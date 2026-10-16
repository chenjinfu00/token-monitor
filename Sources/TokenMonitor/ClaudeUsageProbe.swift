import Foundation
import Darwin

enum ClaudeUsageError: Error {
    case executableMissing, timedOut, unavailable, invalidResponse, rateLimited, unconfirmed, serviceRejected
    case endpointUnavailable, signedOut, noSubscriptionLimits

    var message: String {
        switch self {
        case .executableMissing: return "未找到 Claude Code · 请先安装官方命令行工具"
        case .timedOut: return "Claude 额度查询超时 · 将自动重试"
        case .unavailable: return "Claude 暂未返回实时额度 · 请检查网络或现有登录"
        case .invalidResponse: return "当前 Claude Code 未返回可解析的实时额度"
        case .rateLimited: return "Claude 查询频率受限 · 稍后自动重试"
        case .unconfirmed: return "未确认 Claude 服务端更新 · 将自动重试"
        case .serviceRejected: return "Claude 用量接口暂时拒绝查询 · 稍后自动重试"
        case .endpointUnavailable: return "Claude 用量接口暂时无响应 · 将自动重试"
        case .signedOut: return "Claude Code 登录已失效 · 请重新登录"
        case .noSubscriptionLimits: return "Claude Code 当前登录不含订阅额度 · 请用 Pro/Max 等订阅账号登录"
        }
    }
}

enum ClaudeUsageProbe {
    // Once the usage payload arrives, stdin is closed and the CLI exits within
    // a fraction of a second, flushing its diagnostics. Never hold it longer.
    static let evidenceGrace: TimeInterval = 5

    // The official CLI owns its credentials and refreshes them itself. Only
    // control messages are sent: no user prompt, conversation, or model call.
    static func read(timeout: TimeInterval = 20) throws -> ProviderState {
        guard let path = ClaudeAuthProbe.executable() else { throw ClaudeUsageError.executableMissing }
        let process = Process(), input = Pipe(), output = Pipe(), diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--safe-mode", "--strict-mcp-config", "--tools", "",
            "--no-session-persistence", "--input-format", "stream-json",
            "--output-format", "stream-json", "--verbose", "--print", "--debug-to-stderr"]
        // Safe mode keeps authentication and managed policy intact, while
        // disabling user customizations and project instructions in this probe.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["DISABLE_TELEMETRY"] = "1"
        environment["DO_NOT_TRACK"] = "1"
        environment["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "false"
        // Claude classifies its quota endpoint as nonessential. This child is
        // explicitly a quota query; keep telemetry off without blocking usage.
        environment.removeValue(forKey: "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = diagnostics
        // A child may close stdin between handshake messages. Suppress SIGPIPE
        // on this pipe only so a failed write becomes a recoverable query error.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw ClaudeUsageError.unavailable
        }
        var inputClosed = false
        // Closing stdin lets the CLI exit and flush the rest of its diagnostics.
        func closeInput() {
            guard !inputClosed else { return }
            inputClosed = true
            try? input.fileHandleForWriting.close()
        }
        do { try process.run() } catch { throw ClaudeUsageError.unavailable }
        defer {
            closeInput()
            if process.isRunning {
                process.terminate()
                let stop = Date().addingTimeInterval(1)
                while process.isRunning && Date() < stop { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
            try? diagnostics.fileHandleForReading.close()
        }

        func send(id: String, subtype: String, parameters: [String: Any] = [:]) throws {
            var request: [String: Any] = ["subtype": subtype]
            for (key, value) in parameters { request[key] = value }
            let message: [String: Any] = ["type": "control_request", "request_id": id, "request": request]
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw ClaudeUsageError.unavailable }
        }
        try send(id: "tm_init", subtype: "initialize")
        var deadline = Date().addingTimeInterval(timeout)
        let fd = output.fileHandleForReading.fileDescriptor
        let diagnosticFD = diagnostics.fileHandleForReading.fileDescriptor
        var buffer = Data(), total = 0, initialized = false, outputClosed = false
        var diagnosticBuffer = Data(), diagnosticTotal = 0, diagnosticClosed = false
        var evidence = ClaudeUsageEvidence()
        var pendingUsage: [String: Any]?

        // stdout and stderr are separate pipes: a control payload can arrive
        // before its HTTP evidence. Retain it until the same bounded poll loop
        // receives confirmation; never accept cached/unconfirmed quota data.
        func confirmedUsage() throws -> ProviderState? {
            guard let pendingUsage else { return nil }
            // The CLI states that this login has no plan limits (an API key, an
            // inference-only token or no claude.ai login) and never asked the endpoint.
            if pendingUsage["rate_limits_available"] as? Bool == false { throw ClaudeUsageError.noSubscriptionLimits }
            if evidence.rateLimited { throw ClaudeUsageError.rateLimited }
            // The CLI answered from its fallback cache after the endpoint refused.
            if evidence.serviceRejected { throw ClaudeUsageError.serviceRejected }
            guard evidence.confirmedFresh else { return nil }
            // A snapshot answer is stamped with its server confirmation time.
            return try ClaudeUsageParser.parse(pendingUsage, at: Date().addingTimeInterval(-evidence.confirmationAge))
        }

        func drainDiagnostics() throws {
            while !diagnosticClosed {
                var descriptor = pollfd(fd: diagnosticFD, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 0) > 0 else { break }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(diagnosticFD, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 {
                    diagnosticClosed = true
                    if !diagnosticBuffer.isEmpty {
                        evidence.observe(String(decoding: diagnosticBuffer, as: UTF8.self))
                        diagnosticBuffer.removeAll(keepingCapacity: false)
                    }
                    evidence.finish()
                    break
                }
                diagnosticTotal += count
                // Debug output only covers the CLI's own startup; keep a generous bound.
                guard diagnosticTotal <= 8_388_608 else { throw ClaudeUsageError.invalidResponse }
                diagnosticBuffer.append(contentsOf: chunk.prefix(count))
                while let newline = diagnosticBuffer.firstIndex(of: 10) {
                    let line = String(decoding: diagnosticBuffer[..<newline], as: UTF8.self)
                    diagnosticBuffer.removeSubrange(...newline)
                    evidence.observe(line)
                }
                // Only the whitelist evidence survives; no logs go to disk,
                // the widget, or its callers. Bound a malformed partial line.
                guard diagnosticBuffer.count <= 16_384 else { throw ClaudeUsageError.invalidResponse }
            }
        }
        while Date() < deadline {
            var descriptors = [pollfd(fd: outputClosed ? -1 : fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: diagnosticClosed ? -1 : diagnosticFD, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 250)
            if ready < 0 { if errno == EINTR { continue }; throw ClaudeUsageError.unavailable }
            if ready == 0 { continue }
            try drainDiagnostics()
            if let state = try confirmedUsage() { return state }
            if pendingUsage != nil && diagnosticClosed { throw evidence.unconfirmedError }
            guard descriptors[0].revents != 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 {
                outputClosed = true
                if pendingUsage == nil { throw ClaudeUsageError.unavailable }
                continue
            }
            total += count
            guard total <= 1_048_576 else { throw ClaudeUsageError.invalidResponse }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      item["type"] as? String == "control_response",
                      let response = item["response"] as? [String: Any],
                      let id = response["request_id"] as? String,
                      id == "tm_init" || id == "tm_usage" else { continue }
                guard response["subtype"] as? String == "success" else {
                    // Classify only; never display raw CLI output or account data.
                    let error = response["error"] as? String ?? ""
                    if error.contains("429") || error.lowercased().contains("rate limit") { throw ClaudeUsageError.rateLimited }
                    throw ClaudeUsageError.unavailable
                }
                if id == "tm_init", !initialized {
                    initialized = true
                    // A usage meter needs only plan limits: skip the CLI's scan of
                    // every transcript touched in the last seven days.
                    try send(id: "tm_usage", subtype: "get_usage", parameters: ["skip_behaviors": true])
                } else if id == "tm_usage", initialized, let result = response["response"] as? [String: Any] {
                    pendingUsage = result
                    closeInput()
                    deadline = min(deadline, Date().addingTimeInterval(evidenceGrace))
                    try drainDiagnostics()
                    if let state = try confirmedUsage() { return state }
                    if diagnosticClosed { throw evidence.unconfirmedError }
                }
            }
        }
        if pendingUsage != nil { throw evidence.unconfirmedError }
        throw ClaudeUsageError.timedOut
    }
}

struct ClaudeUsageEvidence {
    // Claude Code 2.1.25x+ persists each confirmed reading and answers a read
    // within 60 seconds from it without asking the endpoint again. That answer
    // is still server-confirmed, just slightly older; long-cached ones are not.
    static let maximumSnapshotAge: TimeInterval = 300
    private static let snapshotPattern = try? NSRegularExpression(
        pattern: "Usage read answered from a snapshot ([0-9]{1,7})s old; endpoint not asked")
    private var successfulRequest = false
    private var snapshotAge: TimeInterval?
    private var unusableResponse = false
    private(set) var rateLimited = false
    // The endpoint refused this account (403) or answered with an in-band error
    // envelope such as a rate limit; querying again right away prolongs it.
    private(set) var serviceRejected = false
    private var authenticationFailed = false
    // The CLI asked the endpoint but got no HTTP answer (timeout, DNS, proxy or
    // TLS failure) or a server error, and answered from its own cache instead.
    private var requestAttempted = false
    private var transportFailed = false
    // The CLI has exited and every diagnostic line has been read.
    private var complete = false
    var confirmedFresh: Bool {
        (successfulRequest || snapshotAge != nil) && !unusableResponse && !rateLimited && !serviceRejected
    }
    // Why an answer had no freshness evidence, as far as the diagnostics tell.
    var unconfirmedError: ClaudeUsageError {
        if authenticationFailed { return .signedOut }
        // A request line without its success line, once all output is in, failed.
        if transportFailed || (complete && requestAttempted && !successfulRequest) { return .endpointUnavailable }
        return .unconfirmed
    }
    // Seconds between the confirming server response and this read.
    var confirmationAge: TimeInterval { successfulRequest ? 0 : (snapshotAge ?? 0) }

    mutating func finish() { complete = true }

    mutating func observe(_ line: String) {
        if line.range(of: "fetchUtilization: 200 after [0-9]+ attempt\\(s\\)", options: .regularExpression) != nil {
            successfulRequest = true
        }
        if let pattern = Self.snapshotPattern,
           let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let digits = Range(match.range(at: 1), in: line),
           let seconds = Double(String(line[digits])), seconds <= Self.maximumSnapshotAge {
            snapshotAge = seconds
        }
        let lower = line.lowercased()
        let failedLoad = lower.contains("failed to load usage data")
        if lower.contains("fetchutilization: get ") { requestAttempted = true }
        if lower.contains("fieldless or non-object body") || failedLoad {
            unusableResponse = true
        }
        if (lower.contains("fetchutilization") || failedLoad) && lower.contains("429") {
            rateLimited = true
        }
        // 403 now, or one remembered from earlier in this CLI process ("answered 403").
        let forbidden = lower.contains("status code 403") || lower.contains("answered 403")
            || (lower.contains("fetchutilization: 403") && lower.contains("remembered for this bearer"))
        if lower.contains("non-object body (in-band error)")
            || (forbidden && (failedLoad || lower.contains("fetchutilization"))) {
            serviceRejected = true
        }
        if failedLoad && (lower.contains("auth error") || lower.contains("status code 401")
            || lower.contains("answered 401")) {
            authenticationFailed = true
        } else if failedLoad && !lower.contains("429") && !forbidden {
            // The CLI logs this for failures without an HTTP answer.
            transportFailed = true
        }
    }
}

enum ClaudeUsageParser {
    static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Foundation's fractional formatter truncates to milliseconds. Parse
        // the integral ISO date and add the API's original fraction instead.
        if let expression = try? NSRegularExpression(pattern: "\\.([0-9]{1,9})(?=Z$|[+-][0-9]{2}:[0-9]{2}$)"),
           let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range, in: value), let digits = Range(match.range(at: 1), in: value),
           let fraction = Double("0." + value[digits]),
           let whole = formatter.date(from: value.replacingCharacters(in: range, with: "")) {
            return whole.addingTimeInterval(fraction)
        }
        return formatter.date(from: value)
    }

    static func parse(_ result: [String: Any], at now: Date = Date()) throws -> ProviderState {
        guard result["rate_limits_available"] as? Bool == true,
              let limits = result["rate_limits"] as? [String: Any] else { throw ClaudeUsageError.unavailable }
        var state = ProviderState(name: "Claude · 实时", updatedAt: now)
        for (key, name, duration) in [("five_hour", "5小时额度", 18000.0),
            ("seven_day", "每周额度", 604800.0), ("seven_day_sonnet", "Sonnet · 每周额度", 604800.0),
            ("seven_day_opus", "Opus · 每周额度", 604800.0)] {
            guard let window = limits[key] as? [String: Any],
                  let used = QuotaParser.number(window["utilization"]), used >= 0, used <= 100 else { continue }
            state.windows.append(QuotaWindow(id: key, name: name, usedPercent: used,
                resetsAt: date(window["resets_at"]), durationSeconds: duration))
        }
        // New server responses can provide a session limit in limits[] while
        // the legacy five_hour field is null. Never turn absent quotas into 0.
        if !state.windows.contains(where: { $0.id == "five_hour" }),
           let entries = limits["limits"] as? [[String: Any]],
           let window = entries.first(where: { $0["kind"] as? String == "session" }),
           let used = QuotaParser.number(window["percent"]), used >= 0, used <= 100 {
            state.windows.insert(QuotaWindow(id: "five_hour", name: "5小时额度", usedPercent: used,
                resetsAt: date(window["resets_at"]), durationSeconds: 18000), at: 0)
        }
        if !state.windows.contains(where: { $0.id == "seven_day" }),
           let entries = limits["limits"] as? [[String: Any]],
           let window = entries.first(where: { $0["kind"] as? String == "weekly_all" }),
           let used = QuotaParser.number(window["percent"]), used >= 0, used <= 100 {
            state.windows.append(QuotaWindow(id: "seven_day", name: "每周额度", usedPercent: used,
                resetsAt: date(window["resets_at"]), durationSeconds: 604800))
        }
        guard !state.windows.isEmpty else { throw ClaudeUsageError.invalidResponse }
        return state
    }
}
