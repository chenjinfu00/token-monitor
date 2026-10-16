import Foundation

// All fixtures are synthetic. These checks never launch the CLI or query an account.
enum ClaudeUsageChecks {
    static let checkCount = 15
    private static let now = Date(timeIntervalSince1970: 1_791_460_800)
    private static let reset = "2026-10-08T12:34:56.123456Z"

    static func run() {
        teamLegacyWindowKeepsServerDeadline()
        zeroIsKnownAndMissingIsUnknown()
        invalidPercentagesAreRejected()
        newSessionFallsBackFromNullLegacy()
        newWeeklyAllFallsBackFromNullLegacy()
        scopedWeeklyDoesNotBecomeOverallWeekly()
        legacyAndNewWindowsAreNotDuplicated()
        absentOrUnavailableQuotasAreRejected()
        missingDeadlineIsNeverConstructed()
        evidenceRequiresSuccessfulHTTPUsageRequest()
        failedOrFieldlessResponseInvalidatesSuccess()
        rateLimitInvalidatesSuccess()
        snapshotAnswerIsRecentConfirmation()
        refusedEndpointIsNotStaleSuccess()
        failuresWithoutAnHTTPAnswerAreExplained()
    }

    private static func parse(_ limits: [String: Any]) -> ProviderState {
        do {
            return try ClaudeUsageParser.parse([
                "rate_limits_available": true, "rate_limits": limits
            ], at: now)
        } catch {
            preconditionFailure("Valid synthetic Claude usage fixture was rejected: \(error)")
        }
    }

    private static func rejects(_ result: [String: Any]) {
        do {
            _ = try ClaudeUsageParser.parse(result, at: now)
            preconditionFailure("Unavailable synthetic Claude quota must not produce a reading")
        } catch is ClaudeUsageError {
            // A provider error is the expected unavailable result.
        } catch {
            preconditionFailure("Unexpected parser error type: \(error)")
        }
    }

    private static func teamLegacyWindowKeepsServerDeadline() {
        let result: [String: Any] = [
            "subscription_type": "team",
            "rate_limits_available": true,
            "rate_limits": ["five_hour": ["utilization": 100, "resets_at": reset]]
        ]
        let state = try! ClaudeUsageParser.parse(result, at: now)
        XCTAssertEqual(state.windows.count, 1)
        XCTAssertEqual(state.windows[0].id, "five_hour")
        XCTAssertEqual(state.windows[0].usedPercent, 100)
        XCTAssertEqual(state.windows[0].remainingPercent, 0)
        XCTAssertEqual(state.windows[0].durationSeconds, 18_000)
        XCTAssertEqual(state.updatedAt, now)
        let actual = state.windows[0].resetsAt!.timeIntervalSince1970
        // Independently calculated UTC timestamp; do not compare the parser to itself.
        precondition(abs(actual - 1_791_462_896.123456) < 0.000001,
            "The server's microsecond ISO deadline must be retained, received \(actual)")
    }

    private static func zeroIsKnownAndMissingIsUnknown() {
        let state = parse([
            "five_hour": NSNull(),
            "seven_day": ["utilization": 0, "resets_at": reset],
            "seven_day_opus": ["resets_at": reset],
            "seven_day_sonnet": ["utilization": NSNull()]
        ])
        XCTAssertEqual(state.windows.map(\.id), ["seven_day"])
        XCTAssertEqual(state.windows[0].usedPercent, 0)
        XCTAssertEqual(state.windows[0].remainingPercent, 100)
    }

    private static func invalidPercentagesAreRejected() {
        let invalid: [Any] = [true, false, -0.01, 100.01, Double.infinity,
            -Double.infinity, Double.nan, "0", NSNull()]
        for value in invalid {
            rejects(["rate_limits_available": true,
                "rate_limits": ["five_hour": ["utilization": value]]])
            rejects(["rate_limits_available": true,
                "rate_limits": ["limits": [["kind": "session", "group": "session", "percent": value]]]])
        }
    }

    private static func newSessionFallsBackFromNullLegacy() {
        let state = parse([
            "five_hour": NSNull(),
            "limits": [
                ["kind": "weekly_scoped", "group": "session", "percent": 99],
                ["kind": "session", "group": "session", "percent": 25.5, "resets_at": reset]
            ]
        ])
        XCTAssertEqual(state.windows.map(\.id), ["five_hour"])
        XCTAssertEqual(state.windows[0].remainingPercent, 74.5)
        XCTAssertEqual(state.windows[0].durationSeconds, 18_000)
        XCTAssertNotNil(state.windows[0].resetsAt)
    }

    private static func newWeeklyAllFallsBackFromNullLegacy() {
        let state = parse([
            "seven_day": NSNull(),
            "limits": [
                ["kind": "session", "group": "session", "percent": 10],
                ["kind": "weekly_all", "percent": 62.5, "resets_at": reset]
            ]
        ])
        XCTAssertEqual(state.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(state.windows[1].remainingPercent, 37.5)
        XCTAssertEqual(state.windows[1].durationSeconds, 604_800)
    }

    private static func scopedWeeklyDoesNotBecomeOverallWeekly() {
        rejects(["rate_limits_available": true, "rate_limits": ["limits": [
            ["kind": "weekly_scoped", "group": "sonnet", "percent": 80, "resets_at": reset]
        ]]])
        let state = parse([
            "seven_day_sonnet": ["utilization": 35],
            "limits": [
                ["kind": "session", "group": "session", "percent": 20],
                ["kind": "weekly_scoped", "group": "opus", "percent": 80]
            ]
        ])
        XCTAssertEqual(state.windows.map(\.id), ["five_hour", "seven_day_sonnet"])
        XCTAssertFalse(state.windows.contains { $0.id == "seven_day" })
    }

    private static func legacyAndNewWindowsAreNotDuplicated() {
        let state = parse([
            "five_hour": ["utilization": 40, "resets_at": reset],
            "seven_day": ["utilization": 50],
            "limits": [
                ["kind": "session", "group": "session", "percent": 60],
                ["kind": "weekly_all", "percent": 70]
            ]
        ])
        XCTAssertEqual(state.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(state.windows.map(\.usedPercent), [40, 50])
    }

    private static func absentOrUnavailableQuotasAreRejected() {
        let validLimits = ["five_hour": ["utilization": 25]]
        for result: [String: Any] in [
            [:],
            ["rate_limits_available": false, "rate_limits": validLimits],
            ["rate_limits": validLimits],
            ["rate_limits_available": true, "rate_limits": NSNull()],
            ["rate_limits_available": true, "rate_limits": [:]],
            ["rate_limits_available": true, "rate_limits": ["five_hour": NSNull()]],
            ["rate_limits_available": true, "rate_limits": ["five_hour": ["resets_at": reset]]]
        ] {
            rejects(result)
        }
    }

    private static func missingDeadlineIsNeverConstructed() {
        for invalidDeadline: Any in [NSNull(), "not-a-date", 1_791_462_896] {
            let state = parse(["five_hour": ["utilization": 30, "resets_at": invalidDeadline]])
            XCTAssertEqual(state.windows[0].remainingPercent, 70)
            XCTAssertNil(state.windows[0].resetsAt)
            XCTAssertNil(state.windows[0].timeRemainingPercent(at: now))
            XCTAssertEqual(state.windows[0].countdown(at: now), "重置时间未知")
        }
        XCTAssertNil(parse(["five_hour": ["utilization": 30]]).windows[0].resetsAt)
    }

    private static func evidenceRequiresSuccessfulHTTPUsageRequest() {
        var evidence = ClaudeUsageEvidence()
        // Parsing a successful control payload is not HTTP freshness evidence.
        _ = parse(["five_hour": ["utilization": 40]])
        XCTAssertFalse(evidence.confirmedFresh)
        for line in ["", "get_usage: success", "fetchUtilization: 201 after 1 attempt(s)",
            "fetchUtilization: 403 after 1 attempt(s)"] {
            evidence.observe(line)
            XCTAssertFalse(evidence.confirmedFresh)
        }
        evidence.observe("[DEBUG] fetchUtilization: 200 after 1 attempt(s)")
        XCTAssertTrue(evidence.confirmedFresh)
        XCTAssertFalse(evidence.rateLimited)
    }

    private static func failedOrFieldlessResponseInvalidatesSuccess() {
        let success = "fetchUtilization: 200 after 1 attempt(s)"
        for failure in ["fetchUtilization: fieldless or non-object body",
            "Failed to load usage data"] {
            for lines in [[success, failure], [failure, success]] {
                var evidence = ClaudeUsageEvidence()
                for line in lines { evidence.observe(line) }
                XCTAssertFalse(evidence.confirmedFresh)
                XCTAssertFalse(evidence.rateLimited)
            }
        }
    }

    private static func snapshotAnswerIsRecentConfirmation() {
        let snapshot = "2026-10-14T13:01:54.077Z [DEBUG] Usage read answered from a snapshot 41s old; endpoint not asked"
        var evidence = ClaudeUsageEvidence()
        evidence.observe(snapshot)
        XCTAssertTrue(evidence.confirmedFresh)
        XCTAssertEqual(evidence.confirmationAge, 41)
        var stale = ClaudeUsageEvidence()
        stale.observe("[DEBUG] Usage read answered from a snapshot 901s old; endpoint not asked")
        XCTAssertFalse(stale.confirmedFresh)
        var live = ClaudeUsageEvidence()
        live.observe("[DEBUG] fetchUtilization: 200 after 2 attempt(s) (401\u{2192}refresh\u{2192}retry succeeded)")
        XCTAssertTrue(live.confirmedFresh)
        XCTAssertEqual(live.confirmationAge, 0)
        for failure in ["fetchUtilization: 429 remembered for this bearer; not asking again for 300s",
            "Failed to load usage data: Request failed with status code 429"] {
            var limited = ClaudeUsageEvidence()
            limited.observe(snapshot)
            limited.observe(failure)
            XCTAssertTrue(limited.rateLimited)
            XCTAssertFalse(limited.confirmedFresh)
        }
        var fieldless = ClaudeUsageEvidence()
        fieldless.observe(snapshot)
        fieldless.observe("Usage fetch returned a fieldless or non-object body (in-band error)")
        XCTAssertFalse(fieldless.confirmedFresh)
    }

    private static func refusedEndpointIsNotStaleSuccess() {
        let success = "[DEBUG] fetchUtilization: 200 after 1 attempt(s)"
        for refusal in ["[ERROR] Usage fetch returned a fieldless or non-object body (in-band error)",
            "[DEBUG] fetchUtilization: 403 remembered for this bearer; not asking again for 300s"] {
            for lines in [[success, refusal], [refusal, success]] {
                var evidence = ClaudeUsageEvidence()
                for line in lines { evidence.observe(line) }
                XCTAssertTrue(evidence.serviceRejected)
                XCTAssertFalse(evidence.confirmedFresh)
                XCTAssertFalse(evidence.rateLimited)
            }
        }
        var signedOut = ClaudeUsageEvidence()
        signedOut.observe("[ERROR] Failed to load usage data: Auth error: no-auth")
        XCTAssertFalse(signedOut.confirmedFresh)
        XCTAssertFalse(signedOut.serviceRejected)
        XCTAssertEqual(String(describing: signedOut.unconfirmedError), "signedOut")
        var quiet = ClaudeUsageEvidence()
        quiet.observe("[DEBUG] MDM settings load completed in 0ms")
        XCTAssertEqual(String(describing: quiet.unconfirmedError), "unconfirmed")
    }

    // Claude Code 2.1.299 logs "Failed to load usage data" only for failures without
    // an HTTP answer, or for 401/403/429; other server errors leave just the request line.
    private static func failuresWithoutAnHTTPAnswerAreExplained() {
        let request = "2026-10-14T18:12:17.001Z [DEBUG] fetchUtilization: GET /api/oauth/usage (attempt 1)"
        for failure in ["[ERROR] Failed to load usage data: timeout of 5000ms exceeded",
            "[ERROR] Failed to load usage data: getaddrinfo ENOTFOUND api.anthropic.com"] {
            var evidence = ClaudeUsageEvidence()
            evidence.observe(request)
            evidence.observe(failure)
            XCTAssertFalse(evidence.confirmedFresh)
            XCTAssertFalse(evidence.rateLimited)
            XCTAssertFalse(evidence.serviceRejected)
            XCTAssertEqual(String(describing: evidence.unconfirmedError), "endpointUnavailable")
        }
        var silent = ClaudeUsageEvidence()
        silent.observe(request)
        // Until the CLI has exited, a missing success line may still arrive.
        XCTAssertEqual(String(describing: silent.unconfirmedError), "unconfirmed")
        silent.finish()
        XCTAssertEqual(String(describing: silent.unconfirmedError), "endpointUnavailable")
        var succeeded = ClaudeUsageEvidence()
        succeeded.observe(request)
        succeeded.observe("[DEBUG] fetchUtilization: 200 after 1 attempt(s)")
        succeeded.finish()
        XCTAssertTrue(succeeded.confirmedFresh)
        for refusal in ["[ERROR] Failed to load usage data: Request failed with status code 403",
            "[DEBUG] fetchUtilization: /api/oauth/usage replayed \u{2014} the endpoint answered 403 12s ago; not asked again for 288s"] {
            var evidence = ClaudeUsageEvidence()
            evidence.observe(refusal)
            XCTAssertTrue(evidence.serviceRejected)
            XCTAssertFalse(evidence.rateLimited)
        }
        var replayedLimit = ClaudeUsageEvidence()
        replayedLimit.observe("[ERROR] Failed to load usage data: the endpoint answered 429 3s ago; not asked again for 297s")
        XCTAssertTrue(replayedLimit.rateLimited)
        var expired = ClaudeUsageEvidence()
        expired.observe("[ERROR] Failed to load usage data: Request failed with status code 401")
        XCTAssertEqual(String(describing: expired.unconfirmedError), "signedOut")
    }

    private static func rateLimitInvalidatesSuccess() {
        let success = "fetchUtilization: 200 after 1 attempt(s)"
        for failure in ["fetchUtilization: 429 after 1 attempt(s)",
            "Failed to load usage data: HTTP 429"] {
            for lines in [[success, failure], [failure, success]] {
                var evidence = ClaudeUsageEvidence()
                for line in lines { evidence.observe(line) }
                XCTAssertTrue(evidence.rateLimited)
                XCTAssertFalse(evidence.confirmedFresh)
            }
        }
    }
}
