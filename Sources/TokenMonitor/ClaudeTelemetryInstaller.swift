import Foundation

// Explicit opt-in only, like the activity hooks. It adds Claude Code's documented
// OpenTelemetry settings to the "env" of ~/.claude/settings.json, pointing only at
// Token Monitor's loopback receiver. Ownership is the exact key/value pairs saved
// here: a key the user already configured differently is never changed, and
// uninstalling removes only values that still match what was installed.
enum ClaudeTelemetryInstaller {
    private struct InstallState: Codable {
        var schemaVersion = 1
        var env: [String: String]
        let backup: String
    }
    private enum Failure: Error { case invalidSettings, invalidState, conflict(String) }
    private static let maximumSettingsBytes = 4 * 1024 * 1024

    static func environment(port: UInt16 = ClaudeTelemetryReceiver.configuredPort) -> [String: String] {
        ["CLAUDE_CODE_ENABLE_TELEMETRY": "1",
         "OTEL_LOGS_EXPORTER": "otlp",
         "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
         "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": ClaudeTelemetryReceiver.logsEndpoint(port: port),
         "OTEL_EXPORTER_OTLP_LOGS_COMPRESSION": "none",
         "OTEL_LOGS_EXPORT_INTERVAL": "1000"]
    }

    static func install(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                        port: UInt16 = ClaudeTelemetryReceiver.configuredPort) -> String? {
        let directory = homeDirectory.appendingPathComponent(".claude/token-monitor", isDirectory: true)
        do {
            try ClaudeActivityFiles.withLock(directory: directory, name: "telemetry-install") {
                let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
                let stateURL = directory.appendingPathComponent("telemetry-install.json")
                let (raw, original) = try settings(settingsURL)
                var state = try loadState(stateURL)
                if let existing = original["env"], !(existing is [String: Any]) { throw Failure.invalidSettings }
                var environment = original["env"] as? [String: Any] ?? [:]
                var owned = state?.env ?? [:]
                for (key, value) in Self.environment(port: port).sorted(by: { $0.key < $1.key }) {
                    let existing = environment[key]
                    let current = existing as? String
                    if existing == nil {
                        environment[key] = value
                        owned[key] = value
                    } else if let current, current == owned[key] {
                        // An earlier Token Monitor value, for example another port.
                        environment[key] = value
                        owned[key] = value
                    } else if current != value {
                        throw Failure.conflict(key)
                    }
                }
                var document = original
                document["env"] = environment
                let unchanged = NSDictionary(dictionary: document).isEqual(to: original)
                if unchanged, let state, state.env == owned { return }
                // Back up the settings as they are before Token Monitor owns any key,
                // including after an earlier uninstall left only the install record.
                if state == nil || state?.env.isEmpty == true {
                    let backup = "telemetry-settings.backup-" + UUID().uuidString + ".json"
                    try ClaudeActivityFiles.atomicWrite(raw, to: directory.appendingPathComponent(backup))
                    state = InstallState(env: [:], backup: backup)
                }
                // Record ownership before changing settings, so an interrupted
                // write remains removable by the next explicit request.
                state!.env = owned
                try ClaudeActivityFiles.atomicWrite(try JSONEncoder().encode(state!), to: stateURL)
                if !unchanged {
                    try ClaudeActivityFiles.atomicWrite(try JSONSerialization.data(withJSONObject: document,
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: settingsURL)
                }
            }
            return nil
        } catch { return message(error) }
    }

    static func uninstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let directory = homeDirectory.appendingPathComponent(".claude/token-monitor", isDirectory: true)
        let stateURL = directory.appendingPathComponent("telemetry-install.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        do {
            try ClaudeActivityFiles.withLock(directory: directory, name: "telemetry-install") {
                guard var state = try loadState(stateURL), !state.env.isEmpty else { return }
                let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
                let (_, original) = try settings(settingsURL)
                var document = original
                if var environment = original["env"] as? [String: Any] {
                    // Keep every value the user changed after installation.
                    for (key, value) in state.env where environment[key] as? String == value {
                        environment.removeValue(forKey: key)
                    }
                    if environment.isEmpty { document.removeValue(forKey: "env") }
                    else { document["env"] = environment }
                }
                if !NSDictionary(dictionary: document).isEqual(to: original) {
                    try ClaudeActivityFiles.atomicWrite(try JSONSerialization.data(withJSONObject: document,
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), to: settingsURL)
                }
                state.env = [:]
                try ClaudeActivityFiles.atomicWrite(try JSONEncoder().encode(state), to: stateURL)
            }
            return nil
        } catch { return message(error) }
    }

    private static func settings(_ url: URL) throws -> (Data, [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Data("{}".utf8), [:]) }
        guard let info = ClaudeActivityFiles.regularFile(url), info.st_size >= 0,
              info.st_size <= maximumSettingsBytes else { throw Failure.invalidSettings }
        guard let raw = ClaudeActivityFiles.boundedRead(url, maximumBytes: maximumSettingsBytes),
              let document = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            throw Failure.invalidSettings
        }
        return (raw, document)
    }

    private static func loadState(_ url: URL) throws -> InstallState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let info = ClaudeActivityFiles.regularFile(url), info.st_size <= 64 * 1024,
              let raw = ClaudeActivityFiles.boundedRead(url, maximumBytes: 64 * 1024),
              let state = try? JSONDecoder().decode(InstallState.self, from: raw), state.schemaVersion == 1,
              state.env.count <= 16,
              state.env.allSatisfy({ $0.key.utf8.count <= 128 && $0.value.utf8.count <= 1024 }),
              state.backup.hasPrefix("telemetry-settings.backup-"), state.backup.hasSuffix(".json"),
              URL(fileURLWithPath: state.backup).lastPathComponent == state.backup else { throw Failure.invalidState }
        return state
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case Failure.invalidSettings: return "Claude 设置格式无效，未修改配置。"
        case Failure.invalidState: return "遥测安装记录无效，未修改 Claude 配置。"
        case Failure.conflict(let key):
            return "Claude 设置的 env 里已有 \(key)，取值与 Token Monitor 需要的不同，未修改配置。若你在用自己的 OpenTelemetry 采集器，请保留原设置。"
        default: return "无法保存遥测配置，请检查本地文件权限。"
        }
    }
}
