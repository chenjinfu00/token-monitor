import Foundation
import Darwin

@main struct ClaudeActivityChecks {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let owner = ClaudeActivityOwner(pid: 321, startedAt: 1_799_000_000)
    static var checks = 0
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
    final class Fixture {
        let home = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ClaudeActivityChecks-" + UUID().uuidString)
        let session = "fixture-private-session"
        var transcript: URL { home.appendingPathComponent("private-transcript.jsonl") }
        var snapshotURL: URL { ClaudeActivityFiles.directory(home: home).appendingPathComponent(ClaudeActivityFiles.hash(session) + ".json") }
        var settingsURL: URL { home.appendingPathComponent(".claude/settings.json") }
        init() { try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true); try! Data().write(to: transcript) }
        deinit { try? FileManager.default.removeItem(at: home) }
        func event(_ name: String, at date: Date = now, extra: [String: Any] = [:], useTranscript: Bool = true,
                   suppliedOwner: ClaudeActivityOwner = owner) {
            var document: [String: Any] = ["hook_event_name": name, "session_id": session,
                "prompt": "PRIVATE_PROMPT_SENTINEL", "tool_input": ["password": "PRIVATE_TOOL_SENTINEL"]]
            if useTranscript { document["transcript_path"] = transcript.path }
            for (key, value) in extra { document[key] = value }
            try! ClaudeActivityHook.capture(document, at: date, homeDirectory: home, owner: suppliedOwner)
        }
        func snapshot() -> ClaudeActivitySnapshot { ClaudeActivityFiles.read(snapshotURL)! }
        func write(_ snapshot: ClaudeActivitySnapshot) { try! ClaudeActivityFiles.atomicWrite(try! JSONEncoder().encode(snapshot), to: snapshotURL) }
        func append(_ data: Data) {
            let handle = try! FileHandle(forWritingTo: transcript); defer { try? handle.close() }
            try! handle.seekToEnd(); try! handle.write(contentsOf: data)
        }
        func usage(_ id: String = "message-private-id", request: String? = "request-private-id", input: Any = 10,
                   output: Any = 5, cache: Any = 3, at date: Date = now.addingTimeInterval(1), includeMessage: Bool = true) -> Data {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var message: [String: Any] = ["usage": ["input_tokens": input, "output_tokens": output,
                "cache_creation_input_tokens": cache, "cache_read_input_tokens": 100_000,
                "reasoning_output_tokens": 100_000], "content": ["text": "PRIVATE_CONVERSATION_SENTINEL"]]
            if includeMessage { message["id"] = id }
            var document: [String: Any] = ["type": "assistant", "timestamp": formatter.string(from: date), "message": message]
            if let request { document["requestId"] = request }
            var bytes = try! JSONSerialization.data(withJSONObject: document); bytes.append(10); return bytes
        }
        func settings(_ document: [String: Any]) {
            try! FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: settingsURL)
        }
        func readSettings() -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as! [String: Any] }
        func app(_ name: String = "Token Monitor.app") -> URL {
            let url = home.appendingPathComponent(name)
            let binary = url.appendingPathComponent("Contents/MacOS/TokenMonitor")
            try! FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary); chmod(binary.path, 0o755)
            return url
        }
    }
    static func hookCommands(_ document: [String: Any]) -> [String] {
        let events = document["hooks"] as? [String: [[String: Any]]] ?? [:]
        return events.values.flatMap { $0 }.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
    }
    static func lifecycle() {
        let f = Fixture()
        let live = ClaudeActivityProbe(homeDirectory: f.home, ownerIsAlive: { _ in true })
        require(live.read(at: now).runningSessionIDs.isEmpty, "No callback means idle")
        f.event("UserPromptSubmit")
        require(live.read(at: now).runningSessionIDs.count == 1, "Prompt confirms local activity")
        f.event("PreToolUse", at: now.addingTimeInterval(1), extra: ["tool_name": "AskUserQuestion"])
        let waiting = live.read(at: now.addingTimeInterval(1))
        require(waiting.runningSessionIDs.isEmpty && waiting.statusNote == "等待授权或输入", "Awaiting a user answer is paused, not falsely idle")
        f.event("PostToolUse", at: now.addingTimeInterval(2))
        require(live.read(at: now.addingTimeInterval(2)).runningSessionIDs.count == 1, "Tool completion resumes activity")
        f.event("PermissionRequest", at: now.addingTimeInterval(3))
        require(live.read(at: now.addingTimeInterval(3)).runningSessionIDs.isEmpty, "Permission waiting is paused")
        f.event("PostToolUseFailure", at: now.addingTimeInterval(4), extra: ["is_interrupt": true])
        require(f.snapshot().phase == .idle, "Reported interruption stops")
        for event in ["Stop", "StopFailure", "SessionEnd"] {
            f.event("UserPromptSubmit", at: now.addingTimeInterval(5)); f.event(event, at: now.addingTimeInterval(6))
            require(live.read(at: now.addingTimeInterval(6)).runningSessionIDs.isEmpty, "Terminal hooks stop activity")
        }
        checks += 1
    }
    static func notificationsAndQuota() {
        let f = Fixture(); f.event("Notification", extra: ["notification_type": "auth_success"])
        let p = ClaudeActivityProbe(homeDirectory: f.home, ownerIsAlive: { _ in true })
        require(p.read(at: now).runningSessionIDs.isEmpty, "Unrelated notifications cannot start a task")
        f.event("UserPromptSubmit"); f.event("Notification", extra: ["notification_type": "permission_prompt"])
        require(p.read(at: now).runningSessionIDs.isEmpty, "Permission notification pauses")
        f.event("UserPromptSubmit"); f.event("Notification", extra: ["notification_type": "idle_prompt"])
        require(p.read(at: now).runningSessionIDs.isEmpty, "Idle notification stops")
        let before = try! Data(contentsOf: f.snapshotURL)
        f.event("UsageQuery", at: now.addingTimeInterval(1))
        require(try! Data(contentsOf: f.snapshotURL) == before, "Monitor quota queries are not activity hooks")
        checks += 1
    }
    static func children() {
        let f = Fixture(); f.event("UserPromptSubmit"); f.event("SubagentStart", extra: ["agent_id": "private-agent"])
        let p = ClaudeActivityProbe(homeDirectory: f.home, ownerIsAlive: { _ in true })
        require(p.read(at: now).runningSessionIDs.count == 2, "Parent and child have distinct activity")
        f.event("Stop", at: now.addingTimeInterval(1)); require(p.read(at: now.addingTimeInterval(1)).runningSessionIDs.count == 1, "Parent stop does not stop a background child")
        f.event("UserPromptSubmit", at: now.addingTimeInterval(2)); f.event("SubagentStop", at: now.addingTimeInterval(2), extra: ["agent_id": "private-agent"])
        require(p.read(at: now.addingTimeInterval(2)).runningSessionIDs.count == 1, "Child stop does not stop parent")
        f.event("SubagentStart", at: now.addingTimeInterval(3), extra: ["agent_id": "private-agent"]); f.event("SessionEnd", at: now.addingTimeInterval(3))
        require(p.read(at: now.addingTimeInterval(3)).runningSessionIDs.isEmpty, "Session end clears all children")
        checks += 1
    }
    static func freshnessAndOwner() {
        let f = Fixture(); f.event("UserPromptSubmit")
        require(ClaudeActivityProbe(homeDirectory: f.home, ownerIsAlive: { _ in false }).read(at: now).runningSessionIDs.isEmpty, "Dead or reused PID cannot run")
        let p = ClaudeActivityProbe(homeDirectory: f.home, ownerIsAlive: { _ in true })
        let expired = p.read(at: now.addingTimeInterval(121))
        require(expired.runningSessionIDs.isEmpty && expired.statusNote == "任务状态待更新", "Live process does not prolong old activity; state is pending")
        var s = f.snapshot(); s.capturedAt = now.timeIntervalSince1970 + 30; f.write(s)
        require(p.read(at: now).runningSessionIDs.isEmpty, "Future snapshot rejected")
        s.capturedAt = now.timeIntervalSince1970; s.owner = ClaudeActivityOwner(pid: 321, startedAt: now.timeIntervalSince1970 + 30); f.write(s)
        require(p.read(at: now).runningSessionIDs.isEmpty, "Future process birth rejected")
        let ended = Fixture(); ended.event("UserPromptSubmit")
        let stoppedAt = now.addingTimeInterval(10)
        ended.event("Stop", at: stoppedAt)
        let deadEnded = ClaudeActivityProbe(homeDirectory: ended.home, ownerIsAlive: { _ in false }).read(at: stoppedAt.addingTimeInterval(1))
        require(deadEnded.runningSessionIDs.isEmpty && deadEnded.lastTaskEventAt == stoppedAt,
            "A real Stop remains authoritative when the owner exits before the worker reads it")
        checks += 1
    }
    static func countersAndBaseline() {
        let f = Fixture(); f.append(f.usage(input: 90_000)); f.event("UserPromptSubmit")
        require(f.snapshot().totalTokens == 0, "Collector starts at EOF without replaying history")
        let p = ClaudeActivityProbe(homeDirectory: f.home, ownerIsAlive: { _ in true }); require(p.read(at: now).tokenDeltas.isEmpty, "Probe bootstrap is a baseline")
        f.append(f.usage()); f.event("PreToolUse", at: now.addingTimeInterval(1))
        let first = p.read(at: now.addingTimeInterval(1))
        require(first.tokenDeltas.first?.tokens == 18, "Fresh input, output and cache writes count; cache reads and reasoning do not")
        require(abs((first.tokenDeltas.first?.weightedTokens ?? 0) - 2_007.75) < 0.001,
            "Speed weighs output fully, input 1/5, cache writes 1/4 and cache reads 1/50 of their count")
        f.append(f.usage(output: 8, at: now.addingTimeInterval(2))); f.event("PostToolUse", at: now.addingTimeInterval(2))
        let streamed = p.read(at: now.addingTimeInterval(2)).tokenDeltas.first
        require(streamed?.tokens == 3 && streamed?.weightedTokens == 3, "Streaming usage is the maximum per API message")
        f.append(f.usage(output: 8, at: now.addingTimeInterval(3))); f.event("PreToolUse", at: now.addingTimeInterval(3))
        require(p.read(at: now.addingTimeInterval(3)).tokenDeltas.isEmpty, "Repeated content blocks cannot inflate rate")
        p.reset(); require(p.read(at: now.addingTimeInterval(3)).tokenDeltas.isEmpty, "Wake/reset does not replay old totals")
        checks += 1
    }
    static func olderSnapshotsStayReadable() {
        let f = Fixture(); f.event("UserPromptSubmit")
        let p = ClaudeActivityProbe(homeDirectory: f.home, ownerIsAlive: { _ in true }); _ = p.read(at: now)
        f.append(f.usage()); f.event("PreToolUse", at: now.addingTimeInterval(1))
        // Store the snapshot the way 0.10.5 did: no weighted total and no cache reads.
        var document = try! JSONSerialization.jsonObject(with: Data(contentsOf: f.snapshotURL)) as! [String: Any]
        document.removeValue(forKey: "weightedTokens")
        if var requests = document["requests"] as? [String: [String: Any]] {
            for key in Array(requests.keys) { requests[key]?.removeValue(forKey: "cacheRead") }
            document["requests"] = requests
        }
        try! ClaudeActivityFiles.atomicWrite(try! JSONSerialization.data(withJSONObject: document), to: f.snapshotURL)
        require(f.snapshot().weightedTokens == nil, "Older snapshots decode without the new fields")
        let legacy = p.read(at: now.addingTimeInterval(1)).tokenDeltas.first
        require(legacy?.tokens == 18 && legacy?.weightedTokens == nil, "Without a weighted baseline the raw count is used")
        f.append(f.usage(output: 9, at: now.addingTimeInterval(2))); f.event("PostToolUse", at: now.addingTimeInterval(2))
        let resumed = p.read(at: now.addingTimeInterval(2)).tokenDeltas.first
        require(f.snapshot().weightedTokens != nil && resumed?.tokens == 4 && resumed?.weightedTokens == nil,
            "The next hook resumes weighted counting; one more read sets its baseline")
        f.append(f.usage("message-second", request: "request-second", at: now.addingTimeInterval(3)))
        f.event("PreToolUse", at: now.addingTimeInterval(3))
        let weighted = p.read(at: now.addingTimeInterval(3)).tokenDeltas.first
        require(weighted?.tokens == 18 && abs((weighted?.weightedTokens ?? 0) - 2_007.75) < 0.001,
            "After the transition each request is weighted")
        checks += 1
    }
    static func requestAliasAndInvalidCounters() {
        let f = Fixture(); f.event("UserPromptSubmit")
        f.append(f.usage(includeMessage: false)); f.event("PreToolUse", at: now.addingTimeInterval(1))
        f.append(f.usage(output: 7, at: now.addingTimeInterval(2))); f.event("PostToolUse", at: now.addingTimeInterval(2))
        require(f.snapshot().totalTokens == 20, "Request fallback merges into later message identity")
        f.append(f.usage("second-content-message", output: 9, at: now.addingTimeInterval(2)))
        f.event("PreToolUse", at: now.addingTimeInterval(2))
        require(f.snapshot().totalTokens == 22, "Different message IDs from the same API request share maxima")
        f.append(f.usage("invalid", request: nil, input: true, output: -1, cache: 1.5, at: now.addingTimeInterval(3)))
        f.append(f.usage("future", request: nil, at: now.addingTimeInterval(60))); f.event("PreToolUse", at: now.addingTimeInterval(3))
        require(f.snapshot().totalTokens == 22, "Boolean, negative, fractional and future counters rejected")
        checks += 1
    }
    static func partialAndTruncation() {
        let f = Fixture(); f.event("UserPromptSubmit"); let line = f.usage(); let split = line.count / 2
        f.append(line.prefix(split)); f.event("PreToolUse", at: now.addingTimeInterval(1))
        require(f.snapshot().totalTokens == 0, "Incomplete lines remain unread")
        f.append(line.suffix(line.count - split)); f.event("PostToolUse", at: now.addingTimeInterval(1))
        require(f.snapshot().totalTokens == 18, "Completed line counts exactly once")
        try! Data().write(to: f.transcript); f.event("PreToolUse", at: now.addingTimeInterval(2))
        f.append(f.usage("new-message", request: nil, at: now.addingTimeInterval(3))); f.event("PostToolUse", at: now.addingTimeInterval(3))
        require(f.snapshot().totalTokens == 36, "Truncation rebases cursor while keeping monotonic observed totals")
        checks += 1
    }
    static func privacyAndAtomicity() {
        let f = Fixture(); f.event("UserPromptSubmit"); f.append(f.usage()); f.event("PreToolUse", at: now.addingTimeInterval(1))
        let text = String(data: try! Data(contentsOf: f.snapshotURL), encoding: .utf8)!
        for value in [f.session, f.transcript.path, "message-private-id", "request-private-id", "PRIVATE_PROMPT_SENTINEL", "PRIVATE_TOOL_SENTINEL", "PRIVATE_CONVERSATION_SENTINEL"] {
            require(!text.contains(value), "Snapshot has no private source values")
        }
        require(ClaudeActivityFiles.regularFile(f.snapshotURL)!.st_mode & 0o777 == 0o600, "Private atomically replaced snapshot")
        let files = try! FileManager.default.contentsOfDirectory(atPath: f.snapshotURL.deletingLastPathComponent().path)
        require(!files.contains(where: { $0.hasPrefix(".write-") }), "No temporary payload is retained")
        let old = try! Data(contentsOf: f.snapshotURL); f.event("Stop", at: now)
        require(try! Data(contentsOf: f.snapshotURL) == old, "Older callback cannot overwrite fresh lifecycle")
        checks += 1
    }
    static func boundedIdentitiesAndOwnershipChange() {
        let f = Fixture(); f.event("UserPromptSubmit")
        for n in 0..<150 { f.append(f.usage("m-\(n)", request: "r-\(n)")) }
        f.event("PreToolUse", at: now.addingTimeInterval(1))
        require(f.snapshot().requests.count == 128 && f.snapshot().requestAliases.count <= 128, "Request bookkeeping is bounded")
        f.event("UserPromptSubmit", at: now.addingTimeInterval(2), suppliedOwner: ClaudeActivityOwner(pid: 654, startedAt: owner.startedAt + 1))
        require(f.snapshot().totalTokens == 0 && f.snapshot().requests.isEmpty, "Changed process ownership does not replay previous session counters")
        checks += 1
    }
    static func installerPreservesAndIsIdempotent() {
        let f = Fixture(); f.settings(["theme": "dark", "privateFixture": "DO_NOT_PRINT", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "other-hook"]]]]]])
        let app = f.app(); require(ClaudeActivityHookInstaller.installIfNeeded(bundleURL: app, homeDirectory: f.home) == nil, "Install synthetic app")
        let settings = f.readSettings(); require(settings["theme"] as? String == "dark" && hookCommands(settings).contains("other-hook"), "Install preserves unrelated fields and hooks")
        require(hookCommands(settings).count == 12, "Exactly eleven lifecycle registrations")
        let bytes = try! Data(contentsOf: f.settingsURL)
        require(ClaudeActivityHookInstaller.installIfNeeded(bundleURL: app, homeDirectory: f.home) == nil && (try! Data(contentsOf: f.settingsURL)) == bytes, "Reinstall does not rewrite or duplicate")
        let backups = try! FileManager.default.contentsOfDirectory(at: f.settingsURL.deletingLastPathComponent().appendingPathComponent("token-monitor"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".backup-") }
        require(backups.count == 1 && ClaudeActivityFiles.regularFile(backups[0])!.st_mode & 0o777 == 0o600, "One private full original backup")
        require(try! JSONSerialization.jsonObject(with: Data(contentsOf: backups[0])) as? NSDictionary == ["theme": "dark", "privateFixture": "DO_NOT_PRINT", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "other-hook"]]]]]] as NSDictionary, "Backup preserves original configuration")
        checks += 1
    }
    static func updateAndUninstall() {
        let f = Fixture(); let foreign = "echo --claude-activity-hook"; f.settings(["hooks": ["Stop": [["hooks": [["type": "command", "command": foreign]]]]]])
        let app = f.app(); require(ClaudeActivityHookInstaller.installIfNeeded(bundleURL: app, homeDirectory: f.home) == nil, "First install")
        let moved = f.app("Moved ' Application.app")
        require(ClaudeActivityHookInstaller.installIfNeeded(bundleURL: moved, homeDirectory: f.home) == nil, "App path can be safely shell quoted and updated")
        var settings = f.readSettings(); require(hookCommands(settings).filter { $0 != foreign }.allSatisfy { !$0.contains("Token Monitor.app") }, "Remove only saved previous owned commands")
        settings["subsequentUserSetting"] = 42; f.settings(settings)
        require(ClaudeActivityHookInstaller.uninstall(homeDirectory: f.home) == nil, "Explicit uninstall")
        settings = f.readSettings(); require(settings["subsequentUserSetting"] as? Int == 42 && hookCommands(settings) == [foreign], "Uninstall keeps later user edits and similar foreign commands")
        require(ClaudeActivityHookInstaller.uninstall(homeDirectory: f.home) == nil, "Uninstall idempotence")
        checks += 1
    }
    static func invalidSettingsFailClosed() {
        let f = Fixture(); f.settings([:]); let bad = Data("[broken json".utf8); try! bad.write(to: f.settingsURL)
        require(ClaudeActivityHookInstaller.installIfNeeded(bundleURL: f.app(), homeDirectory: f.home) != nil, "Malformed settings fail closed")
        require(try! Data(contentsOf: f.settingsURL) == bad, "Do not replace malformed configuration")
        f.settings(["hooks": ["Stop": "invalid-schema"]]); let before = try! Data(contentsOf: f.settingsURL)
        require(ClaudeActivityHookInstaller.installIfNeeded(bundleURL: f.app(), homeDirectory: f.home) != nil && (try! Data(contentsOf: f.settingsURL)) == before, "Malformed hook structures preserved")
        checks += 1
    }
    static func boundedAndMalformedData() {
        let f = Fixture(); f.event("UserPromptSubmit")
        let valid = try! Data(contentsOf: f.snapshotURL)
        var document = try! JSONSerialization.jsonObject(with: valid) as! [String: Any]
        document["schemaVersion"] = 99
        try! JSONSerialization.data(withJSONObject: document).write(to: f.snapshotURL)
        require(ClaudeActivityFiles.read(f.snapshotURL) == nil, "Unknown snapshot schema rejected")
        try! Data(repeating: 32, count: ClaudeActivityFiles.maximumSnapshotBytes + 1).write(to: f.snapshotURL)
        require(ClaudeActivityFiles.read(f.snapshotURL) == nil, "Snapshot reads remain bounded")
        try! valid.write(to: f.snapshotURL)
        let link = f.home.appendingPathComponent("linked.json")
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.snapshotURL)
        require(ClaudeActivityFiles.read(link) == nil, "A symlink is not a snapshot source")
        f.append(Data(repeating: 120, count: 2 * 1024 * 1024 + 20)); f.append(Data([10])); f.append(f.usage())
        for _ in 0..<3 { f.event("PreToolUse", at: now.addingTimeInterval(1)) }
        require(f.snapshot().totalTokens == 18, "Oversized lines are skipped incrementally without blocking later usage")
        checks += 1
    }
    static func unknownTerminalEventsLeaveNoFiles() {
        let f = Fixture()
        for event in ["SessionEnd", "Stop", "StopFailure", "Notification", "PermissionRequest", "SubagentStop", "PostToolUseFailure"] {
            f.event(event)
        }
        require(!FileManager.default.fileExists(atPath: ClaudeActivityFiles.directory(home: f.home).path), "Quota-only and unknown terminal events create no activity directory, locks or snapshot")
        f.event("UserPromptSubmit"); f.event("SessionEnd", at: now.addingTimeInterval(1))
        require(f.snapshot().phase == .idle, "Existing activity still records normal session end")
        checks += 1
    }
    static func crossProcessLock() {
        let f = Fixture(); let directory = ClaudeActivityFiles.directory(home: f.home); try! ClaudeActivityFiles.ensureDirectory(directory)
        let counter = directory.appendingPathComponent("test-counter.json"); try! Data("0".utf8).write(to: counter)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let children = (0..<3).map { _ -> Process in
            let child = Process(); child.executableURL = executable; child.arguments = ["--lock-fixture", directory.path]
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice; try! child.run(); return child
        }
        children.forEach { $0.waitUntilExit(); require($0.terminationStatus == 0, "Fixture child finishes") }
        require(String(data: try! Data(contentsOf: counter), encoding: .utf8) == "60", "Cross-process lock serializes same-session atomic increments")
        checks += 1
    }
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--lock-fixture" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2]); let counter = directory.appendingPathComponent("test-counter.json")
            for _ in 0..<20 {
                try! ClaudeActivityFiles.withLock(directory: directory, name: "fixture") {
                    let value = Int(String(data: try! Data(contentsOf: counter), encoding: .utf8)!)!
                    try! ClaudeActivityFiles.atomicWrite(Data(String(value + 1).utf8), to: counter)
                }
            }
            return
        }
        lifecycle(); notificationsAndQuota(); children(); freshnessAndOwner(); countersAndBaseline(); olderSnapshotsStayReadable()
        requestAliasAndInvalidCounters(); partialAndTruncation(); privacyAndAtomicity(); boundedIdentitiesAndOwnershipChange()
        installerPreservesAndIsIdempotent(); updateAndUninstall(); invalidSettingsFailClosed(); boundedAndMalformedData(); unknownTerminalEventsLeaveNoFiles(); crossProcessLock()
        print("PASS \(checks) Claude activity lifecycle, token metadata, private snapshots and explicit installer checks")
    }
}
