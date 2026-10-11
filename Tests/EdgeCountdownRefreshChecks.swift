import Foundation

@main
struct EdgeCountdownRefreshChecks {
    static let now = Date(timeIntervalSince1970: 1_900_000_000)
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func near(_ actual: Double, _ expected: Double) { require(abs(actual - expected) < 0.00001, "Expected \(expected), got \(actual)") }
    static func provider(_ remaining: Double?, name: String = "Codex", used: Double = 50, duration: Double? = nil) -> ProviderState {
        var value = ProviderState(name: name)
        value.windows = [QuotaWindow(id: name == "Codex" ? "codex.primary" : "five_hour", name: "额度", usedPercent: used,
            resetsAt: remaining.map { now.addingTimeInterval($0) }, durationSeconds: duration)]
        return value
    }
    static func update(_ providers: [ProviderState]) -> Date {
        guard let value = EdgeCountdownRefresh.nextUpdate(providers: providers, after: now) else { preconditionFailure("Expected a visible future boundary") }
        return value
    }
    static func text(_ provider: ProviderState, at date: Date) -> String { EdgeQuotaSummary(provider: provider, at: date).hourComponentText }

    static func hourRoundingBoundaries() {
        let decimal = provider(2 * 3600)
        let next = update([decimal])
        near(next.timeIntervalSince(now), 180.001)
        require(text(decimal, at: now) == "2.0h" && text(decimal, at: next) == "1.9h", "Decimal hours wake exactly when the visible tenth changes")
        let integer = provider(11.2 * 3600)
        let later = update([integer])
        near(later.timeIntervalSince(now), 2520.001)
        require(text(integer, at: now) == "11h" && text(integer, at: later) == "10h", "Long integer hours have no minute/second polling")
    }

    static func hourToMinuteAndMinuteFloors() {
        let value = provider(3600.5)
        let next = update([value])
        near(next.timeIntervalSince(now), 0.501)
        require(text(value, at: now) == "1.0h" && text(value, at: next) == "59m", "Below one hour uses minutes, never 0.9h")
        let minutes = provider(120.5)
        let following = update([minutes])
        near(following.timeIntervalSince(now), 0.501)
        require(text(minutes, at: now) == "2m" && text(minutes, at: following) == "1m", "Minute display follows its floor boundary")
    }

    static func minuteToSecondsAndLastSecond() {
        let value = provider(60.5)
        let next = update([value])
        near(next.timeIntervalSince(now), 0.501)
        require(text(value, at: now) == "1m" && text(value, at: next) == "59s", "Below one minute uses seconds")
        let seconds = provider(10.4)
        let tick = update([seconds])
        near(tick.timeIntervalSince(now), 0.401)
        require(text(seconds, at: tick) == "9s", "Seconds wake only on a changed integer")
        let final = provider(1.2)
        let expired = update([final])
        near(expired.timeIntervalSince(now), 1.201)
        require(text(final, at: now) == "1s" && text(final, at: expired) == "—", "The last second remains 1s until true expiry")
    }

    static func daysCarryAndLongSleep() {
        let carry = provider(47.8 * 3600)
        let next = update([carry])
        near(next.timeIntervalSince(now), 1080.001)
        let before = EdgeQuotaSummary(provider: carry, at: now)
        let after = EdgeQuotaSummary(provider: carry, at: next)
        require(before.daysText == "2d" && after.daysText == "1d" && after.hourComponentText == "23h", "Day carry changes at the existing integer rounding boundary")
        let long = provider((7 * 24 + 14.25) * 3600)
        require(update([long]).timeIntervalSince(now) > 2600, "A long countdown sleeps until a real display change")
    }

    static func expiryCanSelectAnotherQuota() {
        var value = provider(0.5, used: 90)
        value.windows.append(QuotaWindow(id: "codex.secondary", name: "周额度", usedPercent: 20, resetsAt: now.addingTimeInterval(900)))
        let next = update([value])
        near(next.timeIntervalSince(now), 0.501)
        require(EdgeQuotaSummary(provider: value, at: next).window?.id == "codex.secondary", "Expiry promptly selects the next available quota")
        var unchanged = provider(2 * 3600, used: 90)
        unchanged.windows.append(QuotaWindow(id: "codex.secondary", name: "周额度", usedPercent: 20, resetsAt: now.addingTimeInterval(30)))
        near(update([unchanged]).timeIntervalSince(now), 180.001)
        require(update([unchanged]).timeIntervalSince(now) > 30, "An unselected expiry that changes no visible value does not wake the widget")
    }

    static func missingAndExpiredDeadlinesStopTheClock() {
        require(EdgeCountdownRefresh.nextUpdate(providers: [provider(nil)], after: now) == nil, "Unknown deadlines need no timer")
        require(EdgeCountdownRefresh.nextUpdate(providers: [provider(-1)], after: now) == nil, "Already expired windows do not poll for a reset")
        require(EdgeCountdownRefresh.nextUpdate(providers: [], after: now) == nil, "No quota data means no scheduled wake")
    }

    static func bothProvidersChooseEarliestBoundary() {
        let codex = provider(2 * 3600)
        let claude = provider(150.5, name: "Claude Code")
        near(update([codex, claude]).timeIntervalSince(now), 30.501)
    }

    static func paceColorsChangeWithoutAChangedNumber() {
        let remaining = 11.6 * 3600
        let span = 24.0 * 3600
        let crossingTimePercent = (remaining - 100) / span * 100
        for quota in [crossingTimePercent - 15, crossingTimePercent + 5] {
            let value = provider(remaining, used: 100 - quota, duration: span)
            let next = update([value])
            near(next.timeIntervalSince(now), 100.001)
            let before = EdgeQuotaSummary(provider: value, at: now)
            let after = EdgeQuotaSummary(provider: value, at: next)
            require(before.hourComponentText == after.hourComponentText && before.pace != after.pace, "Color thresholds update even while countdown text is unchanged")
        }
    }

    static func main() {
        hourRoundingBoundaries(); hourToMinuteAndMinuteFloors(); minuteToSecondsAndLastSecond()
        daysCarryAndLongSleep(); expiryCanSelectAnotherQuota(); missingAndExpiredDeadlinesStopTheClock()
        bothProvidersChooseEarliestBoundary(); paceColorsChangeWithoutAChangedNumber()
        print("8 edge-countdown rounding, units, days, expiry, idle, provider and pace checks passed")
    }
}
