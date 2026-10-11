import Foundation

/// Small, independent reset journal. Only observed quota decreases are admitted.
final class ResetHistoryArchive {
    private let directory: URL
    private var knownIDs: Set<UUID> = []
    private var knownEvents: Set<String> = []
    private(set) var latest: [HistoryResetRecord] = []
    private static let lock = NSRecursiveLock()
    private static var cleanupGeneration: [String: Int] = [:]

    init(directory: URL) throws {
        self.directory = directory
        try reload()
    }

    @discardableResult
    func append(_ records: [HistoryResetRecord]) throws -> Int {
        guard !records.isEmpty else { return 0 }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var index = try Self.index(directory)
        let incoming = records.filter {
            Self.valid($0) && !knownIDs.contains($0.id) && !knownEvents.contains(Self.identity($0))
        }
        // Apply the cleanup floor explicitly; previous observation metadata can predate it.
        let accepted = incoming.filter { record in index.deletedBefore.map { record.observedAt >= $0 } ?? true }
        guard !accepted.isEmpty else { return 0 }
        try Self.appendRows(accepted, directory: directory)
        for record in accepted { knownIDs.insert(record.id); knownEvents.insert(Self.identity(record)) }
        latest = Self.latestRows(latest + accepted)
        index.version = 1
        try Self.save(index, directory: directory)
        return accepted.count
    }

    func prepareRemoval(before cutoff: Date) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.cleanupGeneration[directory.path, default: 0] += 1
        var index = try Self.index(directory)
        index.deletedBefore = max(index.deletedBefore ?? cutoff, cutoff)
        try Self.save(index, directory: directory)
    }

    func finishRemoval(before cutoff: Date) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.cleanupGeneration[directory.path, default: 0] += 1
        let encoder = Self.encoder()
        for file in try Self.files(directory) {
            let temporary = directory.appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString + ".rewrite")
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw HistoryStorageError.cannotCreateFile
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var removed = 0
            var retained = 0
            var error: Error?
            try Self.stream(file) { record in
                if record.observedAt < cutoff { removed += 1; return }
                do {
                    var data = try encoder.encode(record); data.append(10)
                    try handle.write(contentsOf: data)
                    retained += 1
                } catch let failure { error = failure }
            }
            if let error { throw error }
            try handle.synchronize(); try handle.close()
            guard removed > 0 else { continue }
            if retained == 0 { try FileManager.default.removeItem(at: file) }
            else { _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary) }
        }
        try reload()
    }

    func prepareClear() {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.cleanupGeneration[directory.path, default: 0] += 1
    }

    func finishClear() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.cleanupGeneration[directory.path, default: 0] += 1
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where Self.isOwnedFilename(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
        knownIDs.removeAll(); knownEvents.removeAll(); latest.removeAll()
    }

    static func read(directory: URL) throws -> [HistoryResetRecord] {
        lock.lock()
        let snapshot: Index
        let generation: Int
        do {
            snapshot = try index(directory)
            generation = cleanupGeneration[directory.path, default: 0]
        } catch { lock.unlock(); throw error }
        lock.unlock()
        if !snapshot.migrationCompleted {
            // Do the only full quota scan off the mutation lock, on the caller's background queue.
            var legacy: [HistoryResetRecord] = []
            try UsageHistoryRecorder.forEachArchivedRecord(directory: directory) { record in
                for event in record.resetEvents where event.kind == .usageDrop {
                    guard snapshot.deletedBefore.map({ event.observedAt >= $0 }) ?? true else { continue }
                    legacy.append(HistoryResetRecord(provider: record.provider, windowID: record.windowID,
                        windowName: record.windowName, event: event, durationSeconds: record.durationSeconds))
                }
            }
            lock.lock(); defer { lock.unlock() }
            var current = try index(directory)
            if cleanupGeneration[directory.path, default: 0] == generation && !current.migrationCompleted {
                var existing = Set(try readIndependent(directory: directory).map(identity))
                let additions = legacy.filter { record in
                    valid(record) && (current.deletedBefore.map { record.observedAt >= $0 } ?? true) && existing.insert(identity(record)).inserted
                }
                try appendRows(additions, directory: directory)
                current.migrationCompleted = true
                try save(current, directory: directory)
            }
            return try readIndependent(directory: directory)
        }
        lock.lock(); defer { lock.unlock() }
        return try readIndependent(directory: directory)
    }

    private func reload() throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let records = try Self.readIndependent(directory: directory)
        knownIDs = Set(records.map(\.id))
        knownEvents = Set(records.map(Self.identity))
        latest = Self.latestRows(records)
    }

    private static func identity(_ row: HistoryResetRecord) -> String {
        func stamp(_ date: Date?) -> String { date.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "-" }
        return [row.provider.rawValue, row.windowID, stamp(row.observedAt), stamp(row.previousObservedAt),
            String(row.previousUsedPercent), String(row.usedPercent), stamp(row.previousResetsAt), stamp(row.resetsAt)].joined(separator: "|")
    }

    private static func latestRows(_ rows: [HistoryResetRecord]) -> [HistoryResetRecord] {
        var result: [String: HistoryResetRecord] = [:]
        for row in rows {
            let key = row.provider.rawValue + ":" + row.windowID
            if result[key].map({ $0.observedAt < row.observedAt }) ?? true { result[key] = row }
        }
        return Array(result.values)
    }

    private static func readIndependent(directory: URL) throws -> [HistoryResetRecord] {
        let floor = try index(directory).deletedBefore
        var rows: [HistoryResetRecord] = []
        var seen: Set<String> = []
        for file in try files(directory) {
            try stream(file) { row in
                if (floor.map { row.observedAt >= $0 } ?? true) && seen.insert(identity(row)).inserted { rows.append(row) }
            }
        }
        return rows.sorted { $0.observedAt == $1.observedAt ? $0.id.uuidString < $1.id.uuidString : $0.observedAt < $1.observedAt }
    }

    private static func appendRows(_ rows: [HistoryResetRecord], directory: URL) throws {
        let grouped = Dictionary(grouping: rows) { filename($0.observedAt) }
        let encoder = encoder()
        for name in grouped.keys.sorted() {
            let file = directory.appendingPathComponent(name)
            try refuseLink(file)
            if !FileManager.default.fileExists(atPath: file.path),
               !FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
                throw HistoryStorageError.cannotCreateFile
            }
            let handle = try FileHandle(forUpdating: file)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            if length > 0 {
                try handle.seek(toOffset: length - 1)
                let byte = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if byte != Data([10]) { try handle.write(contentsOf: Data([10])) }
            }
            for row in grouped[name]! {
                var data = try encoder.encode(row); data.append(10)
                try handle.write(contentsOf: data)
            }
            try handle.synchronize()
        }
    }

    private static func stream(_ file: URL, consume: (HistoryResetRecord) -> Void) throws {
        try refuseLink(file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var line = Data(); var oversize = false
        let decoder = decoder()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let newline = chunk[cursor...].firstIndex(of: 10)
                let boundary = newline ?? chunk.endIndex
                if !oversize {
                    if line.count + boundary - cursor <= 16_384 { line.append(contentsOf: chunk[cursor..<boundary]) }
                    else { line.removeAll(keepingCapacity: true); oversize = true }
                }
                if let newline {
                    if !oversize, let row = try? decoder.decode(HistoryResetRecord.self, from: line), valid(row) { consume(row) }
                    line.removeAll(keepingCapacity: true); oversize = false; cursor = newline + 1
                } else { cursor = chunk.endIndex }
            }
        }
    }

    private struct Index: Codable {
        var version = 1
        var migrationCompleted = false
        var deletedBefore: Date?
    }
    private static func index(_ directory: URL) throws -> Index {
        let file = directory.appendingPathComponent("reset-history-index.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return Index() }
        try refuseLink(file)
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 16_384 else { throw HistoryStorageError.invalidCheckpoint }
        let value = try decoder().decode(Index.self, from: Data(contentsOf: file))
        guard value.version == 1, value.deletedBefore.map(validDate) ?? true else { throw HistoryStorageError.invalidCheckpoint }
        return value
    }
    private static func save(_ value: Index, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("reset-history-index.json")
        try refuseLink(file)
        try encoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private static func files(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]).filter {
            guard isMonthlyFilename($0.lastPathComponent) else { return false }
            try refuseLink($0)
            return try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func isOwnedFilename(_ name: String) -> Bool { name == "reset-history-index.json" || isMonthlyFilename(name) }
    private static func isMonthlyFilename(_ name: String) -> Bool {
        guard name.count == 20, name.hasPrefix("resets-"), name.hasSuffix(".jsonl") else { return false }
        let parts = name.dropFirst(7).dropLast(6).split(separator: "-")
        return parts.count == 2 && parts[0].count == 4 && parts[1].count == 2 &&
            Int(parts[0]).map { (1...9999).contains($0) } == true && Int(parts[1]).map { (1...12).contains($0) } == true
    }
    private static func filename(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "resets-%04d-%02d.jsonl", components.year!, components.month!)
    }
    private static func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && (0..<253_402_300_800).contains(date.timeIntervalSince1970) }
    private static func valid(_ row: HistoryResetRecord) -> Bool {
        row.schemaVersion == 1 && !row.windowID.isEmpty && row.windowID.utf8.count <= 128 && row.windowName.utf8.count <= 256 &&
        validDate(row.observedAt) && validDate(row.previousObservedAt) && row.previousObservedAt < row.observedAt &&
        row.previousUsedPercent.isFinite && row.usedPercent.isFinite && (0...100).contains(row.previousUsedPercent) &&
        (0...100).contains(row.usedPercent) && row.previousUsedPercent > row.usedPercent &&
        (row.previousResetsAt.map(validDate) ?? true) && (row.resetsAt.map(validDate) ?? true) &&
        (row.durationSeconds.map { $0.isFinite && $0 > 0 } ?? true)
    }
    private static func refuseLink(_ file: URL) throws {
        if FileManager.default.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw HistoryStorageError.symbolicLink
        }
    }
    private static func encoder() -> JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .millisecondsSince1970; value.outputFormatting = [.sortedKeys]; return value }
    private static func decoder() -> JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value }
}
