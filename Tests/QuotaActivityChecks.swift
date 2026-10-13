import Foundation

@main
struct QuotaActivityChecks {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let deadline = start.addingTimeInterval(18_000)
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }
    static func window(_ used: Double?, id: String = "five_hour", reset: Date? = deadline,
                       duration: TimeInterval? = 18_000, cycle: Date? = nil) -> QuotaWindow {
        QuotaWindow(id: id, name: id, usedPercent: used, resetsAt: reset,
                    durationSeconds: duration, cycleStartedAt: cycle)
    }
    static func state(_ used: Double?, at seconds: TimeInterval, name: String = "Claude Code",
                      reset: Date? = deadline, windows: [QuotaWindow]? = nil) -> ProviderState {
        var result = ProviderState(name: name)
        result.updatedAt = start.addingTimeInterval(seconds)
        result.windows = windows ?? [window(used, reset: reset)]
        return result
    }
    static func observe(_ estimator: inout QuotaActivityEstimator, _ used: Double?, at seconds: TimeInterval,
                        reset: Date? = deadline) -> QuotaActivityEstimate? {
        estimator.observe(state(used, at: seconds, reset: reset), at: start.addingTimeInterval(seconds))
    }

    static func baselineAndActualInterval() {
        var e = QuotaActivityEstimator()
        require(observe(&e, 10, at: 0) == nil, "First successful result establishes a baseline")
        let slow = observe(&e, 11, at: 60)!
        require(slow.percentPerMinute == 1 && slow.sampledFrom == start, "Use actual capture interval and keep its start")
        require(slow.expiresAt == start.addingTimeInterval(135), "Fresh estimate expires 75 seconds after observation")
        let fast = observe(&e, 12, at: 90)!
        require(fast.percentPerMinute == 2 && fast.sampledFrom == start.addingTimeInterval(60), "Shorter interval reflects faster percentage consumption")
    }
    static func unchangedAndRecovery() {
        var e = QuotaActivityEstimator(); _ = observe(&e, 30, at: 0)
        require(observe(&e, 30, at: 60) == nil, "No growth stops the estimate")
        require(observe(&e, 3, at: 120) == nil, "Percentage recovery cannot be consumption")
        let next = observe(&e, 4, at: 180)!
        require(next.percentPerMinute == 1 && next.sampledFrom == start.addingTimeInterval(120), "Recovery becomes a new baseline")
        e.reset(); require(observe(&e, 20, at: 240) == nil, "After query failure/reset, first success is only a baseline")
    }
    static func cycleChanges() {
        var e = QuotaActivityEstimator(); _ = observe(&e, 10, at: 0)
        let changed = deadline.addingTimeInterval(18_000)
        require(observe(&e, 40, at: 60, reset: changed) == nil, "A changed reset deadline is a different cycle")
        require(observe(&e, 41, at: 120, reset: changed)?.percentPerMinute == 1, "New cycle needs two comparable results")
        let newCycle = window(45, reset: changed, cycle: start.addingTimeInterval(150))
        require(e.observe(state(nil, at: 180, windows: [newCycle]), at: start.addingTimeInterval(180)) == nil, "An observed hidden reset anchor also rebases")
        let changedDuration = window(46, reset: changed, duration: 36_000, cycle: start.addingTimeInterval(150))
        require(e.observe(state(nil, at: 240, windows: [changedDuration]), at: start.addingTimeInterval(240)) == nil, "Changed duration cannot share a speed baseline")
    }
    static func duplicateAndOutOfOrder() {
        var e = QuotaActivityEstimator(); _ = observe(&e, 10, at: 0)
        require(e.observe(state(90, at: 0), at: start.addingTimeInterval(20)) == nil, "Duplicate timestamps cannot invent speed")
        require(e.observe(state(90, at: -1), at: start.addingTimeInterval(30)) == nil, "Out-of-order data is ignored")
        require(e.observe(state(80, at: 61), at: start.addingTimeInterval(40)) == nil, "Future captures are ignored")
        require(observe(&e, 11, at: 60)?.percentPerMinute == 1, "Rejected deliveries do not replace the legitimate baseline")
        var loading = state(40, at: 120); loading.isLoading = true
        require(e.observe(loading, at: start.addingTimeInterval(120)) == nil, "A loading snapshot is not a successful response")
    }
    static func freshnessAndDeadline() {
        var e = QuotaActivityEstimator()
        require(e.observe(state(10, at: 0), at: start.addingTimeInterval(301)) == nil, "Over five-minute old data cannot establish a baseline")
        require(e.observe(state(10, at: 60), at: start.addingTimeInterval(360)) == nil, "Five-minute boundary is valid baseline")
        require(e.observe(state(11, at: 120), at: start.addingTimeInterval(400)) == nil, "A valid delayed snapshot only rebases, without historical rotation")
        require(e.observe(state(20, at: 420), at: start.addingTimeInterval(420)) == nil, "Large gap needs a new recent baseline")
        let result = e.observe(state(21, at: 480), at: start.addingTimeInterval(500))!
        require(result.percentPerMinute == 1 && result.expiresAt == start.addingTimeInterval(555), "Delayed delivery cannot extend expiry beyond the capture plus 75 seconds")
        var expired = QuotaActivityEstimator(); _ = observe(&expired, 10, at: 0, reset: start.addingTimeInterval(60))
        require(observe(&expired, 80, at: 60, reset: start.addingTimeInterval(60)) == nil, "Expired quota never creates rotation")
    }
    static func intervalBounds() {
        for (seconds, allowed) in [(4.0, false), (5, true), (180, true), (181, false)] {
            var e = QuotaActivityEstimator(); _ = observe(&e, 10, at: 0)
            let next = observe(&e, 11, at: seconds)
            require((next != nil) == allowed, "Require actual interval from 5 through 180 seconds")
            if let next { require(next.percentPerMinute == 60 / seconds, "Interval rate uses no assumed polling frequency") }
            if !allowed { require(observe(&e, 12, at: seconds + 60)?.percentPerMinute == 1, "Rejected interval still establishes the next fresh baseline") }
        }
    }
    static func invalidNumbers() {
        for used: Double? in [nil, .nan, .infinity, -.infinity, -1, 101] {
            var e = QuotaActivityEstimator(); _ = observe(&e, 10, at: 0)
            require(observe(&e, used, at: 60) == nil, "Reject invalid or missing percentages")
            require(observe(&e, 20, at: 120) == nil, "Invalid successful payload clears the prior comparison")
        }
        var e = QuotaActivityEstimator(); _ = observe(&e, 0, at: 0)
        require(observe(&e, 100, at: 60)?.percentPerMinute == 100, "Zero and 100 are valid bounds")
        require(e.observe(state(50, at: 120), at: Date(timeIntervalSince1970: .nan)) == nil, "Reject invalid observation time")
        var invalidStamp = state(50, at: 120); invalidStamp.updatedAt = Date(timeIntervalSince1970: .infinity)
        require(e.observe(invalidStamp, at: start.addingTimeInterval(120)) == nil, "Reject invalid captured timestamp")
        for invalid in [window(10, reset: Date(timeIntervalSince1970: .nan)), window(10, duration: .nan), window(10, duration: 0), window(10, cycle: Date(timeIntervalSince1970: .infinity))] {
            var value = QuotaActivityEstimator()
            require(value.observe(state(nil, at: 0, windows: [invalid]), at: start) == nil, "Reject invalid cycle metadata")
            require(observe(&value, 11, at: 60) == nil, "Invalid metadata did not establish a baseline")
        }
    }
    static func chooseSingleOverallWindow() {
        var e = QuotaActivityEstimator()
        let first = [window(40, id: "seven_day", duration: 604_800), window(10), window(1, id: "seven_day_sonnet", duration: 604_800)]
        let second = [window(60, id: "seven_day", duration: 604_800), window(11), window(99, id: "seven_day_sonnet", duration: 604_800)].reversed()
        _ = e.observe(state(nil, at: 0, windows: first), at: start)
        require(e.observe(state(nil, at: 60, windows: Array(second)), at: start.addingTimeInterval(60))?.percentPerMinute == 1, "Prefer five_hour and never add overlapping weekly/model buckets")
        var codex = QuotaActivityEstimator()
        let windows = [window(20, id: "codex.secondary", duration: 604_800), window(10, id: "codex.primary", duration: 18_000), window(0, id: "other.primary", duration: 60)]
        _ = codex.observe(state(nil, at: 0, name: "Codex", windows: windows), at: start)
        let newer = [window(90, id: "codex.secondary", duration: 604_800), window(11, id: "codex.primary", duration: 18_000), window(99, id: "other.primary", duration: 60)]
        require(codex.observe(state(nil, at: 60, name: "Codex", windows: newer), at: start.addingTimeInterval(60))?.percentPerMinute == 1, "Shortest overall Codex window wins without model-specific extras")
    }
    static func selectionChangesAndMissingWindow() {
        var e = QuotaActivityEstimator()
        _ = e.observe(state(nil, at: 0, windows: [window(20, id: "seven_day", duration: 604_800)]), at: start)
        require(e.observe(state(nil, at: 60, windows: [window(21, id: "seven_day", duration: 604_800)]), at: start.addingTimeInterval(60))?.percentPerMinute == 1, "Weekly fallback may measure its own stable window")
        require(observe(&e, 80, at: 120) == nil, "A newly available preferred window starts a baseline")
        require(e.observe(state(nil, at: 180, windows: []), at: start.addingTimeInterval(180)) == nil, "Missing windows clear comparison")
        require(observe(&e, 90, at: 240) == nil, "Returning data cannot bridge a missing payload")
        var duplicate = QuotaActivityEstimator()
        _ = duplicate.observe(state(nil, at: 0, windows: [window(10), window(30)]), at: start)
        require(observe(&duplicate, 40, at: 60) == nil, "Ambiguous duplicate IDs never establish an order-dependent baseline")
        var spend = QuotaActivityEstimator()
        _ = spend.observe(state(nil, at: 0, windows: [window(1, id: "spend_limit")]), at: start)
        require(spend.observe(state(nil, at: 60, windows: [window(50, id: "spend_limit")]), at: start.addingTimeInterval(60)) == nil, "Spend percentages are not overall token quota")
    }
    static func clockAndIdentityChanges() {
        var e = QuotaActivityEstimator()
        _ = e.observe(state(10, at: 0), at: start.addingTimeInterval(10))
        require(e.observe(state(11, at: 5), at: start.addingTimeInterval(9)) == nil, "A backwards observation clock clears rate history")
        require(observe(&e, 20, at: 20) == nil, "First result after a clock jump establishes a baseline")
        require(observe(&e, 21, at: 80)?.percentPerMinute == 1, "Stable clock resumes ordinary estimation")
        require(e.observe(state(99, at: 140, name: "Different account"), at: start.addingTimeInterval(140)) == nil, "Provider identity changes do not borrow a baseline")
        var unknownReset = QuotaActivityEstimator(); _ = observe(&unknownReset, 10, at: 0, reset: nil)
        require(observe(&unknownReset, 11, at: 60, reset: nil)?.percentPerMinute == 1, "Unknown reset still permits a stable same-window observed increment")
        require(observe(&unknownReset, 20, at: 120, reset: deadline) == nil, "A newly supplied deadline rebases the comparison")
    }
    static func delayedDeliveryExpiresConservatively() {
        var e = QuotaActivityEstimator(); _ = observe(&e, 10, at: 0)
        let delayed = e.observe(state(11, at: 60), at: start.addingTimeInterval(80))!
        require(delayed.expiresAt == start.addingTimeInterval(135), "Twenty-second delivery delay leaves 55 seconds of validity")
        let almostExpired = e.observe(state(12, at: 120), at: start.addingTimeInterval(194))!
        require(almostExpired.expiresAt == start.addingTimeInterval(195), "Seventy-four-second delayed delivery leaves only one second")
        require(e.observe(state(13, at: 180), at: start.addingTimeInterval(255)) == nil, "At 75 seconds old, a snapshot cannot create an already expired estimate")
        let fresh = e.observe(state(14, at: 240), at: start.addingTimeInterval(280))!
        require(fresh.sampledFrom == start.addingTimeInterval(180) && fresh.percentPerMinute == 1,
                "Expired delivery may serve as the next stable baseline")
        require(fresh.expiresAt == start.addingTimeInterval(315), "Future estimates retain their own capture-based expiry")
    }
    static func subsecondResetJitterDoesNotRestartCycle() {
        var e = QuotaActivityEstimator()
        let firstReset = deadline.addingTimeInterval(0.295572)
        _ = observe(&e, 31, at: 0, reset: firstReset)
        let secondReset = deadline.addingTimeInterval(0.014015)
        let result = observe(&e, 36, at: 60, reset: secondReset)
        require(result?.percentPerMinute == 5,
                "Remaining 69 to 64 with real endpoint deadline jitter is five percentage points/minute")
        require(result?.sampledFrom == start,
                "Subsecond deadline drift preserves the immediately preceding successful capture")
        let fast = observe(&e, 41, at: 90, reset: deadline.addingTimeInterval(-0.350705))
        require(fast?.percentPerMinute == 10, "Comparable higher quota rate survives jitter in either direction")
        require(observe(&e, 41, at: 150, reset: firstReset) == nil,
                "An unchanged quota still stops rotation despite rounding noise")
        require(observe(&e, 42, at: 210, reset: deadline.addingTimeInterval(2)) == nil,
                "A deadline movement beyond one second conservatively establishes a new baseline")
        require(observe(&e, 43, at: 270, reset: deadline.addingTimeInterval(2.5))?.percentPerMinute == 1,
                "The next stable snapshot uses the rebased deadline")
        require(observe(&e, 3, at: 330, reset: deadline.addingTimeInterval(2.3)) == nil,
                "Quota recovery always stops the estimate, including a hidden reset with unchanged deadline")
        require(observe(&e, 4, at: 390, reset: deadline.addingTimeInterval(2.1))?.percentPerMinute == 1,
                "Consumption resumes only against the post-reset baseline")
        require(observe(&e, 5, at: 450, reset: nil) == nil,
                "Missing reset metadata cannot borrow the previous concrete cycle")
    }
    static func realDeadlineNumericFixtureAndCumulativeDrift() {
        // Numeric-only fixture: the user's remaining quota moved 69% to 64%.
        // Reset deadlines use the recorded local snapshot values; the refresh
        // interval is a representative 60 seconds, not a historical task replay.
        let captured = Date(timeIntervalSince1970: 1_791_899_061.1488892)
        let actualFirst = Date(timeIntervalSince1970: 1_791_915_000.295572)
        let actualSecond = Date(timeIntervalSince1970: 1_791_915_000.014015)
        var first = ProviderState(name: "Claude · 实时", updatedAt: captured)
        first.windows = [window(31, reset: actualFirst)]
        var second = ProviderState(name: "Claude · 实时", updatedAt: captured.addingTimeInterval(60))
        second.windows = [window(36, reset: actualSecond)]
        var fixture = QuotaActivityEstimator()
        require(fixture.observe(first, at: captured) == nil, "Actual numeric fixture starts with a baseline")
        require(fixture.observe(second, at: captured.addingTimeInterval(60))?.percentPerMinute == 5,
                "Real fractional deadlines no longer suppress the reported quota decrement")
        var drift = QuotaActivityEstimator()
        _ = observe(&drift, 10, at: 0)
        require(observe(&drift, 11, at: 60, reset: deadline.addingTimeInterval(0.4)) != nil,
                "Small deadline rounding is allowed")
        require(observe(&drift, 12, at: 120, reset: deadline.addingTimeInterval(0.8)) != nil,
                "Rounding within the fixed first-cycle deadline is allowed")
        require(observe(&drift, 13, at: 180, reset: deadline.addingTimeInterval(1.2)) == nil,
                "Repeated subsecond shifts cannot accumulate beyond the original cycle anchor")
        require(observe(&drift, 14, at: 240, reset: deadline.addingTimeInterval(1.3)) != nil,
                "A changed deadline establishes a new fixed anchor")
    }
    static func main() {
        baselineAndActualInterval(); unchangedAndRecovery(); cycleChanges(); duplicateAndOutOfOrder()
        freshnessAndDeadline(); intervalBounds(); invalidNumbers(); chooseSingleOverallWindow()
        selectionChangesAndMissingWindow(); clockAndIdentityChanges(); delayedDeliveryExpiresConservatively()
        subsecondResetJitterDoesNotRestartCycle(); realDeadlineNumericFixtureAndCumulativeDrift()
        print("PASS 13 quota activity interval, freshness, cycle, anchored deadline jitter and single-window estimation groups")
    }
}
