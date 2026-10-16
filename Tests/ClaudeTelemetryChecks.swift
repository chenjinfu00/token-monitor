import Foundation
import Network

// All fixtures are synthetic: a temporary home folder and a loopback receiver on a
// random port. These checks never read real Claude settings or contact a network.
@main
struct ClaudeTelemetryChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }

    static func main() throws {
        framingHandlesSplitPipelinedAndChunkedRequests()
        parserKeepsOnlyCountsAndHashedSessions()
        snapshotMergeReplacesTranscriptEstimates()
        try installerOwnsOnlyItsKeys()
        receiverAcceptsLoopbackExport()
        print("PASS 5 Claude telemetry groups: HTTP framing, OTLP parsing, merge precedence, settings ownership and loopback receiver")
    }

    static func request(_ body: String, headers: String = "") -> String {
        "POST /v1/logs HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\(headers)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    static func framingHandlesSplitPipelinedAndChunkedRequests() {
        let whole = request("{\"a\":1}")
        var buffer = Data(whole.utf8.prefix(20))
        require(TelemetryHTTPFraming.next(from: &buffer) == .needMore, "A partial header waits for more bytes")
        buffer.append(contentsOf: Array(whole.utf8.dropFirst(20)))
        guard case .request(let first) = TelemetryHTTPFraming.next(from: &buffer) else {
            preconditionFailure("A complete request is framed")
        }
        require(first.method == "POST" && first.path == "/v1/logs" && first.body == Data("{\"a\":1}".utf8)
            && !first.closesConnection && !first.isCompressed && buffer.isEmpty, "Content-Length framing")

        var pipelined = Data((request("{}") + request("[1]", headers: "Connection: close\r\n")).utf8)
        guard case .request(let one) = TelemetryHTTPFraming.next(from: &pipelined),
              case .request(let two) = TelemetryHTTPFraming.next(from: &pipelined) else {
            preconditionFailure("Pipelined requests are framed in order")
        }
        require(one.body == Data("{}".utf8) && two.body == Data("[1]".utf8) && two.closesConnection,
            "Pipelined bodies and Connection: close")
        require(TelemetryHTTPFraming.next(from: &pipelined) == .needMore, "Nothing remains after both requests")

        var chunked = Data("POST /v1/logs HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nabcd\r\n2;x=y\r\nef\r\n0\r\n\r\n".utf8)
        guard case .request(let decoded) = TelemetryHTTPFraming.next(from: &chunked) else {
            preconditionFailure("Chunked request is decoded")
        }
        require(decoded.body == Data("abcdef".utf8) && chunked.isEmpty, "Chunked body and extension")
        var trailers = Data(("POST /v1/logs HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nxyz\r\n0\r\nX-Check: 1\r\n\r\n"
            + request("{}")).utf8)
        guard case .request(let withTrailers) = TelemetryHTTPFraming.next(from: &trailers),
              case .request(let following) = TelemetryHTTPFraming.next(from: &trailers) else {
            preconditionFailure("Trailer fields end with the empty line, then the next request starts")
        }
        require(withTrailers.body == Data("xyz".utf8) && following.body == Data("{}".utf8) && trailers.isEmpty,
            "Chunked trailers are consumed")
        var endless = Data(("POST /v1/logs HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "1", count: 2048)).utf8)
        require(TelemetryHTTPFraming.next(from: &endless) == .invalid, "An endless chunk-size line is refused")

        var huge = Data("POST /v1/logs HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)
        require(TelemetryHTTPFraming.next(from: &huge) == .tooLarge, "Oversized body is refused")
        var garbage = Data("NONSENSE\r\n\r\n".utf8)
        require(TelemetryHTTPFraming.next(from: &garbage) == .invalid, "Malformed request line is refused")
        var gzip = Data(request("x", headers: "Content-Encoding: gzip\r\n").utf8)
        guard case .request(let compressed) = TelemetryHTTPFraming.next(from: &gzip) else {
            preconditionFailure("Compressed request is framed")
        }
        require(compressed.isCompressed, "Compressed bodies are flagged, not parsed")
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // One exported batch: an API request, a prompt event named only by its body,
    // and a record without a session, which must be ignored.
    static func payload(at date: Date) -> String {
        let nanos = String(Int64((date.timeIntervalSince1970 + 1) * 1_000_000_000))
        return """
        {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}},
          {"key":"user.email","value":{"stringValue":"someone@example.com"}}]},
         "scopeLogs":[{"scope":{"name":"com.anthropic.claude_code.events"},"logRecords":[
          {"timeUnixNano":"\(nanos)","body":{"stringValue":"claude_code.api_request"},"attributes":[
            {"key":"event.name","value":{"stringValue":"api_request"}},
            {"key":"session.id","value":{"stringValue":"session-a"}},
            {"key":"event.timestamp","value":{"stringValue":"\(iso(date))"}},
            {"key":"input_tokens","value":{"intValue":100}},
            {"key":"output_tokens","value":{"intValue":"50"}},
            {"key":"cache_creation_tokens","value":{"doubleValue":25}},
            {"key":"cache_read_tokens","value":{"intValue":9000}},
            {"key":"prompt","value":{"stringValue":"<REDACTED>"}}]},
          {"timeUnixNano":"\(nanos)","body":{"stringValue":"claude_code.user_prompt"},"attributes":[
            {"key":"session.id","value":{"stringValue":"session-b"}}]},
          {"body":{"stringValue":"claude_code.api_request"},"attributes":[
            {"key":"input_tokens","value":{"intValue":7}}]}
         ]}]}]}
        """
    }

    static func parserKeepsOnlyCountsAndHashedSessions() {
        let sent = Date(timeIntervalSince1970: 1_791_983_314.077)
        let now = sent.addingTimeInterval(30)
        let events = ClaudeTelemetryParser.events(from: Data(payload(at: sent).utf8), now: now)
        require(events.count == 2, "Records without a session are ignored: \(events.count)")
        let api = events[0], prompt = events[1]
        require(api.name == "api_request" && api.tokens == 175, "Input, output and cache writes count; cache reads do not: \(api.tokens)")
        require(abs(api.weightedTokens - 256.25) < 0.001,
            "Speed weight: output 50 + input 100/5 + cache writes 25/4 + cache reads 9000/50: \(api.weightedTokens)")
        require(api.sessionID == ClaudeActivityFiles.hash("session-a") && api.sessionID.count == 64, "Sessions are hashed")
        require(abs(api.at.timeIntervalSince(sent)) < 0.01, "event.timestamp is preferred: \(api.at.timeIntervalSince1970)")
        require(prompt.name == "user_prompt" && prompt.tokens == 0, "The body names an event without event.name")
        require(abs(prompt.at.timeIntervalSince(sent) - 1) < 0.01, "timeUnixNano is the fallback")
        require(ClaudeTelemetryParser.events(from: Data("not json".utf8)).isEmpty, "Malformed bodies yield nothing")
        let early = Date(timeIntervalSince1970: 1_000)
        let clamped = ClaudeTelemetryParser.events(from: Data(payload(at: sent).utf8), now: early)
        require(clamped.allSatisfy { $0.at <= early.addingTimeInterval(2) }, "Future timestamps are clamped")
    }

    static func snapshotMergeReplacesTranscriptEstimates() {
        let now = Date()
        let a = ClaudeActivityFiles.hash("session-a"), b = ClaudeActivityFiles.hash("session-b")
        var reading = ProviderActivityReading()
        reading.runningSessionIDs = [a]
        reading.tokenDeltas = [ActivityTokenDelta(sessionID: a, at: now, tokens: 999),
                               ActivityTokenDelta(sessionID: b, at: now, tokens: 5)]
        var snapshot = ClaudeTelemetrySnapshot()
        snapshot.knownSessionIDs = [a]
        snapshot.recentSessionIDs = [a]
        snapshot.tokenDeltas = [ActivityTokenDelta(sessionID: a, at: now, tokens: 175)]
        snapshot.lastEventAt = now
        let withHooks = snapshot.merged(into: reading, hooksEnabled: true)
        require(withHooks.tokenDeltas.map(\.tokens).sorted() == [5, 175], "Telemetry replaces only its own sessions' estimates")
        require(withHooks.runningSessionIDs == [a] && withHooks.lastTaskEventAt == nil, "Hooks keep lifecycle ownership")
        var idle = ProviderActivityReading()
        idle.tokenDeltas = []
        let withoutHooks = snapshot.merged(into: idle, hooksEnabled: false)
        require(withoutHooks.runningSessionIDs == [a] && withoutHooks.lastTaskEventAt == nil,
            "Without hooks, recent events mean activity, but a pause between exports is not a Stop")
        require(ClaudeTelemetrySnapshot().merged(into: reading, hooksEnabled: false).tokenDeltas.count == 2, "No telemetry leaves estimates")
    }

    static func installerOwnsOnlyItsKeys() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-checks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        func write(_ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: settingsURL)
        }
        func read() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] ?? [:]
        }
        try write(["model": "x", "env": ["FOO": "bar", "CLAUDE_CODE_ENABLE_TELEMETRY": "1"]])
        require(ClaudeTelemetryInstaller.install(homeDirectory: home, port: 47318) == nil, "Install into existing env")
        var env = try read()["env"] as? [String: String] ?? [:]
        require(env["FOO"] == "bar" && env["OTEL_LOGS_EXPORTER"] == "otlp"
            && env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] == "http://127.0.0.1:47318/v1/logs", "Wanted keys are added")
        let model = try read()["model"] as? String
        require(model == "x", "Other settings are kept")
        let written = String(decoding: try Data(contentsOf: settingsURL), as: UTF8.self)
        require(written.contains("http://127.0.0.1:47318/v1/logs"), "Settings stay readable: slashes are not escaped")
        require(ClaudeTelemetryInstaller.install(homeDirectory: home, port: 47318) == nil, "Installing again is idempotent")
        require(ClaudeTelemetryInstaller.install(homeDirectory: home, port: 47319) == nil, "An owned endpoint can move")
        env = try read()["env"] as? [String: String] ?? [:]
        require(env["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"] == "http://127.0.0.1:47319/v1/logs", "Owned value follows the port")
        require(ClaudeTelemetryInstaller.uninstall(homeDirectory: home) == nil, "Uninstall")
        env = try read()["env"] as? [String: String] ?? [:]
        require(env == ["FOO": "bar", "CLAUDE_CODE_ENABLE_TELEMETRY": "1"], "Only installed values are removed: \(env)")

        try write(["env": ["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://collector.example:4318/v1/logs"]])
        let before = try Data(contentsOf: settingsURL)
        let failure = ClaudeTelemetryInstaller.install(homeDirectory: home, port: 47318)
        require(failure?.contains("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT") == true, "A user's own collector is a conflict")
        let after = try Data(contentsOf: settingsURL)
        require(after == before, "A conflict changes nothing")
        try write(["env": "not an object"])
        require(ClaudeTelemetryInstaller.install(homeDirectory: home, port: 47318) != nil, "An invalid env is refused")
    }

    final class Box { var value: String? = nil }

    static func receiverAcceptsLoopbackExport() {
        let port = UInt16(40_000 + Int.random(in: 0..<20_000))
        let receiver = ClaudeTelemetryReceiver(port: port)
        receiver.start()
        defer { receiver.stop() }
        let ready = Date().addingTimeInterval(5)
        while receiver.diagnosticSnapshot()["listening"] as? Bool != true && Date() < ready { usleep(20_000) }
        require(receiver.diagnosticSnapshot()["listening"] as? Bool == true, "Receiver listens on loopback")
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { preconditionFailure("Valid test port") }
        let connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort, using: .tcp)
        let reply = Box()
        let done = DispatchSemaphore(value: 0)
        let message = Data(request(payload(at: Date())).utf8)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: message, completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                        reply.value = data.map { String(decoding: $0, as: UTF8.self) }
                        done.signal()
                    }
                })
            case .failed, .cancelled:
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "telemetry-check-client"))
        _ = done.wait(timeout: .now() + 5)
        connection.cancel()
        require(reply.value?.hasPrefix("HTTP/1.1 200 OK") == true, "Exporter receives success: \(reply.value ?? "nil")")
        let snapshot = receiver.snapshot(at: Date())
        require(snapshot.tokenDeltas.map(\.tokens) == [175], "Token counts are kept: \(snapshot.tokenDeltas)")
        require(snapshot.knownSessionIDs.count == 2, "Both exporting sessions are known")
    }
}
