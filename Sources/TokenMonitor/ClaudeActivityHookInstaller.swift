import Foundation

// Explicit opt-in only. No initializer, probe or application startup invokes this.
// Ownership is the saved exact command, never a flag substring or hook event name.
enum ClaudeActivityHookInstaller {
    private struct InstallState: Codable {
        var schemaVersion = 1
        var commands: [String]
        let backup: String
    }
    private enum Failure: Error { case invalidSettings, invalidState, unavailableApp }
    private static let maximumSettingsBytes = 4 * 1024 * 1024
    private static let eventNames = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Stop", "StopFailure", "SessionEnd", "Notification", "SubagentStart", "SubagentStop"]

    static func installIfNeeded(bundleURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        do {
            guard bundleURL.pathExtension == "app" else { throw Failure.unavailableApp }
            let executable = Bundle(url: bundleURL)?.executableURL
                ?? bundleURL.appendingPathComponent("Contents/MacOS/TokenMonitor")
            guard ClaudeActivityFiles.regularFile(executable) != nil,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.unavailableApp }
            let command = quote(executable.path) + " --claude-activity-hook >/dev/null 2>&1 || true"
            let directory = homeDirectory.appendingPathComponent(".claude/token-monitor", isDirectory: true)
            try ClaudeActivityFiles.withLock(directory: directory, name: "activity-install") {
                let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
                let stateURL = directory.appendingPathComponent("activity-hooks-install.json")
                let (raw, original) = try settings(settingsURL)
                var state = try loadState(stateURL)
                var document = original
                var hooks = try removeOwned(from: original["hooks"], commands: Set(state?.commands ?? []))
                for event in eventNames {
                    var groups = hooks[event] as? [[String: Any]] ?? []
                    var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 2]]]
                    if event == "Notification" { group["matcher"] = "permission_prompt|idle_prompt" }
                    groups.append(group); hooks[event] = groups
                }
                document["hooks"] = hooks
                if let state, state.commands == [command], NSDictionary(dictionary: document).isEqual(to: original) { return }
                if state == nil {
                    let backup = "activity-settings.backup-" + UUID().uuidString + ".json"
                    try ClaudeActivityFiles.atomicWrite(raw, to: directory.appendingPathComponent(backup))
                    state = InstallState(commands: [], backup: backup)
                }
                // Save proof of ownership before changing settings, so interrupted
                // app-path updates remain recoverable by the next explicit request.
                state!.commands = Array(Set(state!.commands + [command])).sorted()
                try ClaudeActivityFiles.atomicWrite(try JSONEncoder().encode(state!), to: stateURL)
                try ClaudeActivityFiles.atomicWrite(try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), to: settingsURL)
                state!.commands = [command]
                try ClaudeActivityFiles.atomicWrite(try JSONEncoder().encode(state!), to: stateURL)
            }
            return nil
        } catch { return message(error) }
    }

    static func uninstall(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let directory = homeDirectory.appendingPathComponent(".claude/token-monitor", isDirectory: true)
        let stateURL = directory.appendingPathComponent("activity-hooks-install.json")
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        do {
            try ClaudeActivityFiles.withLock(directory: directory, name: "activity-install") {
                guard var state = try loadState(stateURL), !state.commands.isEmpty else { return }
                let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")
                let (_, original) = try settings(settingsURL)
                var document = original
                let hooks = try removeOwned(from: original["hooks"], commands: Set(state.commands))
                // Keep all subsequent user changes, including replacement commands.
                if original["hooks"] != nil { document["hooks"] = hooks }
                if !NSDictionary(dictionary: document).isEqual(to: original) {
                    try ClaudeActivityFiles.atomicWrite(try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), to: settingsURL)
                }
                state.commands = []
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
              let document = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw Failure.invalidSettings }
        return (raw, document)
    }
    private static func loadState(_ url: URL) throws -> InstallState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let info = ClaudeActivityFiles.regularFile(url), info.st_size <= 128 * 1024,
              let raw = ClaudeActivityFiles.boundedRead(url, maximumBytes: 128 * 1024),
              let state = try? JSONDecoder().decode(InstallState.self, from: raw), state.schemaVersion == 1,
              state.commands.count <= 8, state.commands.allSatisfy({ $0.utf8.count <= 16 * 1024 }),
              state.backup.hasPrefix("activity-settings.backup-"), state.backup.hasSuffix(".json"),
              URL(fileURLWithPath: state.backup).lastPathComponent == state.backup else { throw Failure.invalidState }
        return state
    }
    private static func removeOwned(from value: Any?, commands: Set<String>) throws -> [String: Any] {
        guard let value else { return [:] }
        guard var events = value as? [String: Any] else { throw Failure.invalidSettings }
        for (event, value) in events {
            guard let groups = value as? [[String: Any]] else { throw Failure.invalidSettings }
            var kept: [[String: Any]] = []
            for var group in groups {
                guard let entries = group["hooks"] as? [[String: Any]] else { throw Failure.invalidSettings }
                let remaining = entries.filter { entry in
                    !(entry["type"] as? String == "command" && (entry["command"] as? String).map(commands.contains) == true)
                }
                if remaining.count == entries.count { kept.append(group) }
                else if !remaining.isEmpty { group["hooks"] = remaining; kept.append(group) }
            }
            events[event] = kept
        }
        return events
    }
    private static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func message(_ error: Error) -> String {
        switch error {
        case Failure.invalidSettings: return "Claude 设置格式无效，未修改配置。"
        case Failure.invalidState: return "活动采集安装记录无效，未修改 Claude 配置。"
        case Failure.unavailableApp: return "请从完整的 Token Monitor 应用安装活动采集。"
        default: return "无法保存活动采集配置，请检查本地文件权限。"
        }
    }
}
