import Foundation
import Darwin

enum ProbeError: Error {
    case executableMissing, timedOut, serviceUnavailable, invalidResponse
    var message: String {
        switch self {
        case .executableMissing: return "未找到 Codex · 请先安装并登录"
        case .timedOut: return "同步超时 · 将自动重试"
        case .serviceUnavailable: return "暂时无法读取额度 · 请检查网络与 Codex 登录"
        case .invalidResponse: return "当前 Codex 未返回可用额度"
        }
    }
}

enum CodexProbe {
    static func executable() -> String? {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["TOKEN_MONITOR_CODEX"] { paths.append(override) }
        paths += [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex"
        ]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Only handshake and read account limits. Never create a conversation or model request.
    static func read(timeout: TimeInterval = 20) throws -> [String: Any] {
        guard let path = executable() else { throw ProbeError.executableMissing }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ProbeError.serviceUnavailable }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let stop = Date().addingTimeInterval(1)
                while process.isRunning && Date() < stop { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? output.fileHandleForReading.close()
        }

        func send(_ request: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 0, "method": "initialize", "params": [
            "clientInfo": ["name": "token_monitor", "title": "Token Monitor",
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.3"]
        ]])
        let deadline = Date().addingTimeInterval(timeout)
        let fd = output.fileHandleForReading.fileDescriptor
        var buffer = Data(), initialized = false
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; throw ProbeError.serviceUnavailable }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { throw ProbeError.serviceUnavailable }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 4_194_304 else { throw ProbeError.invalidResponse }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let item = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let id = item["id"] as? Int else { continue }
                if item["error"] != nil { throw ProbeError.serviceUnavailable }
                if id == 0 && !initialized {
                    initialized = true
                    try send(["method": "initialized", "params": [:] as [String: Any]])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1, let result = item["result"] as? [String: Any] {
                    return result
                }
            }
        }
        throw ProbeError.timedOut
    }
}
