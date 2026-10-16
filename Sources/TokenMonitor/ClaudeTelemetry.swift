import Foundation
import CoreFoundation
import Network

// Optional and explicitly enabled: Claude Code's documented OpenTelemetry events,
// exported as OTLP/HTTP JSON to a loopback-only receiver. Only event names, hashed
// session IDs, timestamps and token counts are kept, in memory. Claude Code redacts
// prompts by default, and every other attribute (account, e-mail, model details)
// is dropped while parsing. Nothing from these events is written to disk.

struct ClaudeTelemetryEvent: Equatable {
    let name: String
    let sessionID: String
    let at: Date
    let tokens: Int
    // Output-token equivalents, cache reads included, for the rotation speed.
    var weightedTokens: Double = 0
}

enum ClaudeTelemetryParser {
    static let maximumEvents = 4096

    static func events(from body: Data, now: Date = Date()) -> [ClaudeTelemetryEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let resourceLogs = root["resourceLogs"] as? [[String: Any]] else { return [] }
        var result: [ClaudeTelemetryEvent] = []
        for resourceLog in resourceLogs {
            let resource = resourceLog["resource"] as? [String: Any]
            let shared = attributes(resource?["attributes"])
            for scopeLog in resourceLog["scopeLogs"] as? [[String: Any]] ?? [] {
                for record in scopeLog["logRecords"] as? [[String: Any]] ?? [] {
                    var values = shared
                    for (key, value) in attributes(record["attributes"]) { values[key] = value }
                    let bodyName = (record["body"] as? [String: Any])?["stringValue"] as? String
                    var name = (values["event.name"] as? String) ?? bodyName ?? ""
                    if name.hasPrefix("claude_code.") { name = String(name.dropFirst("claude_code.".count)) }
                    guard !name.isEmpty, name.utf8.count <= 64,
                          let session = values["session.id"] as? String,
                          !session.isEmpty, session.utf8.count <= 256 else { continue }
                    let at = isoDate(values["event.timestamp"]) ?? unixNanos(record["timeUnixNano"]) ?? now
                    var tokens = 0
                    var weighted = 0.0
                    if name == "api_request" {
                        // The raw count leaves out cache reads (reused context); the
                        // speed weight includes them at their price relative to output.
                        for key in ["input_tokens", "output_tokens", "cache_creation_tokens"] {
                            tokens += count(values[key]) ?? 0
                        }
                        weighted = Double(count(values["output_tokens"]) ?? 0)
                            + Double(count(values["input_tokens"]) ?? 0) * TokenWeights.claudeInput
                            + Double(count(values["cache_creation_tokens"]) ?? 0) * TokenWeights.claudeCacheWrite
                            + Double(count(values["cache_read_tokens"]) ?? 0) * TokenWeights.claudeCacheRead
                    }
                    result.append(ClaudeTelemetryEvent(name: name, sessionID: ClaudeActivityFiles.hash(session),
                        at: min(at, now.addingTimeInterval(2)), tokens: tokens, weightedTokens: weighted))
                    if result.count >= maximumEvents { return result }
                }
            }
        }
        return result
    }

    // OTLP AnyValue: strings, integers (a JSON number or a decimal string) and doubles.
    static func attributes(_ value: Any?) -> [String: Any] {
        var result: [String: Any] = [:]
        for item in value as? [[String: Any]] ?? [] {
            guard let key = item["key"] as? String, key.utf8.count <= 128,
                  let any = item["value"] as? [String: Any] else { continue }
            if let string = any["stringValue"] as? String { result[key] = string }
            else if let integer = any["intValue"] { result[key] = integer }
            else if let double = any["doubleValue"] { result[key] = double }
        }
        return result
    }

    static func count(_ value: Any?) -> Int? {
        let number: Double
        if let string = value as? String, let parsed = Double(string) { number = parsed }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
        else { return nil }
        guard number.isFinite, number >= 0, number <= 1_000_000_000,
              number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let wholeSecondISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func isoDate(_ value: Any?) -> Date? {
        guard let string = value as? String, string.utf8.count <= 64 else { return nil }
        return fractionalISOFormatter.date(from: string) ?? wholeSecondISOFormatter.date(from: string)
    }

    static func unixNanos(_ value: Any?) -> Date? {
        let nanos: Double
        if let string = value as? String, let parsed = Double(string) { nanos = parsed }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { nanos = number.doubleValue }
        else { return nil }
        guard nanos.isFinite, nanos > 0 else { return nil }
        return Date(timeIntervalSince1970: nanos / 1_000_000_000)
    }
}

// Minimal HTTP/1.1 request framing for the OTLP exporter: Content-Length or chunked
// bodies, keep-alive and pipelining. Bounded so a local client cannot grow memory.
enum TelemetryHTTPFraming {
    struct Request: Equatable {
        let method: String
        let path: String
        let body: Data
        let closesConnection: Bool
        let isCompressed: Bool
    }
    enum Step: Equatable { case needMore, invalid, tooLarge, request(Request) }
    static let maximumHeaderBytes = 16_384
    static let maximumBodyBytes = 8_388_608

    static func next(from buffer: inout Data) -> Step {
        let bytes = [UInt8](buffer)
        guard let headerEnd = find([13, 10, 13, 10], in: bytes, from: 0) else {
            return bytes.count > maximumHeaderBytes ? .tooLarge : .needMore
        }
        guard headerEnd <= maximumHeaderBytes else { return .tooLarge }
        var lines = String(decoding: bytes[0..<headerEnd], as: UTF8.self).components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body: [UInt8] = []
        var consumed = headerEnd + 4
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var index = consumed
            while true {
                guard let lineEnd = find([13, 10], in: bytes, from: index) else {
                    // A chunk-size line is short; never buffer an endless one.
                    return bytes.count - index > 1024 ? .invalid : .needMore
                }
                let sizeField = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
                    .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !sizeField.isEmpty, sizeField.utf8.count <= 8,
                      let size = Int(sizeField, radix: 16), size >= 0 else { return .invalid }
                let dataStart = lineEnd + 2
                if size == 0 {
                    // Optional trailer fields, then the empty line that ends the message.
                    var cursor = dataStart
                    while true {
                        guard let end = find([13, 10], in: bytes, from: cursor) else {
                            return bytes.count - dataStart > maximumHeaderBytes ? .tooLarge : .needMore
                        }
                        let isEmptyLine = end == cursor
                        cursor = end + 2
                        if isEmptyLine { break }
                    }
                    consumed = cursor
                    break
                }
                guard body.count + size <= maximumBodyBytes else { return .tooLarge }
                guard bytes.count >= dataStart + size + 2 else { return .needMore }
                body.append(contentsOf: bytes[dataStart..<(dataStart + size)])
                index = dataStart + size + 2
            }
        } else {
            guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .invalid }
            guard length <= maximumBodyBytes else { return .tooLarge }
            guard bytes.count >= consumed + length else { return .needMore }
            body = Array(bytes[consumed..<(consumed + length)])
            consumed += length
        }
        buffer = Data(bytes[consumed...])
        let connection = headers["connection"]?.lowercased() ?? ""
        let closes = connection.contains("close") || (start[2] == "HTTP/1.0" && !connection.contains("keep-alive"))
        let encoding = headers["content-encoding"]?.lowercased() ?? ""
        return .request(Request(method: String(start[0]), path: String(start[1]), body: Data(body),
            closesConnection: closes, isCompressed: !(encoding.isEmpty || encoding == "identity")))
    }

    static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard !pattern.isEmpty, start >= 0, bytes.count >= pattern.count else { return nil }
        var index = start
        while index <= bytes.count - pattern.count {
            var matches = true
            for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
                matches = false
                break
            }
            if matches { return index }
            index += 1
        }
        return nil
    }
}

struct ClaudeTelemetrySnapshot {
    var tokenDeltas: [ActivityTokenDelta] = []
    // Sessions that exported any event in the last ten minutes, and in the last 20 seconds.
    var knownSessionIDs: Set<String> = []
    var recentSessionIDs: Set<String> = []
    var lastEventAt: Date? = nil

    // Exact per-request counts replace transcript estimates for sessions that export
    // telemetry. Without lifecycle hooks, recent events also mark a running task.
    // Exports have no Stop event, so a pause between them is never reported as the
    // end of a task (that would retire quota-based activity while work continues).
    func merged(into reading: ProviderActivityReading, hooksEnabled: Bool) -> ProviderActivityReading {
        var result = reading
        if !knownSessionIDs.isEmpty {
            result.tokenDeltas = reading.tokenDeltas.filter { !knownSessionIDs.contains($0.sessionID) } + tokenDeltas
        }
        if !hooksEnabled { result.runningSessionIDs.formUnion(recentSessionIDs) }
        return result
    }
}

final class ClaudeTelemetryReceiver {
    static let enabledKey = "claudeTelemetryEnabled"
    static let defaultPort: UInt16 = 47318
    static var configuredPort: UInt16 {
        if let text = ProcessInfo.processInfo.environment["TOKEN_MONITOR_TELEMETRY_PORT"],
           let port = UInt16(text), port >= 1024 { return port }
        return defaultPort
    }
    static let shared = ClaudeTelemetryReceiver(port: configuredPort)
    static func logsEndpoint(port: UInt16 = configuredPort) -> String { "http://127.0.0.1:\(port)/v1/logs" }

    let port: UInt16
    private let queue = DispatchQueue(label: "local.tokenmonitor.telemetry", qos: .utility)
    private let lock = NSLock()
    // Listener and connections belong to `queue`; the rest is guarded by `lock`.
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var onEvent: (() -> Void)?
    private var deltas: [ActivityTokenDelta] = []
    private var lastSeen: [String: Date] = [:]
    private var listening = false
    private var receivedBatches = 0

    init(port: UInt16) { self.port = port }

    func start(onEvent: (() -> Void)? = nil) {
        lock.lock()
        if let onEvent { self.onEvent = onEvent }
        lock.unlock()
        queue.async { self.openListener() }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
        lock.lock()
        onEvent = nil
        deltas.removeAll()
        lastSeen.removeAll()
        listening = false
        lock.unlock()
    }

    func snapshot(at now: Date = Date()) -> ClaudeTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        prune(at: now)
        var snapshot = ClaudeTelemetrySnapshot()
        snapshot.tokenDeltas = deltas.filter { $0.at > now.addingTimeInterval(-60) }
        for (session, at) in lastSeen {
            snapshot.knownSessionIDs.insert(session)
            if at > now.addingTimeInterval(-20) { snapshot.recentSessionIDs.insert(session) }
            if at > (snapshot.lastEventAt ?? .distantPast) { snapshot.lastEventAt = at }
        }
        return snapshot
    }

    func diagnosticSnapshot(at now: Date = Date()) -> [String: Any] {
        let current = snapshot(at: now)
        lock.lock()
        defer { lock.unlock() }
        return ["listening": listening, "port": Int(port), "receivedBatches": receivedBatches,
                "knownSessions": current.knownSessionIDs.count, "recentSessions": current.recentSessionIDs.count,
                "lastEventAt": current.lastEventAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()]
    }

    private func setListening(_ value: Bool) {
        lock.lock()
        listening = value
        lock.unlock()
    }

    private func prune(at now: Date) {
        deltas.removeAll { $0.at < now.addingTimeInterval(-120) }
        if deltas.count > 4096 { deltas.removeFirst(deltas.count - 4096) }
        if !lastSeen.isEmpty { lastSeen = lastSeen.filter { $0.value > now.addingTimeInterval(-600) } }
    }

    private func openListener() {
        guard listener == nil, let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: no other machine can reach this receiver.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: endpointPort)
        guard let created = try? NWListener(using: parameters) else { return }
        created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        created.stateUpdateHandler = { [weak self, weak created] state in
            guard let self, let created else { return }
            switch state {
            case .ready:
                if self.listener === created { self.setListening(true) }
            case .failed, .waiting:
                // For example a busy port. A listener must be cancelled to be
                // released; the activity monitor's next read opens a new one.
                created.cancel()
            case .cancelled:
                if self.listener === created {
                    self.listener = nil
                    self.setListening(false)
                }
            default:
                break
            }
        }
        listener = created
        created.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 64 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] content, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let content { buffer.append(content) }
            while true {
                switch TelemetryHTTPFraming.next(from: &buffer) {
                case .needMore:
                    if isComplete || error != nil {
                        // Let queued responses go out before closing.
                        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
                    } else {
                        self.receive(on: connection, buffered: buffer)
                    }
                    return
                case .invalid:
                    self.respond(on: connection, status: "400 Bad Request", close: true)
                    return
                case .tooLarge:
                    self.respond(on: connection, status: "413 Payload Too Large", close: true)
                    return
                case .request(let request):
                    let status: String
                    if request.method != "POST" { status = "405 Method Not Allowed" }
                    else if request.isCompressed { status = "415 Unsupported Media Type" }
                    else {
                        self.ingest(request.body)
                        status = "200 OK"
                    }
                    self.respond(on: connection, status: status, close: request.closesConnection)
                    if request.closesConnection { return }
                }
            }
        }
    }

    private func respond(on connection: NWConnection, status: String, close: Bool) {
        let body = status.hasPrefix("200") ? "{}" : ""
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
            + (close ? "Connection: close\r\n" : "Connection: keep-alive\r\n") + "\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    private func ingest(_ body: Data) {
        let now = Date()
        let events = ClaudeTelemetryParser.events(from: body, now: now)
        lock.lock()
        receivedBatches += 1
        for event in events {
            if event.at > (lastSeen[event.sessionID] ?? .distantPast) { lastSeen[event.sessionID] = event.at }
            if event.tokens > 0 || event.weightedTokens > 0 {
                deltas.append(ActivityTokenDelta(sessionID: event.sessionID, at: event.at, tokens: event.tokens,
                    weightedTokens: event.weightedTokens))
            }
        }
        prune(at: now)
        let callback = events.isEmpty ? nil : onEvent
        lock.unlock()
        callback?()
    }
}
