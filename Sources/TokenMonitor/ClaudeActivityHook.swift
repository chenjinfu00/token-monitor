import Foundation
import CryptoKit
import CoreFoundation
import Darwin

// These files hold only hashed lifecycle identities and numeric counters. Neither
// prompts, tool payloads, transcript paths nor raw API request IDs are persisted.
enum ClaudeActivityPhase: String, Codable { case active, paused, idle }
struct ClaudeActivityOwner: Codable, Equatable {
    let pid: Int32
    let startedAt: Double
}
struct ClaudeAgentActivity: Codable {
    var phase: ClaudeActivityPhase
    var at: Double
}
struct ClaudeActivityCounters: Codable {
    var input = 0
    var output = 0
    var cacheCreation = 0
    // Absent from snapshots written before cache reads were weighed.
    var cacheRead: Int? = nil
    var total: Int { input + output + cacheCreation }
    // Output-token equivalents at list-price ratios; only the rotation speed uses it.
    var weighted: Double {
        Double(output) + Double(input) * TokenWeights.claudeInput
            + Double(cacheCreation) * TokenWeights.claudeCacheWrite + Double(cacheRead ?? 0) * TokenWeights.claudeCacheRead
    }
}
struct ClaudeActivitySnapshot: Codable {
    var schemaVersion = 1
    let sessionHash: String
    var owner: ClaudeActivityOwner
    var createdAt: Double
    var capturedAt: Double
    var phase: ClaudeActivityPhase = .idle
    var heartbeatAt: Double
    var agents: [String: ClaudeAgentActivity] = [:]
    var totalTokens = 0
    // Running output-equivalent total; absent from snapshots of older versions.
    var weightedTokens: Double? = nil
    var tokenAt: Double? = nil
    var transcriptIdentity: String? = nil
    var transcriptOffset: UInt64 = 0
    var discardingLine = false
    var requests: [String: ClaudeActivityCounters] = [:]
    var requestOrder: [String] = []
    var requestAliases: [String: String] = [:]
}

enum ClaudeActivityFiles {
    static let maximumSnapshotBytes = 128 * 1024
    static let ttl: TimeInterval = 120
    static func directory(home: URL) -> URL {
        home.appendingPathComponent(".claude/token-monitor/activity", isDirectory: true)
    }
    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func regularFile(_ url: URL) -> stat? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return info
    }
    static func boundedRead(_ url: URL, maximumBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes,
              let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes else { return nil }
        return data
    }
    static func read(_ url: URL) -> ClaudeActivitySnapshot? {
        guard let data = boundedRead(url, maximumBytes: maximumSnapshotBytes),
              let snapshot = try? JSONDecoder().decode(ClaudeActivitySnapshot.self, from: data),
              snapshot.schemaVersion == 1, validHash(snapshot.sessionHash),
              snapshot.owner.pid > 0, snapshot.owner.startedAt.isFinite, snapshot.owner.startedAt > 0,
              snapshot.createdAt.isFinite, snapshot.capturedAt.isFinite, snapshot.heartbeatAt.isFinite,
              snapshot.totalTokens >= 0, snapshot.totalTokens <= 1_000_000_000_000,
              snapshot.weightedTokens.map({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000_000 }) ?? true,
              snapshot.requests.count <= 128, snapshot.requestOrder.count <= 128,
              snapshot.requestAliases.count <= 128, snapshot.agents.count <= 64,
              snapshot.requests.allSatisfy({ validHash($0.key) && $0.value.input >= 0 && $0.value.input <= 1_000_000_000
                  && $0.value.output >= 0 && $0.value.output <= 1_000_000_000
                  && $0.value.cacheCreation >= 0 && $0.value.cacheCreation <= 1_000_000_000
                  && ($0.value.cacheRead.map { $0 >= 0 && $0 <= 1_000_000_000 } ?? true) }),
              snapshot.agents.allSatisfy({ validHash($0.key) && $0.value.at.isFinite }),
              snapshot.requestOrder.allSatisfy(validHash),
              snapshot.requestAliases.allSatisfy({ validHash($0.key) && validHash($0.value) }),
              snapshot.tokenAt.map({ $0.isFinite }) ?? true else { return nil }
        return snapshot
    }
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
    static func withLock<T>(directory: URL, name: String, body: () throws -> T) throws -> T {
        try ensureDirectory(directory)
        let lock = directory.appendingPathComponent(name + ".lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              Darwin.lockf(fd, F_LOCK, 0) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { _ = Darwin.lockf(fd, F_ULOCK, 0) }
        return try body()
    }
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var closed = false
        defer { if !closed { close(fd) }; unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        close(fd); closed = true
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func ownerIsAlive(_ owner: ClaudeActivityOwner) -> Bool {
        guard owner.pid > 0, kill(owner.pid, 0) == 0 || errno == EPERM,
              let actual = ownerForPID(owner.pid) else { return false }
        return abs(actual.startedAt - owner.startedAt) < 0.001
    }
    static func ownerForPID(_ pid: Int32) -> ClaudeActivityOwner? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ClaudeActivityOwner(pid: pid, startedAt: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }
    static func ancestorClaudeOwner() -> ClaudeActivityOwner? {
        var pid = getppid()
        for _ in 0..<16 {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let url = URL(fileURLWithPath: String(cString: path))
                let components = url.pathComponents
                // Native installs sometimes execute a version-named binary.
                if url.lastPathComponent == "claude" || ((components.contains("claude-code") || (components.contains("claude") && components.contains("versions")))
                    && url.lastPathComponent.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil) {
                    return ownerForPID(pid)
                }
            }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }
}

enum ClaudeActivityHook {
    static let events: Set<String> = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Stop", "StopFailure", "SessionEnd", "Notification", "SubagentStart", "SubagentStop"]
    static func runFromStandardInput() {
        // Always silent and nonblocking from Claude's perspective: no decisions,
        // stdout or stderr. The caller's entry point returns exit status zero.
        var data = Data()
        while data.count <= 2 * 1024 * 1024 {
            let part = FileHandle.standardInput.readData(ofLength: min(64 * 1024, 2 * 1024 * 1024 + 1 - data.count))
            if part.isEmpty { break }; data.append(part)
        }
        guard data.count <= 2 * 1024 * 1024,
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try? capture(document)
    }
    static func capture(_ document: [String: Any], at now: Date = Date(),
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                        owner suppliedOwner: ClaudeActivityOwner? = nil) throws {
        guard let event = document["hook_event_name"] as? String, events.contains(event),
              let session = document["session_id"] as? String, !session.isEmpty, session.utf8.count <= 256,
              let owner = suppliedOwner ?? ClaudeActivityFiles.ancestorClaudeOwner(), owner.pid > 0,
              owner.startedAt.isFinite, owner.startedAt > 0 else { return }
        let hash = ClaudeActivityFiles.hash(session)
        let directory = ClaudeActivityFiles.directory(home: homeDirectory)
        let url = directory.appendingPathComponent(hash + ".json")
        // Quota-only CLI sessions can emit terminal hooks. They must not create
        // activity directories, locks or idle snapshots without a task starter.
        let starters: Set<String> = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart"]
        guard starters.contains(event) || ClaudeActivityFiles.regularFile(url) != nil else { return }
        try ClaudeActivityFiles.withLock(directory: directory, name: hash) {
            let time = now.timeIntervalSince1970
            let previous = ClaudeActivityFiles.read(url)
            // A delayed callback cannot replace a newer capture; PID reuse cannot
            // preserve the old transcript cursor or old request-deduplication map.
            if let previous, previous.capturedAt > time { return }
            var snapshot = previous ?? ClaudeActivitySnapshot(sessionHash: hash, owner: owner,
                createdAt: time, capturedAt: time, heartbeatAt: time)
            if snapshot.owner != owner {
                snapshot.owner = owner; snapshot.createdAt = time
                snapshot.totalTokens = 0; snapshot.weightedTokens = 0; snapshot.tokenAt = nil
                snapshot.transcriptIdentity = nil; snapshot.transcriptOffset = 0
                snapshot.requests = [:]; snapshot.requestOrder = []; snapshot.requestAliases = [:]
                snapshot.agents = [:]; snapshot.phase = .idle
            }
            // Weighted counting starts here for snapshots of older versions; the app
            // compares weighted totals only between two snapshots that both carry one.
            if snapshot.weightedTokens == nil { snapshot.weightedTokens = 0 }
            if let path = document["transcript_path"] as? String, path.utf8.count < 4096 {
                updateUsage(URL(fileURLWithPath: path), snapshot: &snapshot, at: now)
            }
            apply(event: event, document: document, snapshot: &snapshot, at: time)
            snapshot.capturedAt = time
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= ClaudeActivityFiles.maximumSnapshotBytes else { return }
            try ClaudeActivityFiles.atomicWrite(data, to: url)
        }
    }
    private static func apply(event: String, document: [String: Any], snapshot: inout ClaudeActivitySnapshot, at time: Double) {
        let agent = (document["agent_id"] as? String).flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? ClaudeActivityFiles.hash($0) : nil }
        let notification = document["notification_type"] as? String
        let tool = document["tool_name"] as? String
        var phase: ClaudeActivityPhase? = nil
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            phase = (event == "PreToolUse" && tool == "AskUserQuestion") ? .paused : .active
        case "PostToolUseFailure": phase = (document["is_interrupt"] as? Bool == true) ? .idle : .active
        case "PermissionRequest": phase = .paused
        case "Notification":
            if notification == "permission_prompt" { phase = .paused }
            if notification == "idle_prompt" { phase = .idle }
        case "Stop", "StopFailure": phase = .idle
        case "SessionEnd": snapshot.phase = .idle; snapshot.agents = [:]; snapshot.heartbeatAt = time; return
        case "SubagentStart":
            if let agent, snapshot.agents.count < 64 || snapshot.agents[agent] != nil {
                snapshot.agents[agent] = ClaudeAgentActivity(phase: .active, at: time)
            }
            return
        case "SubagentStop": if let agent { snapshot.agents.removeValue(forKey: agent) }; return
        default: break
        }
        guard let phase else { return }
        if let agent {
            if phase == .idle { snapshot.agents.removeValue(forKey: agent) }
            else if snapshot.agents.count < 64 || snapshot.agents[agent] != nil {
                snapshot.agents[agent] = ClaudeAgentActivity(phase: phase, at: time)
            }
        } else {
            snapshot.phase = phase; snapshot.heartbeatAt = time
        }
    }
    private static func updateUsage(_ url: URL, snapshot: inout ClaudeActivitySnapshot, at now: Date) {
        guard url.pathExtension == "jsonl", let info = ClaudeActivityFiles.regularFile(url), info.st_size >= 0 else { return }
        let identity = "\(info.st_dev):\(info.st_ino)"
        let size = UInt64(info.st_size)
        guard snapshot.transcriptIdentity == identity, size >= snapshot.transcriptOffset else {
            // First observation, replacement, or truncation: baseline at EOF.
            snapshot.transcriptIdentity = identity; snapshot.transcriptOffset = size
            snapshot.discardingLine = false; snapshot.requests = [:]; snapshot.requestOrder = []; snapshot.requestAliases = [:]
            return
        }
        guard size > snapshot.transcriptOffset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: snapshot.transcriptOffset)) != nil,
              let data = try? handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return }
        var offset = 0
        while let end = data[offset...].firstIndex(of: 10) {
            let line = data[offset..<end]
            if snapshot.discardingLine { snapshot.discardingLine = false }
            else if line.count <= 512 * 1024, let document = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                consumeUsage(document, snapshot: &snapshot, at: now)
            }
            offset = end + 1
            if offset == data.count { break }
        }
        if offset == 0, data.count == 1024 * 1024 {
            // Skip an oversized record in bounded chunks, without saving its text.
            snapshot.discardingLine = true; offset = data.count
        }
        snapshot.transcriptOffset += UInt64(offset)
    }
    static func consumeUsage(_ document: [String: Any], snapshot: inout ClaudeActivitySnapshot, at now: Date) {
        guard document["type"] as? String == "assistant", let message = document["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let stamp = document["timestamp"] as? String, let date = timestamp(stamp),
              date <= now.addingTimeInterval(2) else { return }
        let messageKey = (message["id"] as? String).flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? ClaudeActivityFiles.hash("message:" + $0) : nil }
        let requestKey = (document["requestId"] as? String).flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? ClaudeActivityFiles.hash("request:" + $0) : nil }
        // An API request can appear in several content blocks. Either identifier
        // may arrive first; once linked, both resolve to the same numeric maxima.
        let linked = requestKey.flatMap { snapshot.requestAliases[$0] }
            ?? messageKey.flatMap { snapshot.requestAliases[$0] }
        let existing = requestKey.flatMap { snapshot.requests[$0] != nil ? $0 : nil }
            ?? messageKey.flatMap { snapshot.requests[$0] != nil ? $0 : nil }
        guard let key = linked ?? existing ?? requestKey ?? messageKey else { return }
        var old = snapshot.requests[key] ?? ClaudeActivityCounters()
        for alternative in [requestKey, messageKey].compactMap({ $0 }) where alternative != key {
            if let fallback = snapshot.requests.removeValue(forKey: alternative) {
                old.input = max(old.input, fallback.input); old.output = max(old.output, fallback.output)
                old.cacheCreation = max(old.cacheCreation, fallback.cacheCreation)
                if let read = fallback.cacheRead { old.cacheRead = max(old.cacheRead ?? 0, read) }
                snapshot.requestOrder.removeAll { $0 == alternative }
            }
        }
        let input = token(usage["input_tokens"]), output = token(usage["output_tokens"]), cache = token(usage["cache_creation_input_tokens"])
        let cacheRead = token(usage["cache_read_input_tokens"])
        guard input != nil || output != nil || cache != nil || cacheRead != nil else { return }
        var next = old
        next.input = max(old.input, input ?? 0); next.output = max(old.output, output ?? 0)
        next.cacheCreation = max(old.cacheCreation, cache ?? 0)
        if let cacheRead { next.cacheRead = max(old.cacheRead ?? 0, cacheRead) }
        let delta = next.total - old.total
        let weightedDelta = next.weighted - old.weighted
        if snapshot.requests[key] == nil { snapshot.requestOrder.append(key) }
        snapshot.requests[key] = next
        for alias in [requestKey, messageKey].compactMap({ $0 }) where alias != key { snapshot.requestAliases[alias] = key }
        while snapshot.requestOrder.count > 128 {
            let removed = snapshot.requestOrder.removeFirst(); snapshot.requests.removeValue(forKey: removed)
            snapshot.requestAliases = snapshot.requestAliases.filter { $0.value != removed && $0.key != removed }
        }
        if snapshot.requestAliases.count > 128 { snapshot.requestAliases = [:] }
        guard delta > 0 || weightedDelta > 0, snapshot.totalTokens <= 1_000_000_000_000 - delta,
              (snapshot.weightedTokens ?? 0) + weightedDelta <= 1_000_000_000_000 else { return }
        snapshot.totalTokens += delta
        snapshot.weightedTokens = (snapshot.weightedTokens ?? 0) + weightedDelta
        snapshot.tokenAt = max(snapshot.tokenAt ?? 0, date.timeIntervalSince1970)
    }
    private static func token(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 1_000_000_000, value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }
    private static func timestamp(_ string: String) -> Date? {
        guard string.utf8.count <= 80 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: string) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
