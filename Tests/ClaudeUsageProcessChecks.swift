import Foundation
import Darwin

// This target links the production probe with a test-only executable resolver.
// Its child process is this synthetic fixture, never the installed Claude CLI.
enum ClaudeAuthProbe {
    static func executable() -> String? {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }
}

@main
struct ClaudeUsageProcessChecks {
    private static let modeKey = "TOKEN_MONITOR_TEST_USAGE_PROCESS_MODE"

    static func main() throws {
        if CommandLine.arguments.contains("--safe-mode") {
            try runFixture()
            return
        }
        setbuf(stdout, nil)
        let originalMode = ProcessInfo.processInfo.environment[modeKey]
        defer {
            if let originalMode { setenv(modeKey, originalMode, 1) }
            else { unsetenv(modeKey) }
        }
        for mode in ["evidence-first", "delayed-200", "partial-200", "stdout-closes-first", "no-newline-200",
                     "snapshot-first", "snapshot-delayed", "evidence-on-eof"] {
            setenv(modeKey, mode, 1)
            let started = Date()
            let state = try ClaudeUsageProbe.read(timeout: 4)
            precondition(state.windows.first?.usedPercent == 36, "Confirmed numeric quota survives independent pipe delivery: \(mode)")
            let age = started.timeIntervalSince(state.updatedAt ?? .distantPast)
            if mode.hasPrefix("snapshot") {
                precondition(age > 9 && age < 15, "A snapshot answer keeps its server confirmation time: \(mode), \(age)")
            } else {
                precondition(abs(age) < 4, "A live answer is stamped when it was read: \(mode), \(age)")
            }
        }
        expect("delayed-429", error: .rateLimited)
        expect("no-confirmation", error: .unconfirmed)
        expect("fieldless-body", error: .unconfirmed)
        expect("invalid-payload", error: .invalidResponse)
        expect("missing-payload", error: .unavailable)
        let start = ProcessInfo.processInfo.systemUptime
        expect("pending-without-evidence", error: .unconfirmed, timeout: 0.35)
        precondition(ProcessInfo.processInfo.systemUptime - start < 1.5, "No confirmation may extend the original deadline")
        expect("snapshot-stale", error: .unconfirmed)
        expect("inband-refusal", error: .serviceRejected)
        expect("forbidden-remembered", error: .serviceRejected)
        expect("signed-out", error: .signedOut)
        expect("network-timeout", error: .endpointUnavailable)
        expect("silent-server-error", error: .endpointUnavailable)
        expect("forbidden-plain", error: .serviceRejected)
        expect("no-subscription", error: .noSubscriptionLimits)
        let hangStart = ProcessInfo.processInfo.systemUptime
        expect("pending-hangs", error: .unconfirmed, timeout: 20)
        precondition(ProcessInfo.processInfo.systemUptime - hangStart < ClaudeUsageProbe.evidenceGrace + 2,
            "A payload without evidence must not hold the CLI for the whole query timeout")
        print("PASS 23 offline Claude usage process checks: independent pipes, delayed/partial confirmation, snapshot answers, endpoint refusals and failures, sign-in state, 429, EOF, invalid data and bounded waits")
    }

    private static func expect(_ mode: String, error expected: ClaudeUsageError, timeout: TimeInterval = 2) {
        setenv(modeKey, mode, 1)
        do {
            _ = try ClaudeUsageProbe.read(timeout: timeout)
            preconditionFailure("Unconfirmed/unusable fixture must never become a fresh reading: \(mode)")
        } catch let actual as ClaudeUsageError {
            precondition(String(describing: actual) == String(describing: expected), "Expected \(expected), got \(actual) for \(mode)")
        } catch {
            preconditionFailure("Unexpected fixture error: \(error)")
        }
    }

    private static func runFixture() throws {
        let mode = ProcessInfo.processInfo.environment[modeKey] ?? ""
        func emit(_ handle: FileHandle, _ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }
        func response(_ id: String, _ payload: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: ["type": "control_response",
                "response": ["request_id": id, "subtype": "success", "response": payload]])
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
        let success = "[DEBUG] fetchUtilization: 200 after 1 attempt(s)"
        let valid: [String: Any] = ["rate_limits_available": true,
            "rate_limits": ["five_hour": ["utilization": 36, "resets_at": "2030-01-01T00:00:00Z"]]]
        while let line = readLine() {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = request["request_id"] as? String else { continue }
            if id == "tm_init" {
                try response(id, [:])
                continue
            }
            guard id == "tm_usage" else { continue }
            let usageRequest = request["request"] as? [String: Any]
            precondition(usageRequest?["skip_behaviors"] as? Bool == true, "A quota query must skip the local transcript scan")
            switch mode {
            case "evidence-first":
                try emit(.standardError, success + "\n")
                try response(id, valid)
            case "delayed-200":
                try response(id, valid)
                usleep(80_000)
                try emit(.standardError, success + "\n")
            case "partial-200":
                try emit(.standardError, "[DEBUG] fetchUtilization: 200 after ")
                try response(id, valid)
                usleep(80_000)
                try emit(.standardError, "1 attempt(s)\n")
            case "stdout-closes-first":
                try response(id, valid)
                try FileHandle.standardOutput.close()
                usleep(80_000)
                try emit(.standardError, success + "\n")
            case "no-newline-200":
                try response(id, valid)
                usleep(80_000)
                try emit(.standardError, success)
            case "delayed-429":
                try response(id, valid)
                usleep(80_000)
                try emit(.standardError, "[DEBUG] fetchUtilization: 429 after 1 attempt(s)\n")
            case "no-confirmation":
                try response(id, valid)
            case "fieldless-body":
                try response(id, valid)
                usleep(80_000)
                try emit(.standardError, success + "\nfetchUtilization: fieldless or non-object body\n")
            case "invalid-payload":
                try emit(.standardError, success + "\n")
                try response(id, ["rate_limits_available": true, "rate_limits": ["five_hour": ["utilization": 101]]])
            case "missing-payload":
                try emit(.standardError, success + "\n")
            case "pending-without-evidence":
                try response(id, valid)
                usleep(3_000_000)
            case "snapshot-first":
                try emit(.standardError, "2026-10-14T13:01:54.077Z [DEBUG] Usage read answered from a snapshot 12s old; endpoint not asked\n")
                try response(id, valid)
            case "snapshot-delayed":
                try response(id, valid)
                usleep(80_000)
                try emit(.standardError, "[DEBUG] Usage read answered from a snapshot 12s old; endpoint not asked\n")
            case "snapshot-stale":
                try emit(.standardError, "[DEBUG] Usage read answered from a snapshot 901s old; endpoint not asked\n")
                try response(id, valid)
            case "evidence-on-eof":
                // The probe closes stdin once it has the payload; diagnostics
                // flushed during the CLI's shutdown must still be accepted.
                try response(id, valid)
                while readLine() != nil {}
                try emit(.standardError, success + "\n")
            case "pending-hangs":
                try response(id, valid)
                usleep(9_000_000)
            case "inband-refusal":
                // HTTP 200 with an error envelope: the CLI falls back to cached numbers.
                try emit(.standardError, success + "\n")
                try emit(.standardError, "[ERROR] Usage fetch returned a fieldless or non-object body (in-band error)\n")
                try response(id, valid)
            case "forbidden-remembered":
                try emit(.standardError, "[DEBUG] fetchUtilization: 403 remembered for this bearer; not asking again for 300s\n")
                try emit(.standardError, "[ERROR] Failed to load usage data: Request failed with status code 403\n")
                try response(id, valid)
            case "signed-out":
                try emit(.standardError, "[ERROR] Failed to load usage data: Auth error: no-auth\n")
                try response(id, valid)
            case "network-timeout":
                // No HTTP answer: the CLI answers from its cache instead.
                try emit(.standardError, "[DEBUG] fetchUtilization: GET /api/oauth/usage (attempt 1)\n")
                try emit(.standardError, "[ERROR] Failed to load usage data: timeout of 5000ms exceeded\n")
                try response(id, valid)
            case "silent-server-error":
                // A 5xx answer is not logged; only the request line shows.
                try emit(.standardError, "[DEBUG] fetchUtilization: GET /api/oauth/usage (attempt 1)\n")
                try response(id, valid)
            case "forbidden-plain":
                try emit(.standardError, "[ERROR] Failed to load usage data: Request failed with status code 403\n")
                try response(id, valid)
            case "no-subscription":
                // API key or inference-only login: the CLI does not ask the endpoint.
                try response(id, ["rate_limits_available": false, "rate_limits": NSNull()])
            default:
                preconditionFailure("Unknown synthetic mode")
            }
            return
        }
    }
}
