import Foundation

@main
struct ResetWatchChecks {
    static let now = ResetNewsParser.date("2026-10-16T10:00:00Z")!
    static let observed = ResetNewsParser.date("2026-10-16T04:30:52Z")!
    static let target = ResetNewsParser.date("2026-10-17T05:00:00Z")!

    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func near(_ actual: Double, _ expected: Double, _ message: String) {
        require(abs(actual - expected) < 0.000001, message)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func source(_ id: String = "2110951585983631505") -> [String: Any] {
        ["type": "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/" + id]
    }
    static func watch() -> [String: Any] {
        // Public API structure captured on 2026-10-16. The watch has no event ID
        // and its explicit expiry is later than observed_at + the rounded 24h label.
        ["level": "elevated", "reset_chance_percent": 40, "forecast_window": "within 24h",
         "observed_at": "2026-10-16T04:30:52.000Z", "expires_at": "2026-10-17T05:00:00.000Z",
         "source": source()]
    }
    static func reset(kind: String = "regular", at: Date = observed.addingTimeInterval(-86400)) -> [String: Any] {
        ["id": "2110618732666257557", "reset_type": kind, "announced_at": iso(at),
         "source": source("2110618732666257557")]
    }
    static func scheduled() -> [String: Any] {
        ["id": "2110951585983631505", "status": "scheduled", "reset_type": "regular",
         "announced_at": iso(now.addingTimeInterval(-1800)), "scheduled_for": iso(now.addingTimeInterval(3600)),
         "source": source()]
    }
    static func data(watch: Any = watch(), latest: Any = reset(), scheduled: Any = NSNull()) -> [String: Any] {
        ["latest_reset": latest, "scheduled_reset": scheduled, "active_watch": watch,
         "stats": ["total": 62, "days_since_last": 1.1, "avg_interval_days": 6.4]]
    }
    static func envelope(_ data: [String: Any]) -> [String: Any] {
        ["meta": ["api_version": "v1", "generated_at": "2026-10-16T09:46:32.617Z"], "data": data]
    }
    static func parsed(_ data: [String: Any]) throws -> ResetNewsState {
        try ResetNewsParser.parse(status: envelope(data), at: now, expiresAt: now.addingTimeInterval(120))
    }

    static func realWatchPublishesWindow() throws {
        let state = try parsed(data())
        guard let reference = state.reference else { preconditionFailure("The current explicit public watch must produce an additional time bar") }
        require(reference.targetKind == .forecastWindow, "A probabilistic watch must retain its distinct kind")
        require(reference.startAt == observed && reference.windowStartAt == observed, "The interval starts at the published observation")
        require(reference.referenceAt == target && reference.windowEndAt == target, "The displayed deadline uses the explicit published expiry without rounding or inventing a target")
        require(state.canShowReference(at: now), "The verified current watch should be visible")
        require(state.detail?.contains("40%") == true, "Probability remains available as context")
        require(state.detail?.contains("额外时间条已隐藏") != true, "The valid watch should not claim its bar is hidden")
    }

    static func remainingUsesPublishedEndpoints() {
        let reference = ResetNewsParser.prediction(data(), at: now)!
        let midpoint = observed.addingTimeInterval(target.timeIntervalSince(observed) / 2)
        near(reference.remainingPercent(at: observed), 100, "A watch starts with its full published interval")
        near(reference.remainingPercent(at: midpoint), 50, "Half of the actual published interval gives 50 percent")
        near(reference.remainingPercent(at: target), 0, "The published expiry is zero")
        near(reference.remainingPercent(at: target.addingTimeInterval(1)), 0, "Expired values clamp at zero")
        let state = ResetNewsState(message: nil, reference: reference)
        require(state.canShowReference(at: observed), "The observation boundary is inclusive")
        require(!state.canShowReference(at: observed.addingTimeInterval(-1)), "A future observation cannot be shown early")
        require(!state.canShowReference(at: target), "The expiry boundary is exclusive")
    }

    static func noExplicitWindowNeverInventsDeadline() {
        for text in ["next few hours", "tomorrow", "", "within two hours", "within 0h", "within -1h"] {
            var record = watch(); record["forecast_window"] = text
            require(ResetNewsParser.prediction(data(watch: record), at: now) == nil, "An indefinite or invalid window must not become a countdown: " + text)
        }
        for key in ["forecast_window", "expires_at", "observed_at"] {
            var record = watch(); record.removeValue(forKey: key)
            require(ResetNewsParser.prediction(data(watch: record), at: now) == nil, "A required public watch field cannot be inferred: " + key)
        }
        var noWindow = watch(); noWindow["forecast_window"] = NSNull()
        require(ResetNewsParser.prediction(data(watch: noWindow), at: now) == nil, "Null forecast text is not an explicit interval")
        require(ResetNewsParser.prediction(data(watch: NSNull()), at: now) == nil, "No announcement means no additional bar")
    }

    static func supportedExplicitUnitsAndLevels() {
        for (text, span): (String, TimeInterval) in [("within 30m", 1800), ("within 2h", 7200), ("within 3d", 259200)] {
            for level in ["elevated", "strong"] {
                var record = watch(); record["forecast_window"] = text; record["level"] = level
                record["observed_at"] = iso(now.addingTimeInterval(-span / 2))
                let expiry = now.addingTimeInterval(span / 2)
                record["expires_at"] = iso(expiry)
                let reference = ResetNewsParser.prediction(data(watch: record, latest: NSNull()), at: now)
                require(reference?.targetKind == .forecastWindow && reference?.referenceAt == expiry, "Supported numeric units qualify the published explicit expiry")
            }
        }
        var mismatched = watch(); mismatched["forecast_window"] = "within 2h"
        require(ResetNewsParser.prediction(data(watch: mismatched), at: now) == nil, "An unrelated distant expiry must not become the deadline of a short forecast")
    }

    static func invalidWatchTimingLevelAndSourceAreRejected() {
        let changes: [(String, Any)] = [
            ("expires_at", iso(now)), ("expires_at", iso(now.addingTimeInterval(-1))),
            ("expires_at", "invalid"), ("observed_at", iso(now.addingTimeInterval(1))),
            ("observed_at", "invalid"), ("level", "unknown"), ("level", "none"),
            ("source", ["type": "x_post", "author": "unknown", "url": "https://x.com/unknown/status/2110951585983631505"]),
            ("source", ["type": "x_post", "author": "thsottiaux", "url": "https://example.com/thsottiaux/status/2110951585983631505"])
        ]
        for (key, value) in changes {
            var record = watch(); record[key] = value
            require(ResetNewsParser.prediction(data(watch: record), at: now) == nil, "An invalid watch must remain hidden: " + key)
        }
    }

    static func scheduledAnnouncementHasPriority() {
        let reference = ResetNewsParser.prediction(data(scheduled: scheduled()), at: now)
        require(reference?.targetKind == .deadline, "A concrete scheduled reset takes precedence over a probabilistic window")
        require(reference?.referenceAt == now.addingTimeInterval(3600), "Scheduled priority preserves its exact scheduled_for")
    }

    static func actualResetCancelsWatchButBankedGrantDoesNot() {
        let later = observed.addingTimeInterval(60)
        require(ResetNewsParser.prediction(data(latest: reset(at: later)), at: now) == nil, "A newer regular reset invalidates the preceding watch")
        let banked = ResetNewsParser.prediction(data(latest: reset(kind: "banked", at: later)), at: now)
        require(banked?.targetKind == .forecastWindow, "A manual banked grant does not cancel a global reset watch")
        let earlier = ResetNewsParser.prediction(data(latest: reset(at: observed.addingTimeInterval(-1))), at: now)
        require(earlier?.targetKind == .forecastWindow, "A preceding reset must not hide a newer watch")
    }

    static func failedOrStalePublicDataRemainsHidden() throws {
        let document = envelope(data())
        let stale = try ResetNewsParser.parse(status: document, at: now, sourceIsStale: true)
        require(!stale.canShowReference(at: now), "A stale upstream response cannot publish a live countdown")
        let expired = try ResetNewsParser.parse(status: document, at: now, expiresAt: now)
        require(!expired.canShowReference(at: now), "An expired public snapshot stays hidden")
        var failed = try parsed(data()); failed.message = "公共重置信息暂不可用"
        require(!failed.canShowReference(at: now), "An unsuccessful refresh cannot imply a confirmed current watch")
    }

    static func confidenceBoundariesStayDistinctFromAnnouncements() {
        for value in [0, 39, 40, 69, 70, 100] {
            var record = watch(); record["reset_chance_percent"] = value
            let reference = ResetNewsParser.prediction(data(watch: record), at: now)!
            require(reference.confidencePercent == Double(value), "A published integer probability is retained exactly")
            if value < 40 { require(reference.confidence == .low, "Low confidence includes 0 through 39 percent") }
            else if value < 70 { require(reference.confidence == .medium, "Medium confidence includes 40 through 69 percent") }
            else { require(reference.confidence == .high, "High confidence includes 70 through 100 percent") }
        }
        let invalid: [Any] = [true, false, -1, 101, 39.5, Double.nan, Double.infinity, "40", NSNull()]
        for value in invalid {
            var record = watch(); record["reset_chance_percent"] = value
            let reference = ResetNewsParser.prediction(data(watch: record), at: now)!
            require(reference.confidencePercent == nil && reference.confidence == .unknown, "An invalid probability must not fabricate confidence or remove a valid timed watch")
        }
        var missing = watch(); missing.removeValue(forKey: "reset_chance_percent")
        let unknown = ResetNewsParser.prediction(data(watch: missing), at: now)!
        require(unknown.confidencePercent == nil && unknown.confidence == .unknown, "A timed watch without a probability has unknown confidence")
        let announcement = ResetNewsParser.prediction(data(scheduled: scheduled()), at: now)!
        require(announcement.confidence == .announced && announcement.confidencePercent == nil, "An announced reset must not inherit a separate watch's probability")
    }

    static func chartUsesWatchOnlyForApplicableCodexCycle() {
        let reference = ResetNewsParser.prediction(data(), at: now)!
        let start = now.addingTimeInterval(-3600)
        func window(_ deadline: Date?, id: String = "codex.primary") -> QuotaWindow {
            QuotaWindow(id: id, name: "额度", usedPercent: 40, resetsAt: deadline,
                        durationSeconds: nil, cycleStartedAt: start)
        }
        let deadline = target.addingTimeInterval(86400)
        let guides = QuotaPacingGuide.make(provider: .codex, window: window(deadline), reference: reference, at: now)
        require(guides.count == 2 && guides[1].source == .codexResetForecast, "An earlier explicit watch adds a Codex guide")
        require(guides.allSatisfy { $0.startAt == start }, "Both guides use the actual account cycle start")
        require(guides[1].targetAt == target, "The watch guide ends at the published expiry")
        require(guides[1].forecastConfidence == .medium && guides[0].forecastConfidence == nil, "The forecast guide carries its probability color without changing the official guide")
        for official in [target, target.addingTimeInterval(-1)] {
            let values = QuotaPacingGuide.make(provider: .codex, window: window(official), reference: reference, at: now)
            require(values.count == 1, "A watch later than or equal to the normal reset cannot act as an early-reset guide")
        }
        let claude = QuotaPacingGuide.make(provider: .claude, window: window(deadline, id: "five_hour"), reference: reference, at: now)
        require(claude.count == 1 && claude[0].source == .official, "The Codex watch never applies to Claude")
        require(QuotaPacingGuide.make(provider: .codex, window: window(nil), reference: reference, at: now).isEmpty, "A public watch cannot invent the account cycle")
    }

    static func main() throws {
        try realWatchPublishesWindow(); remainingUsesPublishedEndpoints()
        noExplicitWindowNeverInventsDeadline(); supportedExplicitUnitsAndLevels()
        invalidWatchTimingLevelAndSourceAreRejected(); scheduledAnnouncementHasPriority()
        actualResetCancelsWatchButBankedGrantDoesNot(); try failedOrStalePublicDataRemainsHidden()
        confidenceBoundariesStayDistinctFromAnnouncements(); chartUsesWatchOnlyForApplicableCodexCycle()
        print("10 reset-watch fixture, timing, provenance, precedence, reset and chart checks passed")
    }
}
