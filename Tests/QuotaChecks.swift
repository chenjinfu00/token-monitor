import Foundation

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { precondition(actual == expected, "Expected \(expected), received \(actual)") }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertFalse(_ value: Bool) { precondition(!value) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }

final class QuotaParserTests {
    func testCodexMultipleBucketsReplaceLegacyView() {
        let windows = QuotaParser.codex([
            "rateLimits": ["primary": ["usedPercent": 90]],
            "rateLimitsByLimitId": [
                "codex": ["primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_900_000_000],
                          "secondary": ["usedPercent": 40, "windowDurationMins": 10080]],
                "reviews": ["limitName": "Code review", "primary": ["usedPercent": 10, "windowDurationMins": 1440]]
            ]
        ])
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first?.name, "5小时额度")
        XCTAssertEqual(windows.first?.remainingPercent, 75)
        XCTAssertEqual(windows[1].name, "每周额度")
        XCTAssertTrue(windows[2].name.contains("Code review"))
        XCTAssertEqual(windows[0].durationSeconds, 18000)
    }

    func testNullOrMissingPercentIsUnknown() {
        let windows = QuotaParser.codex(["rateLimits": ["primary": ["usedPercent": NSNull(), "resetsAt": 1_900_000_000], "secondary": NSNull()]])
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows.first?.remainingPercent)
        XCTAssertEqual(QuotaParser.codex([:]).count, 0)
        XCTAssertNil(QuotaParser.number(true))
        XCTAssertNil(QuotaParser.number(Double.infinity))
    }

    func testClaudeMissingWindowsAreNotFabricated() {
        let state = QuotaParser.claude(["capturedAt": 1_900_000_000, "rateLimits": ["seven_day": ["used_percentage": 23.5, "resets_at": 1_900_001_000]]])
        XCTAssertEqual(state.windows.map(\.id), ["seven_day"])
        XCTAssertEqual(state.windows.first?.remainingPercent, 76.5)
        XCTAssertNotNil(state.updatedAt)
        XCTAssertEqual(state.windows.first?.durationSeconds, 604800)
        XCTAssertTrue(QuotaParser.claude(["capturedAt": 1_900_000_000]).windows.isEmpty)
    }

    func testExpiredSnapshotDoesNotClaimResetHappened() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let window = QuotaWindow(id: "x", name: "quota", usedPercent: 95, resetsAt: now.addingTimeInterval(-1))
        XCTAssertTrue(window.isExpired(at: now))
        XCTAssertEqual(window.countdown(at: now), "窗口已结束 · 等待更新")
        XCTAssertEqual(window.remainingPercent, 5)
    }

    func testCountdownAndPercentageBounds() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let window = QuotaWindow(id: "x", name: "quota", usedPercent: 120, resetsAt: now.addingTimeInterval(3660))
        XCTAssertEqual(window.remainingPercent, 0)
        XCTAssertEqual(window.countdown(at: now), "1小时 1分钟后重置")
        let unknown = QuotaWindow(id: "y", name: "quota", usedPercent: nil, resetsAt: nil)
        XCTAssertNil(unknown.remainingPercent)
        XCTAssertFalse(unknown.isExpired(at: now))
        XCTAssertEqual(unknown.countdown(at: now), "重置时间未知")
    }

    func testRemainingBarsAndPaceDirection() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let fast = QuotaWindow(id: "x", name: "quota", usedPercent: 60, resetsAt: now.addingTimeInterval(750), durationSeconds: 1000)
        XCTAssertEqual(fast.timeRemainingPercent(at: now), 75)
        XCTAssertEqual(fast.paceDifference(at: now), -35)
        XCTAssertTrue(fast.paceText(at: now).contains("使用偏快"))
        let slow = QuotaWindow(id: "x", name: "quota", usedPercent: 20, resetsAt: now.addingTimeInterval(500), durationSeconds: 1000)
        XCTAssertEqual(slow.timeRemainingPercent(at: now), 50)
        XCTAssertEqual(slow.paceDifference(at: now), 30)
        XCTAssertTrue(slow.paceText(at: now).contains("余量充足"))
        let steady = QuotaWindow(id: "x", name: "quota", usedPercent: 50, resetsAt: now.addingTimeInterval(500), durationSeconds: 1000)
        XCTAssertEqual(steady.paceText(at: now), "接近均匀节奏")
    }

    func testTimeUnknownAndExpiredAreNotFabricated() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let unknown = QuotaWindow(id: "x", name: "quota", usedPercent: 50, resetsAt: now.addingTimeInterval(500))
        XCTAssertNil(unknown.timeRemainingPercent(at: now))
        XCTAssertNil(unknown.paceDifference(at: now))
        let expired = QuotaWindow(id: "x", name: "quota", usedPercent: 50, resetsAt: now, durationSeconds: 1000)
        XCTAssertNil(expired.timeRemainingPercent(at: now))
        XCTAssertNil(expired.paceDifference(at: now))
        let future = QuotaWindow(id: "x", name: "quota", usedPercent: 50, resetsAt: now.addingTimeInterval(2000), durationSeconds: 1000)
        XCTAssertNil(future.timeRemainingPercent(at: now))
    }

    func testQuotaColorsCompareRemainingQuotaWithRemainingTime() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        func level(remaining: Double, time: Double = 50) -> QuotaPace {
            QuotaWindow(id: "x", name: "quota", usedPercent: 100 - remaining,
                resetsAt: now.addingTimeInterval(time * 10), durationSeconds: 1000).paceLevel(at: now)
        }
        XCTAssertEqual(level(remaining: 80), .ahead)
        XCTAssertEqual(level(remaining: 55.01), .ahead)
        XCTAssertEqual(level(remaining: 55), .balanced)
        XCTAssertEqual(level(remaining: 50), .balanced)
        XCTAssertEqual(level(remaining: 35.01), .balanced)
        XCTAssertEqual(level(remaining: 35), .behind)
        XCTAssertEqual(level(remaining: 0, time: 80), .behind)
        let expired = QuotaWindow(id: "x", name: "quota", usedPercent: 0, resetsAt: now, durationSeconds: 1000)
        XCTAssertEqual(expired.paceLevel(at: now), .unknown)
        let missing = QuotaWindow(id: "x", name: "quota", usedPercent: nil, resetsAt: now.addingTimeInterval(500), durationSeconds: 1000)
        XCTAssertEqual(missing.paceLevel(at: now), .unknown)
        let noDuration = QuotaWindow(id: "x", name: "quota", usedPercent: 0, resetsAt: now.addingTimeInterval(500))
        XCTAssertEqual(noDuration.paceLevel(at: now), .unknown)
        let invalid = QuotaWindow(id: "x", name: "quota", usedPercent: .nan, resetsAt: now.addingTimeInterval(500), durationSeconds: 1000)
        XCTAssertNil(invalid.remainingPercent)
        XCTAssertEqual(invalid.paceLevel(at: now), .unknown)
    }

    func testExactResetDatesUseAmsterdamAndDaylightSaving() {
        let summer = ResetNewsParser.date("2026-10-08T13:10:00Z")!
        let winter = ResetNewsParser.date("2026-11-08T13:10:00Z")!
        XCTAssertEqual(WidgetDateFormatter.shortReset(summer), "10/08 15:10")
        XCTAssertEqual(WidgetDateFormatter.reset(summer), "10/08 15:10")
        XCTAssertEqual(WidgetDateFormatter.resetDay(summer), "10/08")
        XCTAssertEqual(WidgetDateFormatter.resetTime(summer), "15:10")
        XCTAssertEqual(WidgetDateFormatter.shortReset(winter), "11/08 14:10")
        XCTAssertEqual(WidgetDateFormatter.reset(winter), "11/08 14:10")
    }

    func testCollapsedSummaryKeepsQuotaAndResetFromSameOverallWindow() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let session = QuotaWindow(id: "codex.primary", name: "5小时额度", usedPercent: 10,
            resetsAt: now.addingTimeInterval(4.3 * 3600), durationSeconds: 18000)
        let weekly = QuotaWindow(id: "codex.secondary", name: "每周额度", usedPercent: 70,
            resetsAt: now.addingTimeInterval(120 * 3600), durationSeconds: 604800)
        let review = QuotaWindow(id: "reviews.primary", name: "Code review", usedPercent: 100,
            resetsAt: now.addingTimeInterval(3600), durationSeconds: 86400)
        let summary = EdgeQuotaSummary(provider: ProviderState(name: "Codex", windows: [session, review, weekly]), at: now)
        XCTAssertEqual(summary.window?.id, weekly.id)
        XCTAssertEqual(summary.percentText, "30%")
        XCTAssertEqual(summary.hoursText, "120.0h")
        XCTAssertEqual(summary.pace, .behind)
        let sonnet = QuotaWindow(id: "seven_day_sonnet", name: "Sonnet", usedPercent: 100,
            resetsAt: now.addingTimeInterval(7200), durationSeconds: 604800)
        let claudeSession = QuotaWindow(id: "five_hour", name: "5小时额度", usedPercent: 10,
            resetsAt: now.addingTimeInterval(4.26 * 3600), durationSeconds: 18000)
        let claude = EdgeQuotaSummary(provider: ProviderState(name: "Claude · 实时", windows: [sonnet, claudeSession]), at: now)
        XCTAssertEqual(claude.window?.id, claudeSession.id)
        XCTAssertEqual(claude.hoursText, "4.3h")
        XCTAssertNil(claude.daysText)
        XCTAssertEqual(claude.hourComponentText, "4.3h")
        XCTAssertEqual(claude.percentText, "90%")
    }

    func testCollapsedSummaryMissingExpiredAndNearResetAreTruthful() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let empty = EdgeQuotaSummary(provider: ProviderState(name: "Claude"), at: now)
        XCTAssertNil(empty.window)
        XCTAssertEqual(empty.hoursText, "—")
        XCTAssertEqual(empty.percentText, "—")
        let past = QuotaWindow(id: "five_hour", name: "5小时额度", usedPercent: 100,
            resetsAt: now, durationSeconds: 18000)
        let expired = EdgeQuotaSummary(provider: ProviderState(name: "Claude", windows: [past]), at: now)
        XCTAssertEqual(expired.percentText, "—")
        XCTAssertEqual(expired.hoursText, "—")
        XCTAssertNil(expired.daysText)
        XCTAssertEqual(expired.hourComponentText, "—")
        XCTAssertEqual(expired.pace, .unknown)
        let near = QuotaWindow(id: "five_hour", name: "5小时额度", usedPercent: 100,
            resetsAt: now.addingTimeInterval(30), durationSeconds: 18000)
        let current = EdgeQuotaSummary(provider: ProviderState(name: "Claude", windows: [near, past]), at: now)
        XCTAssertEqual(current.percentText, "0%")
        XCTAssertEqual(current.hoursText, "0.1h")
        XCTAssertNil(current.daysText)
        XCTAssertEqual(current.hourComponentText, "0.1h")
        let noReset = QuotaWindow(id: "five_hour", name: "5小时额度", usedPercent: 23, resetsAt: nil)
        let partial = EdgeQuotaSummary(provider: ProviderState(name: "Claude", windows: [noReset]), at: now)
        XCTAssertEqual(partial.percentText, "77%")
        XCTAssertEqual(partial.hoursText, "—")
        XCTAssertEqual(partial.pace, .unknown)
    }

    func testVerticalSummarySplitsDaysAndRemainingHours() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        func summary(hours: Double) -> EdgeQuotaSummary {
            EdgeQuotaSummary(provider: ProviderState(name: "Codex", windows: [
                QuotaWindow(id: "codex.secondary", name: "每周额度", usedPercent: 59,
                    resetsAt: now.addingTimeInterval(hours * 3600), durationSeconds: 604800)
            ]), at: now)
        }
        let weekly = summary(hours: 136.75)
        XCTAssertEqual(weekly.daysText, "5d")
        XCTAssertEqual(weekly.hourComponentText, "17h")
        XCTAssertEqual(weekly.percentText, "41%")
        let wholeDays = summary(hours: 120)
        XCTAssertEqual(wholeDays.daysText, "5d")
        XCTAssertEqual(wholeDays.hourComponentText, "0.0h")
        let nearDay = summary(hours: 23.98)
        XCTAssertNil(nearDay.daysText)
        XCTAssertEqual(nearDay.hourComponentText, "24h")
        XCTAssertEqual(summary(hours: 9.94).hourComponentText, "9.9h")
        XCTAssertEqual(summary(hours: 10).hourComponentText, "10.0h")
        XCTAssertEqual(summary(hours: 10.01).hourComponentText, "10h")
        XCTAssertEqual(summary(hours: 10.6).hourComponentText, "11h")
        let roundedDay = summary(hours: 143.7)
        XCTAssertEqual(roundedDay.daysText, "6d")
        XCTAssertEqual(roundedDay.hourComponentText, "0h")
    }

    func testObservedEarlyRecoveryAnchorsUnchangedDeadline() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let deadline = now.addingTimeInterval(4000)
        var tracker = QuotaCycleTracker()
        let previous = QuotaWindow(id: "x", name: "quota", usedPercent: 80, resetsAt: deadline, durationSeconds: 4000)
        XCTAssertFalse(tracker.update([previous], at: now).recovered)
        let reset = QuotaWindow(id: "x", name: "quota", usedPercent: 0, resetsAt: deadline, durationSeconds: 4000)
        let restored = tracker.update([reset], at: now.addingTimeInterval(1000))
        XCTAssertTrue(restored.recovered)
        XCTAssertEqual(restored.windows.first?.timeRemainingPercent(at: now.addingTimeInterval(1000)), 100)
        let usedAgain = QuotaWindow(id: "x", name: "quota", usedPercent: 30, resetsAt: deadline, durationSeconds: 4000)
        let later = tracker.update([usedAgain], at: now.addingTimeInterval(2500))
        XCTAssertFalse(later.recovered)
        XCTAssertEqual(later.windows.first?.timeRemainingPercent(at: now.addingTimeInterval(2500)), 50)
        let nextCycle = QuotaWindow(id: "x", name: "quota", usedPercent: 0, resetsAt: now.addingTimeInterval(8000), durationSeconds: 4000)
        let next = tracker.update([nextCycle], at: now.addingTimeInterval(4100))
        XCTAssertFalse(next.recovered)
        XCTAssertNil(next.windows.first?.cycleStartedAt)
    }

    func testAvailableResetCountUnknownAndZeroAreDistinct() {
        XCTAssertNil(QuotaParser.codexSnapshot([:]).resetCreditCount)
        XCTAssertEqual(QuotaParser.codexSnapshot(["rateLimitResetCredits": ["availableCount": 0]]).resetCreditCount, 0)
        XCTAssertEqual(QuotaParser.codexSnapshot(["rateLimitResetCredits": ["availableCount": 2]]).resetCreditCount, 2)
        XCTAssertNil(QuotaParser.codexSnapshot(["rateLimitResetCredits": ["availableCount": true]]).resetCreditCount)
        XCTAssertNil(QuotaParser.codexSnapshot(["rateLimitResetCredits": ["availableCount": 0.5]]).resetCreditCount)
    }

    func testSmallUsageCorrectionDoesNotRestartTimeBar() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let deadline = now.addingTimeInterval(3000)
        var tracker = QuotaCycleTracker()
        let old = QuotaWindow(id: "x", name: "quota", usedPercent: 0.9, resetsAt: deadline, durationSeconds: 4000)
        _ = tracker.update([old], at: now)
        let corrected = QuotaWindow(id: "x", name: "quota", usedPercent: 0, resetsAt: deadline, durationSeconds: 4000)
        let result = tracker.update([corrected], at: now.addingTimeInterval(1000))
        XCTAssertFalse(result.recovered)
        XCTAssertNil(result.windows.first?.cycleStartedAt)
        XCTAssertEqual(result.windows.first?.timeRemainingPercent(at: now.addingTimeInterval(1000)), 50)
    }

    private let publicNow = ResetNewsParser.date("2026-10-08T10:00:00Z")!

    private func publicSource(id: String = "1234567890") -> [String: Any] {
        ["type": "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/" + id]
    }

    private func resetRecord(kind: String = "regular", at timestamp: String = "2026-10-08T08:00:00Z") -> [String: Any] {
        ["id": "1234567890", "reset_type": kind, "announced_at": timestamp,
         "text": "A synthetic reset announcement.", "source": publicSource()]
    }

    private func scheduledRecord() -> [String: Any] {
        ["id": "1234567891", "status": "scheduled", "reset_type": "regular",
         "announced_at": "2026-10-08T09:00:00Z", "scheduled_for": "2026-10-08T11:00:00Z",
         "text": "A synthetic scheduled reset.", "source": publicSource(id: "1234567891")]
    }

    private func watchRecord() -> [String: Any] {
        ["level": "strong", "reset_chance_percent": 37, "forecast_window": "next few hours",
         "observed_at": "2026-10-08T09:00:00Z", "expires_at": "2026-10-08T11:00:00Z",
         "text": "A synthetic watch, not a scheduled reset.", "source": publicSource()]
    }

    private func publicData(latest: Any = NSNull(), scheduled: Any = NSNull(), watch: Any = NSNull()) -> [String: Any] {
        ["latest_reset": latest, "scheduled_reset": scheduled, "active_watch": watch,
         "stats": ["total": 59, "last_reset_at": NSNull(), "days_since_last": NSNull(), "avg_interval_days": 6.7]]
    }

    private func publicEnvelope(_ data: [String: Any], generatedAt: String = "2026-10-08T09:59:00Z") -> [String: Any] {
        ["meta": ["api_version": "v1", "generated_at": generatedAt], "data": data]
    }

    private func expectInvalidPublicEnvelope(_ document: [String: Any]) {
        do {
            _ = try ResetNewsParser.parse(status: document, at: publicNow)
            preconditionFailure("Invalid public API envelope must not become reset news")
        } catch ResetNewsError.unavailable {
            // Schema or timestamp validation must fail closed.
        } catch {
            preconditionFailure("Unexpected public API error: \(error)")
        }
    }

    func testPublicEnvelopeUsesGeneratedTimestampAndNewDomain() throws {
        let state = try ResetNewsParser.parse(status: publicEnvelope(publicData()), at: publicNow)
        XCTAssertEqual(state.updatedAt, publicNow.addingTimeInterval(-60))
        XCTAssertEqual(state.sourceURL?.host, "codex-resets.com")
        XCTAssertNil(state.reference)
        let boundary = try ResetNewsParser.parse(status: publicEnvelope(publicData(), generatedAt: "2026-10-08T10:05:00Z"), at: publicNow)
        XCTAssertEqual(boundary.updatedAt, publicNow.addingTimeInterval(300))
    }

    func testPublicMalformedOrUnsupportedEnvelopeFailsClosed() {
        let valid = publicEnvelope(publicData())
        for invalid: [String: Any] in [[:], ["meta": NSNull(), "data": publicData()],
            ["meta": ["api_version": "v2", "generated_at": "2026-10-08T09:59:00Z"], "data": publicData()],
            ["meta": ["api_version": 1, "generated_at": "2026-10-08T09:59:00Z"], "data": publicData()],
            publicEnvelope(publicData(), generatedAt: "invalid"),
            publicEnvelope(publicData(), generatedAt: "2026-10-08T10:05:01Z")] {
            expectInvalidPublicEnvelope(invalid)
        }
        for key in ["latest_reset", "scheduled_reset", "active_watch", "stats"] {
            var data = publicData()
            data[key] = "not-an-object"
            expectInvalidPublicEnvelope(publicEnvelope(data))
        }
        var nullData = valid
        nullData["data"] = NSNull()
        expectInvalidPublicEnvelope(nullData)
    }

    func testBankedGrantIsManualAndNotGlobalReset() throws {
        let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(latest: resetRecord(kind: "banked"))), at: publicNow)
        XCTAssertTrue(state.headline?.contains("备用重置额度发放") ?? false)
        XCTAssertTrue(state.detail?.contains("需要手动使用") ?? false)
        XCTAssertFalse(state.headline?.contains("全局重置") ?? true)
        XCTAssertNil(state.reference)
        XCTAssertFalse(state.canShowReference(at: publicNow))
    }

    func testRegularAndObservedHeadlinesMatchSourceEvidence() throws {
        let announced = try ResetNewsParser.parse(status: publicEnvelope(publicData(latest: resetRecord())), at: publicNow)
        XCTAssertTrue(announced.headline?.contains("网站记录全局重置") ?? false)
        var observed = resetRecord()
        observed["id"] = "observed-synthetic-reset"
        observed["source"] = ["type": "observed"]
        let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(latest: observed)), at: publicNow)
        XCTAssertTrue(state.headline?.contains("网站观察到全局重置") ?? false)
        XCTAssertNil(state.reference)
        var future = resetRecord()
        future["announced_at"] = "2026-10-08T10:01:00Z"
        let ignored = try ResetNewsParser.parse(status: publicEnvelope(publicData(latest: future)), at: publicNow)
        XCTAssertFalse(ignored.headline?.contains("网站记录全局重置") ?? false)
    }

    func testActiveWatchProbabilityIsEstimateAndNotDeadline() throws {
        let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(watch: watchRecord())), at: publicNow)
        XCTAssertTrue(state.detail?.contains("网站估计概率：37%") ?? false)
        XCTAssertNil(state.reference)
        XCTAssertFalse(state.canShowReference(at: publicNow))
        XCTAssertFalse(state.detail?.contains("24小时 37%") ?? false)
        let data = publicData(watch: watchRecord())
        XCTAssertNil(ResetNewsParser.prediction(data, at: publicNow))
    }

    func testExpiredFutureInvalidWatchesNeverPublishProbability() throws {
        for invalid: Any in [true, -1, 101, 37.5, Double.infinity, Double.nan, "37", NSNull()] {
            var watch = watchRecord()
            watch["reset_chance_percent"] = invalid
            let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(watch: watch)), at: publicNow)
            XCTAssertFalse(state.detail?.contains("网站估计概率：") ?? false)
        }
        for (key, value): (String, Any) in [
            ("expires_at", "2026-10-08T10:00:00Z"),
            ("observed_at", "2026-10-08T10:00:01Z"),
            ("source", ["type": "x_post", "author": "unknown", "url": "https://x.com/unknown/status/1234567890"])
        ] {
            var watch = watchRecord()
            watch[key] = value
            let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(watch: watch)), at: publicNow)
            XCTAssertFalse(state.detail?.contains("网站估计概率：") ?? false)
            XCTAssertNil(state.reference)
        }
        for probability in [0, 100] {
            var watch = watchRecord()
            watch["reset_chance_percent"] = probability
            let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(watch: watch)), at: publicNow)
            XCTAssertTrue(state.detail?.contains("网站估计概率：\(probability)%") ?? false)
        }
    }

    func testExplicitScheduledReferenceKeepsExactTargetAndRemainingScale() throws {
        let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(scheduled: scheduledRecord())), at: publicNow)
        let reference = state.reference!
        XCTAssertEqual(reference.startAt, publicNow.addingTimeInterval(-3600))
        XCTAssertEqual(reference.referenceAt, publicNow.addingTimeInterval(3600))
        XCTAssertEqual(reference.windowStartAt, reference.referenceAt)
        XCTAssertEqual(reference.windowEndAt, reference.referenceAt)
        XCTAssertEqual(reference.targetKind.rawValue, "deadline")
        XCTAssertEqual(reference.remainingPercent(at: reference.startAt), 100)
        XCTAssertEqual(reference.remainingPercent(at: publicNow), 50)
        XCTAssertEqual(reference.remainingPercent(at: reference.referenceAt), 0)
        XCTAssertTrue(state.canShowReference(at: publicNow))
        XCTAssertFalse(state.canShowReference(at: reference.referenceAt))
        XCTAssertTrue(reference.description(at: publicNow).contains("账户恢复待确认"))
    }

    func testScheduledReferenceRequiresExplicitFutureRegularAnnouncement() {
        let valid = scheduledRecord()
        for (key, value): (String, Any) in [
            ("status", "observed"), ("reset_type", "banked"), ("id", ""),
            ("announced_at", "2026-10-08T10:01:00Z"), ("announced_at", "invalid"),
            ("scheduled_for", NSNull()), ("scheduled_for", "2026-10-08T10:00:00Z"),
            ("scheduled_for", "2026-10-08T08:00:00Z"), ("scheduled_for", "2027-10-09T09:00:00Z")
        ] {
            var record = valid
            record[key] = value
            XCTAssertNil(ResetNewsParser.prediction(publicData(scheduled: record), at: publicNow))
        }
        var missing = valid
        missing.removeValue(forKey: "scheduled_for")
        XCTAssertNil(ResetNewsParser.prediction(publicData(scheduled: missing), at: publicNow))
        var noPositiveSpan = valid
        noPositiveSpan["announced_at"] = "2026-10-08T11:00:00Z"
        XCTAssertNil(ResetNewsParser.prediction(publicData(scheduled: noPositiveSpan), at: publicNow.addingTimeInterval(3600)))
    }

    func testScheduledReferenceRejectsUntrustedOrObservedSource() {
        for source: [String: Any] in [
            ["type": "observed"],
            ["type": "x_post", "author": "unknown", "url": "https://x.com/unknown/status/1234567891"],
            ["type": "x_post", "author": "thsottiaux", "url": "http://x.com/thsottiaux/status/1234567891"],
            ["type": "x_post", "author": "thsottiaux", "url": "https://example.com/thsottiaux/status/1234567891"],
            ["type": "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux"],
            ["type": "x_post", "author": "thsottiaux"]
        ] {
            var record = scheduledRecord()
            record["source"] = source
            XCTAssertNil(ResetNewsParser.prediction(publicData(scheduled: record), at: publicNow))
        }
    }

    func testLaterRegularResetCancelsPredictionButBankedGrantDoesNot() throws {
        let scheduled = scheduledRecord()
        let regular = resetRecord(at: "2026-10-08T09:30:00Z")
        XCTAssertNil(ResetNewsParser.prediction(publicData(latest: regular, scheduled: scheduled), at: publicNow))
        let banked = resetRecord(kind: "banked", at: "2026-10-08T09:30:00Z")
        let state = try ResetNewsParser.parse(status: publicEnvelope(publicData(latest: banked, scheduled: scheduled)), at: publicNow)
        XCTAssertNotNil(state.reference)
        XCTAssertTrue(state.canShowReference(at: publicNow))
        let earlier = resetRecord(at: "2026-10-08T08:30:00Z")
        XCTAssertNotNil(ResetNewsParser.prediction(publicData(latest: earlier, scheduled: scheduled), at: publicNow))
    }

    func testSourceFreshnessAndErrorsHidePredictionWithoutInventingLegacyTarget() throws {
        var data = publicData(watch: watchRecord())
        data["forecast"] = ["last_reset_at": "2026-10-07T03:35:09Z", "probabilities": ["rounded_24h": 99],
            "official_signal": ["signal_type": "dated_commitment", "window": ["target_at": "2026-10-08T11:00:00Z"]]]
        data["time_window"] = ["start_hour": 1, "end_hour": 4]
        XCTAssertNil(ResetNewsParser.prediction(data, at: publicNow))
        let document = publicEnvelope(publicData(scheduled: scheduledRecord()))
        var state = try ResetNewsParser.parse(status: document, at: publicNow, expiresAt: publicNow.addingTimeInterval(120))
        XCTAssertTrue(state.canShowReference(at: publicNow))
        XCTAssertNotNil(state.freshnessWarning(at: publicNow.addingTimeInterval(120)))
        XCTAssertFalse(state.canShowReference(at: publicNow.addingTimeInterval(120)))
        state.message = "公共重置信息暂不可用"
        XCTAssertFalse(state.canShowReference(at: publicNow))
        let stale = try ResetNewsParser.parse(status: document, at: publicNow, sourceIsStale: true)
        XCTAssertNotNil(stale.freshnessWarning(at: publicNow))
        XCTAssertFalse(stale.canShowReference(at: publicNow))
        let expired = try ResetNewsParser.parse(status: document, at: publicNow, expiresAt: publicNow)
        XCTAssertFalse(expired.canShowReference(at: publicNow))
    }

    func testRetryAfterHonoursBothSecondsAndHTTPDate() {
        XCTAssertEqual(ResetNewsService.retryDelay("600", at: publicNow), 600)
        XCTAssertEqual(ResetNewsService.retryDelay("Thu, 08 Oct 2026 10:30:00 GMT", at: publicNow), 1800)
        XCTAssertEqual(ResetNewsService.retryDelay("invalid", at: publicNow), 300)
    }

    func testPublicCacheLifetimeUsesClientMaxAgeAndSubtractsAge() {
        XCTAssertEqual(ResetNewsService.cacheLifetime("public, max-age=14400, s-maxage=60", age: "35"), 14365)
        XCTAssertEqual(ResetNewsService.cacheLifetime("s-maxage=3600", age: "5"), 55)
        XCTAssertEqual(ResetNewsService.cacheLifetime(nil, age: nil), 60)
        XCTAssertEqual(ResetNewsService.cacheLifetime("MAX-AGE=\"90\", s-maxage=10", age: "10"), 80)
        XCTAssertEqual(ResetNewsService.cacheLifetime("max-age=45", age: "100"), 0)
        XCTAssertEqual(ResetNewsService.cacheLifetime("no-cache, max-age=14400", age: "35"), 0)
        XCTAssertEqual(ResetNewsService.cacheLifetime("max-age=14400, no-store", age: nil), 0)
        XCTAssertEqual(ResetNewsService.cacheLifetime("max-age=999999", age: "35"), 86365)
        for invalid in ["invalid", "nan", "inf"] {
            XCTAssertEqual(ResetNewsService.cacheLifetime("max-age=" + invalid, age: nil), 60)
            XCTAssertEqual(ResetNewsService.cacheLifetime("max-age=100", age: invalid), 100)
        }
        XCTAssertEqual(ResetNewsService.cacheLifetime(nil, age: "-1"), 60)
    }

    func testPublicSnapshotRegressionAndRevalidationPreserveGeneratedTime() throws {
        let cached = publicEnvelope(publicData(scheduled: scheduledRecord()))
        let older = publicEnvelope(publicData(latest: resetRecord(kind: "banked")), generatedAt: "2026-10-08T09:58:00Z")
        let newer = publicEnvelope(publicData(), generatedAt: "2026-10-08T10:00:00Z")
        XCTAssertTrue(ResetNewsService.isOlderSnapshot(older, than: cached))
        XCTAssertFalse(ResetNewsService.isOlderSnapshot(newer, than: cached))
        XCTAssertFalse(ResetNewsService.isOlderSnapshot(cached, than: cached))
        XCTAssertFalse(ResetNewsService.isOlderSnapshot([:], than: cached))
        XCTAssertFalse(ResetNewsService.isOlderSnapshot(cached, than: [:]))
        XCTAssertFalse(ResetNewsService.isOlderSnapshot(publicEnvelope(publicData(), generatedAt: "invalid"), than: cached))
        let original = try ResetNewsParser.parse(status: cached, at: publicNow, expiresAt: publicNow.addingTimeInterval(60))
        // A 304 reuses this body; later receipt/cache expiry is not a newer observation.
        let revalidated = try ResetNewsParser.parse(status: cached, at: publicNow.addingTimeInterval(60),
            expiresAt: publicNow.addingTimeInterval(3600))
        XCTAssertEqual(revalidated.updatedAt, original.updatedAt)
        XCTAssertEqual(revalidated.updatedAt, publicNow.addingTimeInterval(-60))
        XCTAssertEqual(revalidated.reference?.referenceAt, original.reference?.referenceAt)
    }

}

@main
struct QuotaChecks {
    static func main() throws {
        let tests = QuotaParserTests()
        tests.testCodexMultipleBucketsReplaceLegacyView()
        tests.testNullOrMissingPercentIsUnknown()
        tests.testClaudeMissingWindowsAreNotFabricated()
        tests.testExpiredSnapshotDoesNotClaimResetHappened()
        tests.testCountdownAndPercentageBounds()
        tests.testRemainingBarsAndPaceDirection()
        tests.testTimeUnknownAndExpiredAreNotFabricated()
        tests.testQuotaColorsCompareRemainingQuotaWithRemainingTime()
        tests.testExactResetDatesUseAmsterdamAndDaylightSaving()
        tests.testCollapsedSummaryKeepsQuotaAndResetFromSameOverallWindow()
        tests.testCollapsedSummaryMissingExpiredAndNearResetAreTruthful()
        tests.testVerticalSummarySplitsDaysAndRemainingHours()
        tests.testObservedEarlyRecoveryAnchorsUnchangedDeadline()
        tests.testAvailableResetCountUnknownAndZeroAreDistinct()
        tests.testSmallUsageCorrectionDoesNotRestartTimeBar()
        try tests.testPublicEnvelopeUsesGeneratedTimestampAndNewDomain()
        tests.testPublicMalformedOrUnsupportedEnvelopeFailsClosed()
        try tests.testBankedGrantIsManualAndNotGlobalReset()
        try tests.testRegularAndObservedHeadlinesMatchSourceEvidence()
        try tests.testActiveWatchProbabilityIsEstimateAndNotDeadline()
        try tests.testExpiredFutureInvalidWatchesNeverPublishProbability()
        try tests.testExplicitScheduledReferenceKeepsExactTargetAndRemainingScale()
        tests.testScheduledReferenceRequiresExplicitFutureRegularAnnouncement()
        tests.testScheduledReferenceRejectsUntrustedOrObservedSource()
        try tests.testLaterRegularResetCancelsPredictionButBankedGrantDoesNot()
        try tests.testSourceFreshnessAndErrorsHidePredictionWithoutInventingLegacyTarget()
        tests.testRetryAfterHonoursBothSecondsAndHTTPDate()
        tests.testPublicCacheLifetimeUsesClientMaxAgeAndSubtractsAge()
        try tests.testPublicSnapshotRegressionAndRevalidationPreserveGeneratedTime()
        print("29 quota, pacing, reset-date, collapsed-summary, early recovery and public-reset checks passed")
        ClaudeUsageChecks.run()
        print("12 Claude live-usage and freshness checks passed")
    }
}
