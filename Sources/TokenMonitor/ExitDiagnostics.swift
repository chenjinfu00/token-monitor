import AppKit
import Foundation
import Darwin

// Private local breadcrumbs that explain a later disappearance: which quit path
// ran, a termination signal, or an abrupt end (forced kill, crash, power loss)
// detected at the next launch. Only times, process ID, version and the reason
// are stored; never account, quota or conversation data.
@MainActor
enum ExitDiagnostics {
    private static let maximumEntries = 100
    private static var heartbeat: Timer?
    private static var signalSources: [DispatchSourceSignal] = []
    private static var quitReason: String?
    private static var finished = false
    private static var launchedAt = Date()

    private static var stateURL: URL { MonitorStore.dataDirectory.appendingPathComponent("session-state.json") }
    private static var logURL: URL { MonitorStore.dataDirectory.appendingPathComponent("exit-log.jsonl") }
    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static func begin() {
        try? FileManager.default.createDirectory(at: MonitorStore.dataDirectory,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let previous = readObject(stateURL), previous["state"] as? String == "running" {
            // The previous instance never reached a normal termination path.
            append(["event": "abnormal-end", "pid": previous["pid"] ?? NSNull(),
                    "version": previous["version"] ?? NSNull(),
                    "launchedAt": previous["launchedAt"] ?? NSNull(),
                    "lastSeenAt": previous["heartbeatAt"] ?? NSNull(),
                    "detectedAt": Date().timeIntervalSince1970])
        }
        launchedAt = Date()
        writeState("running")
        let timer = Timer(timeInterval: 120, repeats: true) { _ in
            Task { @MainActor in ExitDiagnostics.heartbeatTick() }
        }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        for number in [SIGTERM, SIGHUP] {
            // A handler stops the default action from ending the process before
            // AppKit's normal termination records why; children reset it on exec.
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                Task { @MainActor in
                    ExitDiagnostics.recordQuit(reason: "signal-\(number)")
                    NSApplication.shared.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    static func recordQuit(reason: String) {
        if quitReason == nil { quitReason = reason }
    }

    static func finish() {
        guard !finished else { return }
        finished = true
        heartbeat?.invalidate()
        heartbeat = nil
        append(["event": "quit", "reason": quitReason ?? "system", "version": version,
                "launchedAt": launchedAt.timeIntervalSince1970, "at": Date().timeIntervalSince1970])
        writeState("exited")
    }

    static func report() -> String {
        var lines: [String] = []
        if let state = readObject(stateURL) {
            let status = state["state"] as? String == "running" ? "运行中，或上次没有正常退出" : "已正常退出"
            lines.append("最近一次：\(status) · 版本 \(text(state["version"])) · 启动 \(moment(state["launchedAt"])) · 最后记录 \(moment(state["heartbeatAt"]))")
        }
        let entries = readLog()
        if entries.isEmpty { lines.append("尚无退出记录。") }
        for entry in entries.suffix(20) {
            if entry["event"] as? String == "abnormal-end" {
                lines.append("\(moment(entry["lastSeenAt"])) 之后：异常结束，没有经过正常退出流程（可能被系统或其他程序强制结束、崩溃或断电）· 版本 \(text(entry["version"]))")
            } else {
                lines.append("\(moment(entry["at"]))：退出 · \(describe(entry["reason"] as? String)) · 版本 \(text(entry["version"]))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func heartbeatTick() {
        if !finished { writeState("running") }
    }

    private static func describe(_ reason: String?) -> String {
        switch reason ?? "system" {
        case "menu": return "菜单栏“退出 Token Monitor”"
        case "window-button": return "小窗左上角退出按钮（旧版本）"
        case "signal-15": return "收到 SIGTERM（被其他程序或系统要求结束）"
        case "signal-1": return "收到 SIGHUP（例如从终端启动后关闭了终端）"
        case "system": return "系统或其他应用请求退出（如注销、关机或更新）"
        case let other: return other
        }
    }

    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return "未知"
    }

    private static func moment(_ value: Any?) -> String {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds.isFinite, seconds > 0 else { return "未知时间" }
        return Date(timeIntervalSince1970: seconds).formatted(date: .numeric, time: .standard)
    }

    private static func writeState(_ state: String) {
        write(["schemaVersion": 1, "state": state, "pid": Int(getpid()), "version": version,
               "launchedAt": launchedAt.timeIntervalSince1970, "heartbeatAt": Date().timeIntervalSince1970],
              to: stateURL)
    }

    private static func write(_ object: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func append(_ entry: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(entry),
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        let lines = (readLogLines() + [line]).suffix(maximumEntries)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: logURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    private static func readLogLines() -> [String] {
        guard let data = try? Data(contentsOf: logURL), data.count <= 262_144 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func readLog() -> [[String: Any]] {
        readLogLines().compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), data.count <= 65_536 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
