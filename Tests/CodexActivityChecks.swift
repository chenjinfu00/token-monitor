import Foundation
import Darwin
import SQLite3

@main struct CodexActivityChecks {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let a = "00000000-0000-4000-8000-000000000001"
    static let b = "00000000-0000-4000-8000-000000000002"

    final class Fixture {
        let home: URL
        let root: URL
        let locks: URL
        let database: URL
        var descriptors: [String: Int32] = [:]
        var paths: [String: URL] = [:]
        var db: OpaquePointer?

        init() {
            home = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("CodexActivityChecks-" + UUID().uuidString)
            root = home.appendingPathComponent(".codex")
            locks = root.appendingPathComponent("thread-writer-locks")
            database = root.appendingPathComponent("state_5.sqlite")
            try! FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
            require(sqlite3_open(database.path, &db) == SQLITE_OK, "Fixture database opens")
            require(sqlite3_exec(db, "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, archived INTEGER DEFAULT 0)", nil, nil, nil) == SQLITE_OK, "Fixture schema")
        }
        deinit {
            descriptors.values.forEach { _ = flock($0, LOCK_UN); close($0) }
            sqlite3_close(db)
            try? FileManager.default.removeItem(at: home)
        }
        @discardableResult func session(_ id: String, oldFolder: Bool = false, inDatabase: Bool = true) -> URL {
            let directory: URL
            if oldFolder { directory = root.appendingPathComponent("sessions/2020/01/01") }
            else {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let parts = calendar.dateComponents([.year, .month, .day], from: now)
                directory = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            }
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("rollout-test-" + id + ".jsonl")
            try! Data().write(to: path); paths[id] = path
            if inDatabase {
                var statement: OpaquePointer?
                require(sqlite3_prepare_v2(db, "INSERT INTO threads(id,rollout_path) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK, "Insert prepare")
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, id, -1, transient)
                sqlite3_bind_text(statement, 2, path.path, -1, transient)
                require(sqlite3_step(statement) == SQLITE_DONE, "Insert path")
                sqlite3_finalize(statement)
            }
            let fd = open(locks.appendingPathComponent(id + ".lock").path, O_RDWR | O_CREAT, 0o600)
            require(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0, "Fixture owns writer lock")
            descriptors[id] = fd
            return path
        }
        func unlock(_ id: String) { if let fd = descriptors.removeValue(forKey: id) { _ = flock(fd, LOCK_UN); close(fd) } }
        func append(_ id: String, _ data: Data) {
            let handle = try! FileHandle(forWritingTo: paths[id]!); defer { try? handle.close() }
            try! handle.seekToEnd(); try! handle.write(contentsOf: data)
        }
        func event(_ id: String, _ type: String, at: Date = now, turn: String = "turn-a") {
            append(id, line(type, at: at, payload: ["turn_id": turn]))
        }
        func count(_ id: String, input: Int, cached: Int, output: Int, reasoning: Int = 0, at: Date = now) {
            append(id, counterLine(input: input, cached: cached, output: output, reasoning: reasoning, at: at))
        }
    }
    static func require(_ value: Bool, _ message: String) { precondition(value, message) }
    static func line(_ type: String, at: Date = now, payload: [String: Any] = [:]) -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var payload = payload; payload["type"] = type
        var bytes = try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: at), "payload": payload])
        bytes.append(10); return bytes
    }
    static func counterLine(input: Int, cached: Int, output: Int, reasoning: Int = 0, at: Date = now) -> Data {
        line("token_count", at: at, payload: ["info": ["total_token_usage": ["input_tokens": input,
            "cached_input_tokens": cached, "output_tokens": output, "reasoning_output_tokens": reasoning,
            "total_tokens": input + output]]])
    }

    static func bootstrapAndIncrementalRates() {
        let fixture = Fixture(); fixture.session(a)
        fixture.event(a, "task_started"); fixture.count(a, input: 1_000, cached: 800, output: 50)
        let probe = CodexActivityProbe(homeDirectory: fixture.home)
        let initial = probe.read(at: now)
        require(initial.runningSessionIDs == [a] && initial.tokenDeltas.isEmpty, "Initial history establishes a baseline, never historical rate")
        require(initial.watchedFiles.contains(where: { $0.lastPathComponent == fixture.paths[a]!.lastPathComponent }) && initial.watchedDirectories.contains(where: { $0.lastPathComponent == fixture.locks.lastPathComponent }), "Observe a held session and new locks")
        fixture.count(a, input: 2_000, cached: 1_600, output: 80, reasoning: 50_000, at: now.addingTimeInterval(1))
        let fresh = probe.read(at: now.addingTimeInterval(1))
        require(fresh.tokenDeltas.count == 1 && fresh.tokenDeltas[0].sessionID == a
            && fresh.tokenDeltas[0].at == now.addingTimeInterval(1) && fresh.tokenDeltas[0].tokens == 230,
            "Subtract cached input and do not add reasoning twice")
        require(abs((fresh.tokenDeltas[0].weightedTokens ?? 0) - 65) < 0.001,
            "Speed weight: output 30 + fresh input 200 x 1/8 + cached input 800 x 1/80")
        fixture.count(a, input: 2_000, cached: 1_600, output: 80, reasoning: 50_000, at: now.addingTimeInterval(2))
        require(probe.read(at: now.addingTimeInterval(2)).tokenDeltas.isEmpty, "Repeated totals must not inflate rate")
        require(probe.read(at: now.addingTimeInterval(3)).tokenDeltas.isEmpty, "Unchanged file is never replayed")
    }
    static func lifecycleAndWriterAuthenticity() {
        let fixture = Fixture(); fixture.session(a)
        fixture.event(a, "task_started"); let probe = CodexActivityProbe(homeDirectory: fixture.home)
        require(probe.read(at: now).runningSessionIDs == [a], "Started task with a live writer runs")
        fixture.event(a, "task_complete", at: now.addingTimeInterval(1), turn: "other-turn")
        require(probe.read(at: now.addingTimeInterval(1)).runningSessionIDs == [a], "A copied parent completion cannot stop the child turn")
        fixture.event(a, "task_complete", at: now.addingTimeInterval(2))
        let ended = probe.read(at: now.addingTimeInterval(2))
        require(ended.runningSessionIDs.isEmpty && ended.watchedFiles.contains(where: { $0.lastPathComponent == fixture.paths[a]!.lastPathComponent }), "Completion stops rotation but idle loaded sessions stay watched")
        fixture.event(a, "task_started", at: now.addingTimeInterval(3), turn: "turn-b")
        require(probe.read(at: now.addingTimeInterval(3)).runningSessionIDs == [a], "Later tasks in the same session are detected")
        fixture.event(a, "turn_aborted", at: now.addingTimeInterval(4), turn: "turn-b")
        require(probe.read(at: now.addingTimeInterval(4)).runningSessionIDs.isEmpty, "Aborting stops rotation")
        fixture.event(a, "task_started", at: now.addingTimeInterval(5)); fixture.unlock(a)
        require(probe.read(at: now.addingTimeInterval(5)).runningSessionIDs.isEmpty, "A crashed process leaves no false run from stale logs")
        let idleReading = probe.read(at: now.addingTimeInterval(5)); require(idleReading.watchedFiles.contains(where: { $0.lastPathComponent == fixture.database.lastPathComponent }), "Idle database remains observed for a newly loaded old thread")
    }
    static func quotaAndGuardiansAreNotTasks() {
        let fixture = Fixture(); fixture.session(a); fixture.session(b)
        fixture.count(a, input: 100, cached: 0, output: 10)
        fixture.event(b, "thread_settings_applied")
        let probe = CodexActivityProbe(homeDirectory: fixture.home)
        require(probe.read(at: now).runningSessionIDs.isEmpty, "Quota requests, token counters, settings and writer locks alone are not tasks")
        fixture.event(a, "task_started", at: now.addingTimeInterval(30))
        require(probe.read(at: now).runningSessionIDs.isEmpty, "An implausibly future lifecycle is ignored")
    }
    static func concurrentAndOldDateDiscovery() {
        let fixture = Fixture(); fixture.session(a, oldFolder: true); fixture.session(b, inDatabase: false)
        for id in [a, b] { fixture.event(id, "task_started"); fixture.count(id, input: 100, cached: 40, output: 10) }
        let probe = CodexActivityProbe(homeDirectory: fixture.home)
        require(probe.read(at: now).runningSessionIDs == [a, b], "SQLite locates resumed old threads, and current-date fallback locates unindexed new threads")
        for id in [a, b] { fixture.count(id, input: 200, cached: 80, output: 20, at: now.addingTimeInterval(1)) }
        let fresh = probe.read(at: now.addingTimeInterval(1))
        require(fresh.tokenDeltas.count == 2 && fresh.tokenDeltas.reduce(0, { $0 + $1.tokens }) == 140, "Concurrent tasks contribute independent incremental counters")
    }
    static func forkCompactionAndCounterReset() {
        let fixture = Fixture(); fixture.session(a)
        fixture.event(a, "task_started"); fixture.count(a, input: 100, cached: 0, output: 0)
        let probe = CodexActivityProbe(homeDirectory: fixture.home); _ = probe.read(at: now)
        fixture.append(a, Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"parent-session\"}}\n".utf8))
        fixture.count(a, input: 2_000, cached: 0, output: 0, at: now.addingTimeInterval(1))
        require(probe.read(at: now.addingTimeInterval(1)).tokenDeltas.isEmpty, "Fork metadata rebases copied history")
        fixture.count(a, input: 2_030, cached: 0, output: 0, at: now.addingTimeInterval(2))
        require(probe.read(at: now.addingTimeInterval(2)).tokenDeltas.first?.tokens == 30, "Counts after the fork baseline remain incremental")
        fixture.append(a, Data("{\"type\":\"compacted\",\"payload\":{}}\n".utf8))
        fixture.count(a, input: 3_000, cached: 0, output: 0, at: now.addingTimeInterval(3))
        require(probe.read(at: now.addingTimeInterval(3)).tokenDeltas.isEmpty, "Compaction establishes a fresh baseline")
        fixture.count(a, input: 50, cached: 0, output: 0, at: now.addingTimeInterval(4))
        require(probe.read(at: now.addingTimeInterval(4)).tokenDeltas.isEmpty, "Counter rollback never produces a negative or replayed rate")
        fixture.count(a, input: 70, cached: 0, output: 0, at: now.addingTimeInterval(5))
        require(probe.read(at: now.addingTimeInterval(5)).tokenDeltas.first?.tokens == 20, "Rate recovers after a counter reset")
    }
    static func partialMalformedAndOversizedLines() {
        let fixture = Fixture(); fixture.session(a); fixture.event(a, "task_started"); fixture.count(a, input: 100, cached: 0, output: 0)
        let probe = CodexActivityProbe(homeDirectory: fixture.home); _ = probe.read(at: now)
        let bytes = counterLine(input: 150, cached: 0, output: 0, at: now.addingTimeInterval(1))
        let split = bytes.count / 2
        fixture.append(a, bytes.prefix(split))
        require(probe.read(at: now.addingTimeInterval(1)).tokenDeltas.isEmpty, "Partial JSON must wait for a newline")
        fixture.append(a, bytes.suffix(bytes.count - split))
        require(probe.read(at: now.addingTimeInterval(1)).tokenDeltas.first?.tokens == 50, "Partial lines complete exactly once")
        fixture.append(a, Data("invalid JSON\n".utf8))
        fixture.append(a, Data(repeating: 120, count: 2 * 1_024 * 1_024 + 10))
        _ = probe.read(at: now.addingTimeInterval(2))
        fixture.append(a, Data("\n".utf8)); fixture.count(a, input: 170, cached: 0, output: 0, at: now.addingTimeInterval(3))
        require(probe.read(at: now.addingTimeInterval(3)).tokenDeltas.first?.tokens == 20, "Oversized malformed lines are skipped without blocking later counters")
    }
    static func replacementTruncationAndWakeBaseline() {
        let fixture = Fixture(); let path = fixture.session(a); fixture.event(a, "task_started"); fixture.count(a, input: 100, cached: 0, output: 0)
        let probe = CodexActivityProbe(homeDirectory: fixture.home); _ = probe.read(at: now)
        try! Data().write(to: path)
        require(probe.read(at: now.addingTimeInterval(1)).runningSessionIDs.isEmpty, "A truncated session cannot retain stale activity")
        fixture.event(a, "task_started", at: now.addingTimeInterval(2)); fixture.count(a, input: 500, cached: 0, output: 0, at: now.addingTimeInterval(2))
        require(probe.read(at: now.addingTimeInterval(2)).runningSessionIDs == [a], "A rewritten session can start again")
        probe.reset()
        fixture.count(a, input: 800, cached: 0, output: 0, at: now.addingTimeInterval(3))
        require(probe.read(at: now.addingTimeInterval(3)).tokenDeltas.isEmpty, "Wake/reset rebuilds the baseline without replaying asleep consumption")
        let replacement = path.deletingLastPathComponent().appendingPathComponent("replacement.jsonl")
        try! line("task_complete", at: now.addingTimeInterval(4), payload: ["turn_id": "turn-a"]).write(to: replacement)
        try! FileManager.default.removeItem(at: path); try! FileManager.default.moveItem(at: replacement, to: path)
        require(probe.read(at: now.addingTimeInterval(4)).runningSessionIDs.isEmpty, "Inode replacement rebuilds lifecycle state")
    }
    static func bootstrapBoundAndStaleDelta() {
        let fixture = Fixture(); fixture.session(a); fixture.event(a, "task_started", at: now.addingTimeInterval(-300))
        fixture.append(a, Data(repeating: 120, count: 8 * 1_024 * 1_024 + 100)); fixture.append(a, Data("\n".utf8))
        fixture.count(a, input: 100, cached: 0, output: 0)
        let probe = CodexActivityProbe(homeDirectory: fixture.home)
        require(probe.read(at: now).runningSessionIDs.isEmpty, "Do not infer activity when lifecycle is outside the bounded bootstrap")
        fixture.event(a, "task_started", at: now.addingTimeInterval(1))
        fixture.count(a, input: 200, cached: 0, output: 0, at: now.addingTimeInterval(1))
        require(probe.read(at: now.addingTimeInterval(200)).tokenDeltas.isEmpty, "Old appended counters are not presented as current consumption")
    }
    static func main() {
        bootstrapAndIncrementalRates(); lifecycleAndWriterAuthenticity(); quotaAndGuardiansAreNotTasks()
        concurrentAndOldDateDiscovery(); forkCompactionAndCounterReset(); partialMalformedAndOversizedLines()
        replacementTruncationAndWakeBaseline(); bootstrapBoundAndStaleDelta()
        print("PASS 8 Codex activity lifecycle, incremental token and safety checks")
    }
}
