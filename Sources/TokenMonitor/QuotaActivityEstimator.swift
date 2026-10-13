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
    private var previous: Sample?
    private var acceptedAt: Date?
    private var lastObservedAt: Date?
    private var lastPositive: QuotaActivityEstimate?
    static let idleTimeout: TimeInterval = 300

    mutating func reset() {
        previous = nil; acceptedAt = nil; lastObservedAt = nil; lastPositive = nil
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
            previous = nil; lastPositive = nil
            return nil
        }
        guard acceptedAt.map({ capturedAt > $0 }) ?? true else { return activeEstimate(at: now) }
        acceptedAt = capturedAt
        guard let window = Self.selectedWindow(in: state, at: now) else {
            previous = nil; lastPositive = nil
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
            return nil
        }
        let seconds = capturedAt.timeIntervalSince(old.at)
        let delta = used - oldUsed
        guard delta >= 0 else {
            // A hidden reset or quota recovery invalidates recent consumption immediately.
            lastPositive = nil
            return nil
        }
        // Integer percentages can stay unchanged while a real task is working.
        // Keep its last observed speed, without extending the last-positive deadline.
        guard delta > 0 else { return activeEstimate(at: now) }
        guard seconds >= 5, seconds <= Self.idleTimeout else {
            lastPositive = nil
            return nil
        }
        let rate = delta * 60 / seconds
        // A delayed delivery expires from the actual confirmed capture, not receipt.
        // Known resets also bound the lease, even if the next query fails to arrive.
        let expiresAt = min(capturedAt.addingTimeInterval(Self.idleTimeout), window.resetsAt ?? .distantFuture)
        guard rate.isFinite, rate > 0, expiresAt > now else {
            lastPositive = nil
            return nil
        }
        let estimate = QuotaActivityEstimate(percentPerMinute: rate, sampledFrom: old.at, expiresAt: expiresAt)
        lastPositive = estimate
        return estimate
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
