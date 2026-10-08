import Foundation
import Darwin

@main
struct SingleInstanceChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--try-lock" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            guard let lock = try SingleInstanceLock.acquire(directory: directory) else { exit(3) }
            withExtendedLifetime(lock) { exit(0) }
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--hold-lock" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            guard let lock = try SingleInstanceLock.acquire(directory: directory) else { exit(3) }
            withExtendedLifetime(lock) {
                FileHandle.standardOutput.write(Data("ready\n".utf8))
                while true { Darwin.sleep(1) }
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("token-monitor-lock-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        func child(_ mode: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [mode, directory.path]
            process.standardError = FileHandle.nullDevice
            return process
        }
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }

        var first = try SingleInstanceLock.acquire(directory: directory)
        require(first != nil, "First instance must acquire the lock")
        let duplicate = child("--try-lock")
        try duplicate.run()
        duplicate.waitUntilExit()
        require(duplicate.terminationStatus == 3, "A second process must not acquire the lock")
        first = nil
        let successor = child("--try-lock")
        try successor.run()
        successor.waitUntilExit()
        require(successor.terminationStatus == 0, "The lock must be available after normal exit")

        let holder = child("--hold-lock")
        let readiness = Pipe()
        holder.standardOutput = readiness
        try holder.run()
        defer {
            if holder.isRunning { holder.terminate(); holder.waitUntilExit() }
        }
        let ready = readiness.fileHandleForReading.availableData
        require(String(decoding: ready, as: UTF8.self).hasPrefix("ready"), "The child must own the lock before checking")
        require(try SingleInstanceLock.acquire(directory: directory) == nil, "A held lock must block another instance")
        holder.terminate()
        holder.waitUntilExit()
        let recovered = try SingleInstanceLock.acquire(directory: directory)
        require(recovered != nil, "A terminated process must not leave a stale lock")
        withExtendedLifetime(recovered) { print("Single-instance process exclusion and exit recovery checks passed") }
    }
}
