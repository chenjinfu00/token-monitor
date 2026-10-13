import Foundation
import Darwin

// Link the real probes with only a synthetic Claude executable resolver.
// Every child is this fixture; these checks never touch accounts or networks.
enum ClaudeAuthProbe {
    static func executable() -> String? { fixtureExecutable }
}

private var fixtureExecutable: String {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
}

@main
struct ProbePipeSafetyChecks {
    private static let modeKey = "TOKEN_MONITOR_TEST_PIPE_MODE"
    private static let modes = ["exit-immediately", "close-before-initialize", "close-after-initialize"]

    static func main() throws {
        // A shell/runner may have inherited SIG_IGN. Restore the real default
        // in each isolated worker so an unprotected pipe write kills that
        // worker, and the outer test process can report it safely.
        signal(SIGPIPE, SIG_DFL)
        if CommandLine.arguments.contains("--safe-mode") || CommandLine.arguments.contains("app-server") {
            try runFixture()
            return
        }
        if let worker = CommandLine.arguments.firstIndex(of: "--pipe-worker") {
            let provider = CommandLine.arguments[worker + 1]
            let mode = CommandLine.arguments[worker + 2]
            setenv("TOKEN_MONITOR_CODEX", fixtureExecutable, 1)
            for _ in 0..<4 {
                setenv(modeKey, mode, 1)
                expectUnavailable(provider)
                // The same calling process must be able to query again after
                // a failed child, rather than retaining broken state.
                setenv(modeKey, "normal", 1)
                try expectSuccess(provider)
            }
            print("0")
            return
        }
        for provider in ["codex", "claude"] {
            for mode in modes { try runIsolated(provider, mode: mode) }
        }
        print("PASS 48 offline pipe safety checks: early exit, stdin closure, handshake write failure, default SIGPIPE, and subsequent query recovery")
    }

    private static func runIsolated(_ provider: String, mode: String) throws {
        let worker = Process(), output = Pipe()
        worker.executableURL = URL(fileURLWithPath: fixtureExecutable)
        worker.arguments = ["--pipe-worker", provider, mode]
        worker.standardInput = FileHandle.nullDevice
        worker.standardOutput = output
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        defer { try? output.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while worker.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if worker.isRunning {
            kill(worker.processIdentifier, SIGKILL)
            worker.waitUntilExit()
            preconditionFailure("Synthetic probe worker exceeded its deadline")
        }
        worker.waitUntilExit()
        precondition(worker.terminationReason == .exit && worker.terminationStatus == 0,
            "Probe must survive a closed child pipe: \(provider), \(mode), termination \(worker.terminationStatus)")
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        precondition(String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "0")
    }

    private static func expectUnavailable(_ provider: String) {
        do {
            if provider == "codex" { _ = try CodexProbe.read(timeout: 1) }
            else { _ = try ClaudeUsageProbe.read(timeout: 1) }
            preconditionFailure("Closed fixture must not produce a successful quota reading")
        } catch let error as ProbeError {
            precondition(provider == "codex" && String(describing: error) == "serviceUnavailable")
        } catch let error as ClaudeUsageError {
            precondition(provider == "claude" && String(describing: error) == "unavailable")
        } catch {
            preconditionFailure("Pipe failures must map to the provider's unavailable error")
        }
    }

    private static func expectSuccess(_ provider: String) throws {
        if provider == "codex" {
            let result = try CodexProbe.read(timeout: 1)
            precondition(result["fixture"] as? Int == 36)
        } else {
            let result = try ClaudeUsageProbe.read(timeout: 1)
            precondition(result.windows.first?.usedPercent == 36)
        }
    }

    private static func emit(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func initializeResponse(_ codex: Bool) throws {
        if codex { try emit(["id": 0, "result": [:] as [String: Any]]) }
        else {
            try emit(["type": "control_response", "response": ["request_id": "tm_init",
                "subtype": "success", "response": [:] as [String: Any]]])
        }
    }

    private static func runFixture() throws {
        let mode = ProcessInfo.processInfo.environment[modeKey] ?? ""
        let codex = CommandLine.arguments.contains("app-server")
        if mode == "exit-immediately" { Darwin._exit(7) }
        if mode == "close-before-initialize" {
            // Initial send can race child startup; the subsequent handshake
            // write is guaranteed to see this closed pipe.
            Darwin.close(STDIN_FILENO)
            try initializeResponse(codex)
            usleep(100_000)
            return
        }
        guard let first = readLine(),
              (try JSONSerialization.jsonObject(with: Data(first.utf8))) is [String: Any] else { return }
        if mode == "close-after-initialize" {
            Darwin.close(STDIN_FILENO)
            try initializeResponse(codex)
            usleep(100_000)
            return
        }
        precondition(mode == "normal")
        try initializeResponse(codex)
        while let line = readLine() {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if codex {
                guard request["id"] as? Int == 1 else { continue }
                try emit(["id": 1, "result": ["fixture": 36]])
            } else {
                guard request["request_id"] as? String == "tm_usage" else { continue }
                try FileHandle.standardError.write(contentsOf: Data("fetchUtilization: 200 after 1 attempt(s)\n".utf8))
                try emit(["type": "control_response", "response": ["request_id": "tm_usage", "subtype": "success",
                    "response": ["rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": 36,
                        "resets_at": "2030-01-01T00:00:00Z"]]]]])
            }
            return
        }
    }
}
