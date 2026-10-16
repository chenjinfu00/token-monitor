import Foundation
import CoreFoundation
import Darwin
import SQLite3

// Read-only local observation. A quota app-server process is never considered a task.
// All state belongs to the monitor's single background queue; no conversation text is kept.
final class CodexActivityProbe {
    private let codexDirectory: URL
    private let sessionsDirectory: URL
    private let locksDirectory: URL
    private var tails: [String: Tail] = [:]
    private let fractionalDate = ISO8601DateFormatter()
    private let plainDate = ISO8601DateFormatter()
    private let maximumRead = 8 * 1_024 * 1_024
    private let maximumLine = 2 * 1_024 * 1_024
    private let chunkSize = 64 * 1_024

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        sessionsDirectory = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        locksDirectory = codexDirectory.appendingPathComponent("thread-writer-locks", isDirectory: true)
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plainDate.formatOptions = [.withInternetDateTime]
    }

    func reset() { tails.removeAll() }

    func read(at now: Date) -> ProviderActivityReading {
        var reading = ProviderActivityReading()
        // Watching idle loaded sessions catches the next task, even in an old date folder.
        reading.watchedDirectories = [codexDirectory, locksDirectory]
        let heldIDs = heldWriterIDs()
        let databaseURL = stateDatabaseURL()
        if let databaseURL {
            reading.watchedFiles.append(databaseURL)
            let wal = URL(fileURLWithPath: databaseURL.path + "-wal")
            if FileManager.default.fileExists(atPath: wal.path) { reading.watchedFiles.append(wal) }
        }
        guard !heldIDs.isEmpty else { tails.removeAll(); return reading }
        let paths = rolloutPaths(for: heldIDs, databaseURL: databaseURL, now: now)
        tails = tails.filter { heldIDs.contains($0.key) && paths[$0.key] != nil }
        for id in heldIDs.sorted() {
            guard let url = paths[id], let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            var attributes = stat()
            guard fstat(handle.fileDescriptor, &attributes) == 0, attributes.st_size >= 0,
                  (attributes.st_mode & S_IFMT) == S_IFREG else { continue }
            reading.watchedFiles.append(url)
            let size = UInt64(attributes.st_size)
            let identity = FileIdentity(device: UInt64(attributes.st_dev), inode: UInt64(attributes.st_ino))
            var tail = tails[id] ?? Tail()
            let needsBaseline = tail.identity != identity || tail.url != url || size < tail.offset
            if needsBaseline || size - tail.offset > UInt64(maximumRead) {
                tail = bootstrap(handle: handle, size: size, identity: identity, url: url, now: now)
            } else if size > tail.offset {
                readAppend(handle: handle, size: size, tail: &tail, sessionID: id, now: now,
                    deltas: &reading.tokenDeltas)
            }
            // Close/release races may occur after discovery. A second check prevents a dead
            // writer's unfinished log from reviving an animation for the next polling interval.
            if writerIsHeld(id: id) {
                if tail.running { reading.runningSessionIDs.insert(id) }
                tails[id] = tail
            } else { tails.removeValue(forKey: id) }
        }
        return reading
    }

    private struct FileIdentity: Equatable { let device: UInt64; let inode: UInt64 }
    private struct Counters: Equatable {
        let input: Int
        let cached: Int
        let output: Int
        var effective: Int { input - cached + output }
        // Output-equivalent cost: fresh input and cached input at their list price.
        var weighted: Double {
            Double(output) + Double(input - cached) * TokenWeights.codexInput + Double(cached) * TokenWeights.codexCachedInput
        }
        func continues(_ previous: Counters) -> Bool {
            input >= previous.input && cached >= previous.cached && output >= previous.output
        }
    }
    private struct Tail {
        var identity: FileIdentity?
        var url: URL?
        var offset: UInt64 = 0
        var partial = Data()
        var skippingLargeLine = false
        var running = false
        var turnID: String?
        var lifecycleAt: Date?
        var counters: Counters?
        var countersAt: Date?
    }
    private enum Event {
        case started(Date, String?)
        case ended(Date, String?)
        case counters(Date, Counters)
        case rebase
    }

    private func heldWriterIDs() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: locksDirectory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var held = Set<String>()
        for file in files where file.pathExtension == "lock" {
            let id = file.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            if writerIsHeld(id: id) { held.insert(id) }
        }
        return held
    }

    private func writerIsHeld(id: String) -> Bool {
        // Never create or update a writer lock. Nonblocking observation cannot delay Codex.
        let fd = open(locksDirectory.appendingPathComponent(id + ".lock").path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    private func stateDatabaseURL() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: codexDirectory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return files.compactMap { url -> (Int, URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }.max(by: { $0.0 < $1.0 })?.1
    }

    private func rolloutPaths(for ids: Set<String>, databaseURL: URL?, now: Date) -> [String: URL] {
        var result: [String: URL] = [:]
        if let databaseURL {
            var db: OpaquePointer?
            if sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
               let db {
                defer { sqlite3_close(db) }
                // Primary-key lookups do not walk titles, prompts, or all history.
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = ? AND archived = 0", -1,
                    &statement, nil) == SQLITE_OK, let statement {
                    defer { sqlite3_finalize(statement) }
                    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    for id in ids {
                        sqlite3_reset(statement)
                        sqlite3_clear_bindings(statement)
                        sqlite3_bind_text(statement, 1, id, -1, transient)
                        if sqlite3_step(statement) == SQLITE_ROW,
                           let text = sqlite3_column_text(statement, 0) {
                            let path = String(cString: text)
                            let url = URL(fileURLWithPath: path).standardizedFileURL
                            if validRollout(url, id: id) { result[id] = url }
                        }
                    }
                }
            } else if let db { sqlite3_close(db) }
        }
        let missing = ids.subtracting(result.keys)
        guard !missing.isEmpty else { return result }
        // A new thread may acquire its writer lock before SQLite stores its rollout path.
        // Search only today's/yesterday's local and UTC folders, never the full tree.
        for directory in recentSessionDirectories(at: now) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let stem = file.deletingPathExtension().lastPathComponent
                guard stem.count >= 36 else { continue }
                let id = String(stem.suffix(36))
                if missing.contains(id), validRollout(file, id: id) { result[id] = file }
            }
        }
        return result
    }

    private func validRollout(_ url: URL, id: String) -> Bool {
        let actual = url.resolvingSymlinksInPath().standardizedFileURL
        let root = sessionsDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return actual.path.hasPrefix(root) && actual.pathExtension == "jsonl"
            && actual.deletingPathExtension().lastPathComponent.hasSuffix(id)
    }

    private func recentSessionDirectories(at now: Date) -> [URL] {
        var paths = Set<String>()
        for zone in [TimeZone.autoupdatingCurrent, TimeZone(secondsFromGMT: 0)!] {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
            for day in [now, yesterday] {
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                if let year = parts.year, let month = parts.month, let day = parts.day {
                    paths.insert(String(format: "%04d/%02d/%02d", year, month, day))
                }
            }
        }
        return paths.sorted().map { sessionsDirectory.appendingPathComponent($0, isDirectory: true) }
    }

    private func bootstrap(handle: FileHandle, size: UInt64, identity: FileIdentity, url: URL, now: Date) -> Tail {
        var tail = Tail(); tail.identity = identity; tail.url = url
        let start = size > UInt64(maximumRead) ? size - UInt64(maximumRead) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return tail }
        tail.offset = start + UInt64(data.count)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        guard let final = lines.last else { return tail }
        if final.count <= maximumLine { tail.partial = final.isEmpty ? Data() : Data(final) }
        else { tail.skippingLargeLine = true }
        let lower = start == 0 ? 0 : 1 // The first line of a bounded tail may be incomplete.
        let upper = lines.count - 1 // Never process a line until its terminating newline exists.
        var newest: [Event] = []
        var foundStart = false, foundCounter = false
        if upper > lower {
            for index in stride(from: upper - 1, through: lower, by: -1) {
                guard let event = event(from: Data(lines[index]), now: now) else { continue }
                newest.append(event)
                if case .started = event { foundStart = true }
                if case .counters = event { foundCounter = true }
                if foundStart && foundCounter { break }
            }
        }
        var ignored: [ActivityTokenDelta] = []
        for event in newest.reversed() {
            apply(event, to: &tail, sessionID: "", now: now, emit: false, deltas: &ignored)
        }
        return tail
    }

    private func readAppend(handle: FileHandle, size: UInt64, tail: inout Tail, sessionID: String,
        now: Date, deltas: inout [ActivityTokenDelta]) {
        guard (try? handle.seek(toOffset: tail.offset)) != nil else { return }
        while tail.offset < size {
            let count = min(chunkSize, Int(size - tail.offset))
            guard let bytes = try? handle.read(upToCount: count), !bytes.isEmpty else { break }
            tail.offset += UInt64(bytes.count)
            var begin = bytes.startIndex
            for newline in bytes.indices where bytes[newline] == 10 {
                consume(bytes[begin..<newline], complete: true, tail: &tail,
                    sessionID: sessionID, now: now, deltas: &deltas)
                begin = bytes.index(after: newline)
            }
            if begin < bytes.endIndex {
                consume(bytes[begin..<bytes.endIndex], complete: false, tail: &tail,
                    sessionID: sessionID, now: now, deltas: &deltas)
            }
        }
    }

    private func consume(_ fragment: Data.SubSequence, complete: Bool, tail: inout Tail,
        sessionID: String, now: Date, deltas: inout [ActivityTokenDelta]) {
        if !tail.skippingLargeLine {
            if tail.partial.count + fragment.count <= maximumLine { tail.partial.append(fragment) }
            else { tail.partial.removeAll(keepingCapacity: false); tail.skippingLargeLine = true }
        }
        guard complete else { return }
        if !tail.skippingLargeLine, let event = event(from: tail.partial, now: now) {
            apply(event, to: &tail, sessionID: sessionID, now: now, emit: true, deltas: &deltas)
        }
        tail.partial.removeAll(keepingCapacity: tail.partial.count <= chunkSize)
        tail.skippingLargeLine = false
    }

    private func event(from line: Data, now: Date) -> Event? {
        guard line.count <= maximumLine,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        if type == "compacted" || type == "session_meta" { return .rebase }
        guard type == "event_msg", let payload = object["payload"] as? [String: Any],
              let subtype = payload["type"] as? String,
              ["task_started", "task_complete", "turn_aborted", "token_count"].contains(subtype),
              let timestamp = object["timestamp"] as? String,
              let date = fractionalDate.date(from: timestamp) ?? plainDate.date(from: timestamp),
              date <= now.addingTimeInterval(5) else { return nil }
        let turn = payload["turn_id"] as? String
        switch subtype {
        case "task_started": return .started(date, turn)
        case "task_complete", "turn_aborted": return .ended(date, turn)
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let input = counter(total["input_tokens"]),
                  let cached = counter(total["cached_input_tokens"]),
                  let output = counter(total["output_tokens"]), cached <= input,
                  !(input - cached).addingReportingOverflow(output).overflow else { return nil }
            return .counters(date, Counters(input: input, cached: cached, output: output))
        default: return nil
        }
    }

    private func counter(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let numeric = number.doubleValue
        guard numeric.isFinite, numeric >= 0, numeric < Double(Int.max), numeric.rounded(.down) == numeric else { return nil }
        return number.intValue
    }

    private func apply(_ event: Event, to tail: inout Tail, sessionID: String, now: Date,
        emit: Bool, deltas: inout [ActivityTokenDelta]) {
        switch event {
        case .started(let at, let turn):
            if let previous = tail.lifecycleAt, at < previous { return }
            tail.running = true; tail.turnID = turn; tail.lifecycleAt = at
        case .ended(let at, let turn):
            if let previous = tail.lifecycleAt, at < previous { return }
            if let turn, let active = tail.turnID, turn != active { return }
            tail.running = false; tail.turnID = nil; tail.lifecycleAt = at
        case .rebase:
            tail.counters = nil; tail.countersAt = nil
        case .counters(let at, let current):
            if let previousAt = tail.countersAt, at < previousAt { return }
            defer { tail.counters = current; tail.countersAt = at }
            guard emit, let previous = tail.counters, current.continues(previous),
                  current.effective > previous.effective,
                  at >= now.addingTimeInterval(-120) else { return }
            deltas.append(ActivityTokenDelta(sessionID: sessionID, at: at,
                tokens: current.effective - previous.effective, weightedTokens: current.weighted - previous.weighted))
        }
    }
}
