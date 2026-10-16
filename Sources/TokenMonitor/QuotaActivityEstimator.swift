import Foundation

// This is quota percentage per minute, never a claimed token count. A new
// confirmed snapshot can only be compared with one stable overall quota window.
struct QuotaActivityEstimate: Equatable {
    let percentPerMinute: Double
    let sampledFrom: Date
    let expiresAt: Date
}

struct QuotaActivityEstimator {
    private struct Sample {
        let provider: String
        let window: QuotaWindow
        let at: Date
        let resetAnchor: Date?
    }
    private struct Point { let at: Date; let used: Double }
    private var previous: Sample?
    // Confirmed captures of the current comparable cycle, oldest first, at most one
    // lease period old. Integer percentages need a longer span at low consumption.
    private var recent: [Point] = []
    private var acceptedAt: Date?
    private var lastObservedAt: Date?
    private var lastPositive: QuotaActivityEstimate?
    static let idleTimeout: TimeInterval = 300
    // A speed is measured over the shortest recent span that grew by this many
    // percentage points, otherwise over the whole five minutes: a single integer
    // step then no longer reads as a full point per query interval.
    static let minimumPoints: Double = 3

    mutating func reset() {
        previous = nil; recent = []; acceptedAt = nil; lastObservedAt = nil; lastPositive = nil
    }

    private mutating func activeEstimate(at now: Date) -> QuotaActivityEstimate? {
        if lastPositive.map({ $0.expiresAt <= now }) ?? false { lastPositive = nil }
        return lastPositive
    }

    mutating func observe(_ state: ProviderState, at now: Date = Date()) -> QuotaActivityEstimate? {
        guard now.timeIntervalSince1970.isFinite else { reset(); return nil }
        if lastObservedAt.map({ now < $0 }) ?? false {
            reset(); lastObservedAt = now
            return nil
        }
        lastObservedAt = now
        // Loading/replayed deliveries never claim new consumption or renew a lease.
        guard !state.isLoading else { return activeEstimate(at: now) }
        guard let capturedAt = state.updatedAt, capturedAt.timeIntervalSince1970.isFinite,
              capturedAt <= now, now.timeIntervalSince(capturedAt) <= Self.idleTimeout else {
            previous = nil; recent = []; lastPositive = nil
            return nil
        }
        guard acceptedAt.map({ capturedAt > $0 }) ?? true else { return activeEstimate(at: now) }
        acceptedAt = capturedAt
        guard let window = Self.selectedWindow(in: state, at: now) else {
            previous = nil; recent = []; lastPositive = nil
            return nil
        }
        let old = previous
        let sameCycle = old.map { old in
            old.provider == state.name && old.window.id == window.id &&
                Self.sameResetDeadline(old.resetAnchor, window.resetsAt) &&
                old.window.cycleStartedAt == window.cycleStartedAt &&
                old.window.durationSeconds == window.durationSeconds
        } ?? false
        let sample = Sample(provider: state.name, window: window, at: capturedAt,
                            resetAnchor: sameCycle ? old?.resetAnchor : window.resetsAt)
        previous = sample
        guard sameCycle, let old,
              let oldUsed = old.window.usedPercent, let used = window.usedPercent else {
            lastPositive = nil
            recent = window.usedPercent.map { [Point(at: capturedAt, used: $0)] } ?? []
            return nil
        }
        let seconds = capturedAt.timeIntervalSince(old.at)
        let delta = used - oldUsed
        guard delta >= 0 else {
            // A hidden reset or quota recovery invalidates recent consumption immediately.
            lastPositive = nil
            recent = [Point(at: capturedAt, used: used)]
            return nil
        }
        // Integer percentages can stay unchanged while a real task is working.
        // Keep its last observed speed, without extending the last-positive deadline.
        guard delta > 0 else {
            remember(Point(at: capturedAt, used: used))
            return activeEstimate(at: now)
        }
        guard seconds >= 5, seconds <= Self.idleTimeout else {
            lastPositive = nil
            recent = [Point(at: capturedAt, used: used)]
            return nil
        }
        remember(Point(at: capturedAt, used: used))
        let baseline = Self.baseline(in: recent)
        let rate = (used - baseline.used) * 60 / capturedAt.timeIntervalSince(baseline.at)
        // A delayed delivery expires from the actual confirmed capture, not receipt.
        // Known resets also bound the lease, even if the next query fails to arrive.
        let expiresAt = min(capturedAt.addingTimeInterval(Self.idleTimeout), window.resetsAt ?? .distantFuture)
        guard rate.isFinite, rate > 0, expiresAt > now else {
            lastPositive = nil
            return nil
        }
        let estimate = QuotaActivityEstimate(percentPerMinute: rate, sampledFrom: baseline.at, expiresAt: expiresAt)
        lastPositive = estimate
        return estimate
    }

    private mutating func remember(_ point: Point) {
        recent.append(point)
        recent.removeAll { $0.at < point.at.addingTimeInterval(-Self.idleTimeout) }
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
    }

    // The newest earlier capture at least minimumPoints lower, else the oldest
    // one in the five-minute span. The previous capture is always in the span.
    private static func baseline(in points: [Point]) -> Point {
        guard let latest = points.last else { preconditionFailure("A positive delta has two captures") }
        for point in points.dropLast().reversed() where latest.used - point.used >= minimumPoints {
            return point
        }
        return points.count > 1 ? points[0] : latest
    }

    private static func sameResetDeadline(_ old: Date?, _ new: Date?) -> Bool {
        switch (old, new) {
        case (nil, nil): return true
        case let (old?, new?):
            // Claude's quota endpoint reconstructs the same reset deadline with
            // subsecond jitter on each query. Preserve its full display precision,
            // but do not mistake that rounding noise for a new quota cycle.
            // Compare against a fixed cycle anchor so drift cannot accumulate.
            return abs(old.timeIntervalSince(new)) <= 1
        default: return false
        }
    }

    private static func selectedWindow(in state: ProviderState, at now: Date) -> QuotaWindow? {
        let overall: [QuotaWindow]
        if state.windows.contains(where: { ["five_hour", "seven_day"].contains($0.id) }) {
            overall = state.windows.filter { ["five_hour", "seven_day"].contains($0.id) }
        } else if state.windows.contains(where: { $0.id.hasPrefix("codex.") }) {
            overall = state.windows.filter { $0.id.hasPrefix("codex.") }
        } else {
            // Unknown providers may still report an overall primary/secondary
            // window. Spend/model-specific buckets are not usable substitutes.
            overall = state.windows.filter { $0.id.hasSuffix(".primary") || $0.id.hasSuffix(".secondary") }
        }
        let counts = Dictionary(grouping: overall, by: \.id).mapValues(\.count)
        let valid = overall.filter { window in
            guard counts[window.id] == 1, let used = window.usedPercent, used.isFinite, (0...100).contains(used),
                  window.resetsAt.map({ $0.timeIntervalSince1970.isFinite && $0 > now }) ?? true,
                  window.durationSeconds.map({ $0.isFinite && $0 > 0 }) ?? true,
                  window.cycleStartedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= now }) ?? true else { return false }
            return true
        }
        return valid.min { left, right in
            if (left.id == "five_hour") != (right.id == "five_hour") { return left.id == "five_hour" }
            let leftSpan = left.durationSeconds ?? .infinity
            let rightSpan = right.durationSeconds ?? .infinity
            if leftSpan != rightSpan { return leftSpan < rightSpan }
            return left.id < right.id
        }
    }
}

// Quota-based activity for one provider: confirmed quota captures combined with that
// provider's local task lifecycle. Platform-neutral; the store adds timers and UI.
struct QuotaInference {
    private var estimator = QuotaActivityEstimator()
    private(set) var estimate: QuotaActivityEstimate?
    private(set) var lastQuotaAt: Date?
    private(set) var lastInterruptionAt: Date?

    // A confirmed capture. Returns false when it was ignored and nothing changed.
    mutating func observe(_ state: ProviderState, local: ProviderActivityState, at now: Date) -> Bool {
        guard let timestamp = state.updatedAt else { reset(); return true }
        // Replayed snapshots neither stop current activity nor extend its deadline.
        guard timestamp > (lastQuotaAt ?? .distantPast) else { return false }
        guard timestamp <= now.addingTimeInterval(2) else { reset(); return true }
        // A query captured before Stop/pause may arrive afterwards. It cannot
        // establish a baseline for activity that would span that interruption.
        guard timestamp > (lastInterruptionAt ?? .distantPast) else { return false }
        lastQuotaAt = timestamp
        guard !local.isPaused else { clear(); return true }
        estimate = estimator.observe(state, at: now)
        return true
    }

    // Local lifecycle evidence. Returns true when a real Stop or pause retired the estimate.
    mutating func observeLocal(_ local: ProviderActivityState) -> Bool {
        if local.isPaused {
            if let interruptedAt = local.lastTaskEventAt {
                lastInterruptionAt = max(interruptedAt, lastInterruptionAt ?? .distantPast)
            }
            // Permission waits retire the lease even if event metadata is incomplete.
            clear()
            return true
        }
        if local.runningTaskCount == 0, let interruptedAt = local.lastTaskEventAt,
           interruptedAt > (lastInterruptionAt ?? .distantPast) {
            lastInterruptionAt = interruptedAt
            // Losing the subsequent Stop snapshot cannot revive the retired lease.
            clear()
            return true
        }
        return false
    }

    // Drops an estimate whose lease has run out. Returns true when one was dropped.
    mutating func expire(at now: Date) -> Bool {
        guard let estimate, estimate.expiresAt <= now else { return false }
        self.estimate = nil
        return true
    }

    // The expiry timer for this exact lease fired.
    mutating func endLease(expiringAt expected: Date) -> Bool {
        guard estimate?.expiresAt == expected else { return false }
        estimate = nil
        return true
    }

    mutating func clear() { estimator.reset(); estimate = nil }
    mutating func forgetCaptures() { clear(); lastQuotaAt = nil }
    mutating func reset() { clear(); lastQuotaAt = nil; lastInterruptionAt = nil }

    func merged(into local: ProviderActivityState, at now: Date) -> ProviderActivityState {
        guard let estimate, estimate.expiresAt > now,
              estimate.sampledFrom > (lastInterruptionAt ?? .distantPast) else { return local }
        return local.mergingQuotaEstimate(percentPerMinute: estimate.percentPerMinute, sampledFrom: estimate.sampledFrom)
    }
}
