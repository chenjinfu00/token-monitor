import Foundation

/// Call mutation methods on one owner queue (the app uses its main actor). Static archive reads are independent.
final class UsageHistoryRecorder {
    let directory: URL
    private(set) var interval: HistorySamplingInterval
    private(set) var firstRecordedAt: Date?
    private var pending: [String: Bucket] = [:]
    private var previous: [String: LastObservation] = [:]
    private var acceptedAt: [HistoryProvider: Date] = [:]
    private var segmentFloor: Date?
    private let fileManager = FileManager.default

    init(directory: URL, interval: HistorySamplingInterval = .fifteenMinutes) throws {
        self.directory = directory
        self.interval = interval
        try Self.ensureDirectory(directory)
        try restorePrevious()
    }

    var pendingRecords: [UsageHistoryRecord] {
        pending.values.map { $0.record() }.sorted(by: Self.recordOrder)
    }

    /// Accept only newly delivered successful service snapshots. Repeated statusline files are deduplicated.
    func observe(provider: HistoryProvider, observations: [HistoryObservation], capturedAt: Date, now: Date = Date()) throws {
        guard Self.validDate(capturedAt), Self.validDate(now), now.timeIntervalSince(capturedAt) <= 300,
              capturedAt.timeIntervalSince(now) <= 30,
              acceptedAt[provider].map({ capturedAt > $0 }) ?? true else { return }
        try flush(at: now)
        acceptedAt[provider] = capturedAt
        var seenWindows: Set<String> = []
        for observation in observations.prefix(128) {
            guard seenWindows.insert(observation.windowID).inserted else { continue }
            guard let used = observation.usedPercent, used.isFinite, (0...100).contains(used),
                  !observation.windowID.isEmpty, observation.windowID.utf8.count <= 128,
                  observation.name.utf8.count <= 256,
                  observation.resetsAt.map({ Self.validDate($0) && $0 > now }) ?? true else { continue }
            firstRecordedAt = min(firstRecordedAt ?? capturedAt, capturedAt)
            let duration = observation.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let key = Self.key(provider, observation.windowID)
            let last = LastObservation(provider: provider, windowID: observation.windowID,
                windowName: observation.name, observedAt: capturedAt, usedPercent: used,
                resetsAt: observation.resetsAt, durationSeconds: duration)
            let start = Self.bucketStart(capturedAt, interval: interval)
            let end = start.addingTimeInterval(interval.seconds)
            // A successful update can arrive shortly after its capture. Do not append a fresh observation
            // to an older pending interval, or invent samples for the time while the app was asleep.
            if let bucket = pending[key], bucket.naturalStart != start {
                try persist([bucket.record()])
                pending.removeValue(forKey: key)
            }
            var bucket = pending[key] ?? Bucket(provider: provider, observation: last,
                naturalStart: start, intervalStart: max(start, segmentFloor ?? start),
                intervalEnd: end, intervalMinutes: interval.rawValue)
            if bucket.sampleCount > 0 {
                if used > bucket.peakUsedPercent {
                    bucket.peakUsedPercent = used
                    bucket.peakObservedAt = capturedAt
                }
                bucket.lastObservedAt = capturedAt
                bucket.lastUsedPercent = used
                bucket.resetsAt = observation.resetsAt
                bucket.durationSeconds = duration
                bucket.windowName = observation.name
            }
            if let old = previous[key], capturedAt > old.observedAt {
                bucket.resetEvents.append(contentsOf: Self.events(previous: old, current: last))
            }
            bucket.sampleCount += 1
            pending[key] = bucket
            previous[key] = last
        }
    }

    /// Disk writes occur once per completed interval. Force only for quit or explicit setting changes.
    func flush(at now: Date = Date(), force: Bool = false) throws {
        guard Self.validDate(now) else { return }
        let keys = pending.keys.filter { force || pending[$0]!.intervalEnd <= now }
        guard !keys.isEmpty else {
            if force { segmentFloor = now }
            return
        }
        let records = keys.compactMap { key -> UsageHistoryRecord? in
            guard let bucket = pending[key] else { return nil }
            return bucket.record(endingAt: force ? max(bucket.lastObservedAt, min(now, bucket.intervalEnd)) : nil)
        }
        try persist(records)
        for key in keys { pending.removeValue(forKey: key) }
        if force { segmentFloor = now }
    }

    func setInterval(_ value: HistorySamplingInterval, at now: Date = Date()) throws {
        guard value != interval else { return }
        try flush(at: now, force: true)
        interval = value
        segmentFloor = now
    }

    /// Snapshot pendingRecords on the owner queue; use this static reader on a background queue.
    static func read(directory: URL, range: DateInterval) throws -> [UsageHistoryRecord] {
        guard validDate(range.start), validDate(range.end) else { return [] }
        let files = try historyFiles(directory).filter { url in
            guard let month = fileMonth(url.lastPathComponent) else { return false }
            let rangeStart = monthStart(range.start)
            let rangeEnd = monthStart(range.end)
            return month >= rangeStart && month <= rangeEnd
        }
        var records: [UsageHistoryRecord] = []
        var seen: Set<UUID> = []
        for file in files {
            try streamRecords(file) { record in
                guard record.intervalEnd >= range.start, record.intervalStart <= range.end,
                      seen.insert(record.id).inserted else { return }
                records.append(record)
            }
        }
        return records.sorted(by: recordOrder)
    }

    /// Reduces archive rows as they are decoded, so a year of one-minute samples never
    /// needs to be retained in memory merely to draw an hourly or daily curve.
    /// Real gaps and observed replenishments remain separate continuous segments.
    static func readForChart(directory: URL, range: DateInterval, aggregationSeconds: TimeInterval?,
                             calendar: Calendar = .autoupdatingCurrent) throws -> [UsageHistoryRecord] {
        guard let seconds = aggregationSeconds, seconds.isFinite, seconds > 0 else {
            return try read(directory: directory, range: range).filter { $0.intervalEnd > range.start && $0.intervalStart < range.end }
        }
        guard validDate(range.start), validDate(range.end) else { return [] }
        let files = try historyFiles(directory).filter { url in
            guard let month = fileMonth(url.lastPathComponent) else { return false }
            return month >= monthStart(range.start) && month <= monthStart(range.end)
        }
        var collectors: [String: ChartCollector] = [:]
        var output: [UsageHistoryRecord] = []
        for file in files {
            try streamRecords(file) { record in
                guard record.intervalEnd > range.start, record.intervalStart < range.end else { return }
                let identity = key(record.provider, record.windowID)
                var collector = collectors[identity] ?? ChartCollector()
                // Retries may append the same stable row. Normal duplicate writes are adjacent;
                // this ring is bounded independently of years of source observations.
                guard !collector.recentIDs.contains(record.id) else { return }
                collector.recentIDs.append(record.id)
                if collector.recentIDs.count > 128 { collector.recentIDs.removeFirst() }
                let date = record.peakObservedAt ?? record.firstObservedAt
                let bin = seconds >= 86_400 ? calendar.startOfDay(for: date) :
                    range.start.addingTimeInterval(floor(date.timeIntervalSince(range.start) / seconds) * seconds)
                let recovery = record.resetEvents.contains { $0.kind == .usageDrop }
                var continuous = false
                if let prior = collector.previous {
                    let missingInterval = record.intervalStart.timeIntervalSince(prior.intervalEnd) > 1
                    let missingObservations = record.firstObservedAt.timeIntervalSince(prior.lastObservedAt) > 300
                    let outOfOrder = record.firstObservedAt < prior.lastObservedAt || record.intervalStart < prior.intervalStart
                    let priorRecovery = prior.resetEvents.contains { $0.kind == .usageDrop }
                    continuous = !missingInterval && !missingObservations && !outOfOrder && !priorRecovery && !recovery
                }
                if let current = collector.aggregate, collector.bin == bin, continuous {
                    collector.aggregate = mergeForChart(current, record)
                } else {
                    if let current = collector.aggregate { output.append(current) }
                    collector.aggregate = record
                    collector.bin = bin
                }
                collector.previous = record
                collectors[identity] = collector
            }
        }
        output += collectors.values.compactMap(\.aggregate)
        return output.sorted(by: recordOrder)
    }

    private struct ChartCollector {
        var previous: UsageHistoryRecord?
        var aggregate: UsageHistoryRecord?
        var bin: Date?
        var recentIDs: [UUID] = []
    }

    private static func mergeForChart(_ first: UsageHistoryRecord, _ next: UsageHistoryRecord) -> UsageHistoryRecord {
        let peak = next.peakUsedPercent > first.peakUsedPercent ? next : first
        let latest = next.lastObservedAt >= first.lastObservedAt ? next : first
        return UsageHistoryRecord(id: peak.id, schemaVersion: peak.schemaVersion,
            provider: peak.provider, windowID: peak.windowID, windowName: latest.windowName,
            intervalStart: min(first.intervalStart, next.intervalStart),
            intervalEnd: max(first.intervalEnd, next.intervalEnd),
            firstObservedAt: min(first.firstObservedAt, next.firstObservedAt),
            lastObservedAt: max(first.lastObservedAt, next.lastObservedAt),
            peakUsedPercent: peak.peakUsedPercent, lastUsedPercent: latest.lastUsedPercent,
            resetsAt: latest.resetsAt, durationSeconds: latest.durationSeconds,
            resetEvents: first.resetEvents + next.resetEvents,
            sampleCount: first.sampleCount + next.sampleCount, intervalMinutes: peak.intervalMinutes,
            peakObservedAt: peak.peakObservedAt ?? peak.firstObservedAt)
    }

    func read(range: DateInterval, includingPending: Bool = true) throws -> [UsageHistoryRecord] {
        var records = try Self.read(directory: directory, range: range)
        if includingPending {
            let ids = Set(records.map(\.id))
            records += pendingRecords.filter { !ids.contains($0.id) && $0.intervalEnd >= range.start && $0.intervalStart <= range.end }
        }
        return records.sorted(by: Self.recordOrder)
    }

    func storageBytes() throws -> Int64 {
        try Self.storageBytes(directory: directory)
    }

    static func storageBytes(directory: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]).reduce(0) { total, url in
            guard isOwnedFilename(url.lastPathComponent) else { return total }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    /// Remove only this recorder's named files. Other files beside the archive are left intact.
    func clear(at now: Date = Date()) throws {
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files where Self.isOwnedFilename(file.lastPathComponent) { try fileManager.removeItem(at: file) }
        pending.removeAll()
        previous.removeAll()
        acceptedAt.removeAll()
        segmentFloor = now
        firstRecordedAt = nil
    }

    /// Remove completed intervals ending at/before the chosen date. A bucket crossing
    /// the cutoff is retained whole, because its peak cannot be divided retrospectively.
    func remove(before cutoff: Date, at now: Date = Date()) throws {
        guard Self.validDate(cutoff), Self.validDate(now) else { throw HistoryStorageError.invalidDate }
        try Self.rejectSymbolicLink(directory)
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for entry in entries where Self.isOwnedFilename(entry.lastPathComponent) { try Self.rejectSymbolicLink(entry) }
        let cutoffMonth = Self.monthStart(cutoff)
        let encoder = Self.encoder()
        for file in try Self.historyFiles(directory) {
            guard let month = Self.fileMonth(file.lastPathComponent), month <= cutoffMonth else { continue }
            let temporary = directory.appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString + ".rewrite")
            guard fileManager.createFile(atPath: temporary.path, contents: nil,
                attributes: [.posixPermissions: 0o600]) else { throw HistoryStorageError.cannotCreateFile }
            defer { try? fileManager.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var removed = 0
            var retained = 0
            var writeError: Error?
            try Self.streamRecords(file) { record in
                if record.intervalEnd <= cutoff { removed += 1; return }
                guard writeError == nil else { return }
                do {
                    var data = try encoder.encode(record)
                    data.append(10)
                    try handle.write(contentsOf: data)
                    retained += 1
                } catch { writeError = error }
            }
            if let writeError { throw writeError }
            try handle.synchronize()
            try handle.close()
            guard removed > 0 else { continue }
            if retained == 0 { try fileManager.removeItem(at: file) }
            else { _ = try fileManager.replaceItemAt(file, withItemAt: temporary) }
        }
        pending = pending.filter { $0.value.intervalEnd > cutoff }
        previous = previous.filter { $0.value.observedAt > cutoff }
        acceptedAt.removeAll()
        var archived: [String: LastObservation] = [:]
        firstRecordedAt = pending.values.map(\.firstObservedAt).min()
        for file in try Self.historyFiles(directory) {
            try Self.streamRecords(file) { record in
                firstRecordedAt = min(firstRecordedAt ?? record.firstObservedAt, record.firstObservedAt)
                guard record.lastObservedAt > cutoff else { return }
                let identity = Self.key(record.provider, record.windowID)
                guard archived[identity].map({ $0.observedAt < record.lastObservedAt }) ?? true else { return }
                archived[identity] = LastObservation(provider: record.provider, windowID: record.windowID,
                    windowName: record.windowName, observedAt: record.lastObservedAt,
                    usedPercent: record.lastUsedPercent, resetsAt: record.resetsAt, durationSeconds: record.durationSeconds)
            }
        }
        for (identity, value) in archived {
            if previous[identity].map({ $0.observedAt < value.observedAt }) ?? true { previous[identity] = value }
        }
        for value in previous.values {
            acceptedAt[value.provider] = max(acceptedAt[value.provider] ?? .distantPast, value.observedAt)
        }
        let checkpointURL = directory.appendingPathComponent("latest.json")
        if archived.isEmpty && firstRecordedAt == nil {
            if fileManager.fileExists(atPath: checkpointURL.path) { try fileManager.removeItem(at: checkpointURL) }
        } else {
            let checkpoint = Checkpoint(version: 1, firstRecordedAt: firstRecordedAt,
                observations: archived.values.sorted { $0.observedAt < $1.observedAt })
            try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
        }
        segmentFloor = max(segmentFloor ?? now, now)
    }

    private func persist(_ records: [UsageHistoryRecord]) throws {
        guard !records.isEmpty else { return }
        try Self.ensureDirectory(directory)
        let encoder = Self.encoder()
        let grouped = Dictionary(grouping: records) { Self.filename(for: $0.intervalStart) }
        for filename in grouped.keys.sorted() {
            let url = directory.appendingPathComponent(filename)
            try Self.rejectSymbolicLink(url)
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else { throw HistoryStorageError.cannotCreateFile }
            }
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            // A crash or manually damaged tail must not swallow the next valid record.
            if length > 0 {
                try handle.seek(toOffset: length - 1)
                let lastByte = try handle.read(upToCount: 1)
                try handle.seekToEnd()
                if lastByte != Data([10]) { try handle.write(contentsOf: Data([10])) }
            }
            for record in grouped[filename]!.sorted(by: Self.recordOrder) {
                var data = try encoder.encode(record)
                data.append(10)
                try handle.write(contentsOf: data)
            }
            try handle.synchronize()
        }
        // Store only baselines represented by a flushed record. In-progress samples are never
        // checkpointed at one-minute polling frequency or mistaken for completed history.
        var checkpointValues: [String: LastObservation] = [:]
        if let restored = try? loadCheckpoint() {
            for value in restored.observations { checkpointValues[Self.key(value.provider, value.windowID)] = value }
        }
        for record in records {
            let value = LastObservation(provider: record.provider, windowID: record.windowID,
                windowName: record.windowName, observedAt: record.lastObservedAt,
                usedPercent: record.lastUsedPercent, resetsAt: record.resetsAt,
                durationSeconds: record.durationSeconds)
            let key = Self.key(value.provider, value.windowID)
            if checkpointValues[key].map({ $0.observedAt <= value.observedAt }) ?? true { checkpointValues[key] = value }
        }
        let checkpoint = Checkpoint(version: 1, firstRecordedAt: firstRecordedAt, observations: checkpointValues.values.sorted { $0.observedAt < $1.observedAt })
        let checkpointURL = directory.appendingPathComponent("latest.json")
        try Self.rejectSymbolicLink(checkpointURL)
        try encoder.encode(checkpoint).write(to: checkpointURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpointURL.path)
    }

    private func restorePrevious() throws {
        if let checkpoint = try? loadCheckpoint() {
            firstRecordedAt = checkpoint.firstRecordedAt ?? checkpoint.observations.map(\.observedAt).min()
            for value in checkpoint.observations where value.isValid {
                previous[Self.key(value.provider, value.windowID)] = value
                acceptedAt[value.provider] = max(acceptedAt[value.provider] ?? .distantPast, value.observedAt)
            }
            return
        }
        // Recovery from a missing/damaged checkpoint needs only the most recent monthly file.
        if let file = try Self.historyFiles(directory).last {
            try Self.streamRecords(file) { record in
                firstRecordedAt = min(firstRecordedAt ?? record.firstObservedAt, record.firstObservedAt)
                let key = Self.key(record.provider, record.windowID)
                guard previous[key].map({ $0.observedAt < record.lastObservedAt }) ?? true else { return }
                let value = LastObservation(provider: record.provider, windowID: record.windowID,
                    windowName: record.windowName, observedAt: record.lastObservedAt,
                    usedPercent: record.lastUsedPercent, resetsAt: record.resetsAt,
                    durationSeconds: record.durationSeconds)
                previous[key] = value
                acceptedAt[value.provider] = max(acceptedAt[value.provider] ?? .distantPast, value.observedAt)
            }
        }
    }

    private func loadCheckpoint() throws -> Checkpoint {
        let url = directory.appendingPathComponent("latest.json")
        try Self.rejectSymbolicLink(url)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw HistoryStorageError.invalidCheckpoint }
        let checkpoint = try Self.decoder().decode(Checkpoint.self, from: Data(contentsOf: url))
        guard checkpoint.version == 1, checkpoint.firstRecordedAt.map({ Self.validDate($0) }) ?? true, checkpoint.observations.count <= 256,
              checkpoint.observations.allSatisfy(\.isValid) else { throw HistoryStorageError.invalidCheckpoint }
        return checkpoint
    }

    private static func events(previous old: LastObservation, current value: LastObservation) -> [HistoryResetEvent] {
        var kinds: [HistoryResetEvent.Kind] = []
        let deadlineChanged = old.resetsAt.flatMap { prior in
            value.resetsAt.map { abs($0.timeIntervalSince(prior)) >= 60 }
        } ?? false
        let deadlinePassed = old.resetsAt.map { old.observedAt < $0 && $0 <= value.observedAt } ?? false
        let drop = old.usedPercent - value.usedPercent
        let observedRecovery = drop >= 5 || (drop > 0.01 && (deadlineChanged || deadlinePassed)) ||
            (value.usedPercent <= 1 && drop >= 1)
        if observedRecovery { kinds.append(.usageDrop) }
        if deadlineChanged || (old.resetsAt == nil) != (value.resetsAt == nil) { kinds.append(.deadlineChanged) }
        if deadlinePassed { kinds.append(.priorDeadlinePassed) }
        return kinds.map {
            HistoryResetEvent(id: UUID(), kind: $0, observedAt: value.observedAt,
                previousObservedAt: old.observedAt, previousUsedPercent: old.usedPercent,
                usedPercent: value.usedPercent, previousResetsAt: old.resetsAt, resetsAt: value.resetsAt)
        }
    }

    private static func streamRecords(_ url: URL, consume: (UsageHistoryRecord) -> Void) throws {
        try rejectSymbolicLink(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var line = Data()
        var oversize = false
        let decoder = decoder()
        func deliver() {
            if !oversize, !line.isEmpty, let record = try? decoder.decode(UsageHistoryRecord.self, from: line), valid(record) {
                consume(record)
            }
            line.removeAll(keepingCapacity: true)
            oversize = false
        }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            var cursor = chunk.startIndex
            while cursor < chunk.endIndex {
                let newline = chunk[cursor...].firstIndex(of: 10)
                let boundary = newline ?? chunk.endIndex
                if !oversize {
                    if line.count + boundary - cursor <= 131_072 { line.append(contentsOf: chunk[cursor..<boundary]) }
                    else { line.removeAll(keepingCapacity: true); oversize = true }
                }
                if let newline { deliver(); cursor = newline + 1 }
                else { cursor = chunk.endIndex }
            }
        }
        // JSONL entries are committed only with their trailing newline. An incomplete tail is ignored.
    }

    private static func valid(_ value: UsageHistoryRecord) -> Bool {
        value.schemaVersion == 1 && !value.windowID.isEmpty && value.windowID.utf8.count <= 128 &&
        value.windowName.utf8.count <= 256 && validDate(value.intervalStart) && validDate(value.intervalEnd) &&
        value.intervalEnd >= value.intervalStart && value.firstObservedAt >= value.intervalStart &&
        value.lastObservedAt >= value.firstObservedAt && value.lastObservedAt <= value.intervalEnd &&
        value.peakUsedPercent.isFinite && (0...100).contains(value.peakUsedPercent) &&
        (value.peakObservedAt.map { validDate($0) && $0 >= value.firstObservedAt && $0 <= value.lastObservedAt } ?? true) &&
        value.lastUsedPercent.isFinite && (0...value.peakUsedPercent).contains(value.lastUsedPercent) &&
        (value.resetsAt.map { validDate($0) } ?? true) &&
        (value.durationSeconds.map { $0.isFinite && $0 > 0 } ?? true) &&
        value.sampleCount > 0 && value.sampleCount <= 100_000 &&
        HistorySamplingInterval(rawValue: value.intervalMinutes) != nil && value.resetEvents.count <= 10_000 &&
        value.resetEvents.allSatisfy { event in
            validDate(event.observedAt) && validDate(event.previousObservedAt) &&
            event.previousObservedAt < event.observedAt && event.observedAt >= value.firstObservedAt &&
            event.observedAt <= value.lastObservedAt && event.usedPercent.isFinite &&
            event.previousUsedPercent.isFinite && (0...100).contains(event.usedPercent) &&
            (0...100).contains(event.previousUsedPercent) &&
            (event.previousResetsAt.map { validDate($0) } ?? true) &&
            (event.resetsAt.map { validDate($0) } ?? true)
        }
    }

    private static func validDate(_ value: Date) -> Bool {
        let timestamp = value.timeIntervalSince1970
        return timestamp.isFinite && timestamp >= 0 && timestamp < 253_402_300_800
    }
    private static func key(_ provider: HistoryProvider, _ id: String) -> String { provider.rawValue + ":" + id }
    private static func recordOrder(_ a: UsageHistoryRecord, _ b: UsageHistoryRecord) -> Bool {
        if a.intervalStart != b.intervalStart { return a.intervalStart < b.intervalStart }
        if a.provider != b.provider { return a.provider.rawValue < b.provider.rawValue }
        if a.windowID != b.windowID { return a.windowID < b.windowID }
        return a.id.uuidString < b.id.uuidString
    }
    private static func bucketStart(_ date: Date, interval: HistorySamplingInterval) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / interval.seconds) * interval.seconds)
    }
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private static func monthStart(_ date: Date) -> Date {
        utcCalendar.date(from: utcCalendar.dateComponents([.year, .month], from: date))!
    }
    private static func filename(for date: Date) -> String {
        let parts = utcCalendar.dateComponents([.year, .month], from: date)
        return String(format: "usage-%04d-%02d.jsonl", parts.year!, parts.month!)
    }
    private static func fileMonth(_ name: String) -> Date? {
        guard name.utf8.count == 19, name.hasPrefix("usage-"), name.hasSuffix(".jsonl") else { return nil }
        let middle = name.dropFirst(6).dropLast(6)
        let components = middle.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2, components[0].count == 4, components[1].count == 2,
              components.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(components[0]), let month = Int(components[1]), (1...9999).contains(year), (1...12).contains(month) else { return nil }
        return utcCalendar.date(from: DateComponents(year: year, month: month, day: 1))
    }
    private static func isOwnedFilename(_ name: String) -> Bool { name == "latest.json" || fileMonth(name) != nil }
    private static func historyFiles(_ directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]).filter { url in
            guard fileMonth(url.lastPathComponent) != nil else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func ensureDirectory(_ directory: URL) throws {
        try rejectSymbolicLink(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
    private static func rejectSymbolicLink(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw HistoryStorageError.symbolicLink }
    }
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private struct Checkpoint: Codable { let version: Int; let firstRecordedAt: Date?; let observations: [LastObservation] }
    private struct LastObservation: Codable {
        let provider: HistoryProvider
        let windowID: String
        let windowName: String
        let observedAt: Date
        let usedPercent: Double
        let resetsAt: Date?
        let durationSeconds: TimeInterval?
        var isValid: Bool {
            !windowID.isEmpty && windowID.utf8.count <= 128 && windowName.utf8.count <= 256 &&
            validDate(observedAt) && usedPercent.isFinite && (0...100).contains(usedPercent) &&
            (resetsAt.map { validDate($0) } ?? true) &&
            (durationSeconds.map { $0.isFinite && $0 > 0 } ?? true)
        }
    }
    private struct Bucket {
        let id = UUID()
        let provider: HistoryProvider
        let windowID: String
        var windowName: String
        let naturalStart: Date
        let intervalStart: Date
        let intervalEnd: Date
        let firstObservedAt: Date
        var lastObservedAt: Date
        var peakUsedPercent: Double
        var peakObservedAt: Date
        var lastUsedPercent: Double
        var resetsAt: Date?
        var durationSeconds: TimeInterval?
        var resetEvents: [HistoryResetEvent] = []
        var sampleCount = 0
        let intervalMinutes: Int
        init(provider: HistoryProvider, observation: LastObservation, naturalStart: Date,
             intervalStart: Date, intervalEnd: Date, intervalMinutes: Int) {
            self.provider = provider
            windowID = observation.windowID
            windowName = observation.windowName
            self.naturalStart = naturalStart
            self.intervalStart = min(intervalStart, observation.observedAt)
            self.intervalEnd = intervalEnd
            firstObservedAt = observation.observedAt
            lastObservedAt = observation.observedAt
            peakUsedPercent = observation.usedPercent
            peakObservedAt = observation.observedAt
            lastUsedPercent = observation.usedPercent
            resetsAt = observation.resetsAt
            durationSeconds = observation.durationSeconds
            self.intervalMinutes = intervalMinutes
        }
        func record(endingAt end: Date? = nil) -> UsageHistoryRecord {
            UsageHistoryRecord(id: id, schemaVersion: 1, provider: provider, windowID: windowID,
                windowName: windowName, intervalStart: intervalStart, intervalEnd: end ?? intervalEnd,
                firstObservedAt: firstObservedAt, lastObservedAt: lastObservedAt,
                peakUsedPercent: peakUsedPercent, lastUsedPercent: lastUsedPercent, resetsAt: resetsAt,
                durationSeconds: durationSeconds, resetEvents: resetEvents, sampleCount: sampleCount,
                intervalMinutes: intervalMinutes, peakObservedAt: peakObservedAt)
        }
    }
}

enum HistoryStorageError: LocalizedError {
    case cannotCreateFile, invalidCheckpoint, symbolicLink, invalidDate
    var errorDescription: String? {
        switch self {
        case .cannotCreateFile: return "无法创建用量历史文件。"
        case .invalidCheckpoint: return "历史索引损坏，正在使用有效的记录恢复。"
        case .symbolicLink: return "历史目录包含外部文件链接，无法安全写入。"
        case .invalidDate: return "所选历史清理日期无效。"
        }
    }
}
