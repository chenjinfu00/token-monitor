import Foundation
import Darwin

enum ClaudeAuthProbe {
    static func executable() -> String? {
        let paths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", NSHomeDirectory() + "/.local/bin/claude"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // Read only the login flag; never retain or display account identifiers.
    static func isLoggedIn() -> Bool? {
        guard let path = executable() else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["auth", "status"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer {
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        var data = Data()
        let deadline = Date().addingTimeInterval(10)
        let fd = output.fileHandleForReading.fileDescriptor
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 250) <= 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            if data.count > 65_536 { return nil }
        }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return result["loggedIn"] as? Bool
    }
}
