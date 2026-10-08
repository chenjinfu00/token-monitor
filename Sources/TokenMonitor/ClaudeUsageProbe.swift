import Foundation
import Darwin

enum ClaudeUsageError: Error {
    case executableMissing, timedOut, unavailable, invalidResponse, rateLimited, unconfirmed

    var message: String {
        switch self {
        case .executableMissing: return "未找到 Claude Code · 请先安装官方命令行工具"
        case .timedOut: return "Claude 额度查询超时 · 将自动重试"
        case .unavailable: return "Claude 暂未返回实时额度 · 请检查网络或现有登录"
        case .invalidResponse: return "当前 Claude Code 未返回可解析的实时额度"
        case .rateLimited: return "Claude 查询频率受限 · 稍后自动重试"
        case .unconfirmed: return "未确认 Claude 服务端更新 · 将自动重试"
        }
    }
}

enum ClaudeUsageProbe {
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
        do { try process.run() } catch { throw ClaudeUsageError.unavailable }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let stop = Date().addingTimeInterval(1)
                while process.isRunning && Date() < stop { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
            try? diagnostics.fileHandleForReading.close()
        }

        func send(id: String, subtype: String) throws {
            var data = try JSONSerialization.data(withJSONObject: [
                "type": "control_request", "request_id": id, "request": ["subtype": subtype]
            ])
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(id: "tm_init", subtype: "initialize")
        let deadline = Date().addingTimeInterval(timeout)
        let fd = output.fileHandleForReading.fileDescriptor
        let diagnosticFD = diagnostics.fileHandleForReading.fileDescriptor
        var buffer = Data(), total = 0, initialized = false
        var diagnosticBuffer = Data(), diagnosticTotal = 0, diagnosticClosed = false
        var evidence = ClaudeUsageEvidence()

        func drainDiagnostics() throws {
            while !diagnosticClosed {
                var descriptor = pollfd(fd: diagnosticFD, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 0) > 0 else { break }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(diagnosticFD, &chunk, chunk.count)
                if count <= 0 { diagnosticClosed = true; break }
                diagnosticTotal += count
                guard diagnosticTotal <= 1_048_576 else { throw ClaudeUsageError.invalidResponse }
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
            var descriptors = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: diagnosticClosed ? -1 : diagnosticFD, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&descriptors, nfds_t(descriptors.count), 250)
            if ready < 0 { if errno == EINTR { continue }; throw ClaudeUsageError.unavailable }
            if ready == 0 { continue }
            try drainDiagnostics()
            guard descriptors[0].revents != 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { throw ClaudeUsageError.unavailable }
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
                    try send(id: "tm_usage", subtype: "get_usage")
                } else if id == "tm_usage", initialized, let result = response["response"] as? [String: Any] {
                    try drainDiagnostics()
                    if evidence.rateLimited { throw ClaudeUsageError.rateLimited }
                    guard evidence.confirmedFresh else { throw ClaudeUsageError.unconfirmed }
                    return try ClaudeUsageParser.parse(result)
                }
            }
        }
        throw ClaudeUsageError.timedOut
    }
}

struct ClaudeUsageEvidence {
    private var successfulRequest = false
    private var unusableResponse = false
    private(set) var rateLimited = false
    var confirmedFresh: Bool { successfulRequest && !unusableResponse && !rateLimited }

    mutating func observe(_ line: String) {
        if line.range(of: "fetchUtilization: 200 after [0-9]+ attempt\\(s\\)", options: .regularExpression) != nil {
            successfulRequest = true
        }
        let lower = line.lowercased()
        if lower.contains("fieldless or non-object body") || lower.contains("failed to load usage data") {
            unusableResponse = true
        }
        if (lower.contains("fetchutilization") || lower.contains("failed to load usage data")) && lower.contains("429") {
            rateLimited = true
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
