import Foundation

@main
struct PacingGuideChecks {
    static let base = Date(timeIntervalSince1970: 1_900_000_000)
    static func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
    static func require(_ value: Bool, _ message: String) { precondition(value, message) }
    static func near(_ actual: Double, _ expected: Double) { require(abs(actual - expected) < 0.000001, "Expected \(expected), received \(actual)") }
    static func window(reset: Double? = 1800, duration: Double? = 1800, anchor: Double? = nil, id: String = "codex.primary") -> QuotaWindow {
        QuotaWindow(id: id, name: "5小时额度", usedPercent: 40, resetsAt: reset.map(date), durationSeconds: duration, cycleStartedAt: anchor.map(date))
    }
    static func reference(target: Double = 1200, expiry: Double? = nil, kind: WebsiteResetReference.TargetKind = .deadline) -> WebsiteResetReference {
        WebsiteResetReference(startAt: date(700), referenceAt: date(target), windowStartAt: date(target), windowEndAt: date(expiry ?? target), targetKind: kind)
    }
    static func reset(_ at: Double, deadline: Double? = 1800, provider: HistoryProvider = .codex, id: String = "codex.primary") -> HistoryResetRecord {
        HistoryResetRecord(id: UUID(), provider: provider, windowID: id, windowName: "5小时额度",
            observedAt: date(at), previousObservedAt: date(at - 10), previousUsedPercent: 90, usedPercent: 0,
            previousResetsAt: date(1000), resetsAt: deadline.map(date))
    }

    static func endpointsAndClipping() {
        let guides = QuotaPacingGuide.make(provider: .codex, window: window(), at: date(900))
        require(guides.count == 1 && guides[0].anchor == .officialWindowDuration, "Known official duration identifies the nominal cycle")
        let guide = guides[0]
        near(guide.percent(at: date(-100)), 0); near(guide.percent(at: date(0)), 0)
        near(guide.percent(at: date(900)), 50); near(guide.percent(at: date(1800)), 100)
        near(guide.percent(at: date(1900)), 100)
        let clipped = guide.clippedPoints(in: DateInterval(start: date(450), end: date(1350)))
        require(clipped.count == 2, "Clipped guide has two real endpoints")
        near(clipped[0].usedPercent, 25); near(clipped[1].usedPercent, 75)
        require(guide.clippedPoints(in: DateInterval(start: date(1801), end: date(2000))).isEmpty, "Guides do not extend beyond their cycle")
    }

    static func earlyAnchorAndPredictionShareStart() {
        let guides = QuotaPacingGuide.make(provider: .codex, window: window(anchor: 400), reference: reference(), at: date(900))
        require(guides.count == 2 && guides.allSatisfy { $0.startAt == date(400) && $0.anchor == .liveCycleStart }, "A live early-recovery anchor overrides nominal duration for both guides")
        require(guides[0].source == .official && guides[1].source == .codexResetForecast, "Official and forecast sources remain separate")
        near(guides[0].percent(at: date(900)), 500.0 / 1400 * 100)
        near(guides[1].percent(at: date(900)), 62.5)
        near(guides[1].percent(at: date(1200)), 100)
        require(guides[1].sourceURL?.host == "codex-resets.com", "Prediction preserves its source")
    }

    static func unknownDurationRequiresMatchingObservedCycle() {
        let history = [reset(500), reset(600), reset(800, deadline: 1700), reset(850, provider: .claude), reset(880, id: "codex.secondary")]
        let guides = QuotaPacingGuide.make(provider: .codex, window: window(duration: nil), resetHistory: history, at: date(900))
        require(guides.count == 1 && guides[0].startAt == date(600) && guides[0].anchor == .observedReset, "Only the newest reset matching provider, window and current deadline anchors an unknown duration")
        require(QuotaPacingGuide.make(provider: .codex, window: window(duration: nil), resetHistory: [reset(800, deadline: 1700)], at: date(900)).isEmpty, "Another cycle cannot supply this cycle's start")
        require(QuotaPacingGuide.make(provider: .codex, window: window(duration: nil), at: date(900)).isEmpty, "Application recording start is never invented as a cycle start")
    }

    static func restartRestoresNearFullEarlyRecoveryAnchor() {
        func event(_ used: Double) -> HistoryResetRecord {
            HistoryResetRecord(id: UUID(), provider: .codex, windowID: "codex.primary", windowName: "5小时额度",
                observedAt: date(600), previousObservedAt: date(590), previousUsedPercent: 90, usedPercent: used,
                previousResetsAt: date(1800), resetsAt: date(1800))
        }
        let recovered = event(0)
        let guides = QuotaPacingGuide.make(provider: .codex, window: window(), resetHistory: [recovered], reference: reference(), at: date(900))
        require(guides.count == 2 && guides.allSatisfy { $0.startAt == date(600) && $0.anchor == .observedReset }, "A persisted near-full same-deadline recovery restores both pacing anchors after restart")
        near(guides[0].percent(at: date(900)), 25)
        let partial = QuotaPacingGuide.make(provider: .codex, window: window(), resetHistory: [event(20)], at: date(900))
        require(partial[0].startAt == date(0) && partial[0].anchor == .officialWindowDuration, "A partial quota decrease must not replace a known official cycle")
        let explicit = QuotaPacingGuide.make(provider: .codex, window: window(anchor: 400), resetHistory: [recovered], at: date(900))
        require(explicit[0].startAt == date(400) && explicit[0].anchor == .liveCycleStart, "The explicit live anchor remains authoritative")
    }

    static func unavailableAndExpiredNeverProduceGuides() {
        require(QuotaPacingGuide.make(provider: .codex, window: window(reset: nil), at: date(900)).isEmpty, "Unknown deadline cannot define a pacing guide")
        require(QuotaPacingGuide.make(provider: .codex, window: window(reset: 900), at: date(900)).isEmpty, "Expired deadlines are hidden")
        require(QuotaPacingGuide.make(provider: .codex, window: window(duration: 60), at: date(900)).isEmpty, "A future nominal start is not an active cycle")
        require(QuotaPacingGuide.make(provider: .codex, window: window(duration: nil, anchor: 1000), at: date(900)).isEmpty, "Invalid future anchors cannot create a cycle")
    }

    static func invalidForecastsLeaveOfficialOnly() {
        for value in [reference(target: 900), reference(target: 1800), reference(target: 1900), reference(expiry: 800), reference(kind: .center)] {
            require(QuotaPacingGuide.make(provider: .codex, window: window(), reference: value, at: date(900)).count == 1, "Expired, late, closed, and uncertain forecasts cannot create an early-reset line")
        }
        require(QuotaPacingGuide.make(provider: .claude, window: window(id: "five_hour"), reference: reference(), at: date(900)).count == 1, "A Codex public prediction never applies to Claude")
    }

    static func main() {
        endpointsAndClipping(); earlyAnchorAndPredictionShareStart(); unknownDurationRequiresMatchingObservedCycle()
        restartRestoresNearFullEarlyRecoveryAnchor(); unavailableAndExpiredNeverProduceGuides(); invalidForecastsLeaveOfficialOnly()
        print("6 pacing-guide endpoint, clipping, anchor, cycle, expiry and prediction checks passed")
    }
}
