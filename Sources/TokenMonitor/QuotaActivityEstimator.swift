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
    }
    private var previous: Sample?
    private var acceptedAt: Date?
    private var lastObservedAt: Date?

    mutating func reset() { previous = nil; acceptedAt = nil; lastObservedAt = nil }

    mutating func observe(_ state: ProviderState, at now: Date = Date()) -> QuotaActivityEstimate? {
        guard now.timeIntervalSince1970.isFinite else { return nil }
        if lastObservedAt.map({ now < $0 }) ?? false {
            reset(); lastObservedAt = now
            return nil
        }
        lastObservedAt = now
        guard !state.isLoading,
              let capturedAt = state.updatedAt, capturedAt.timeIntervalSince1970.isFinite,
              capturedAt <= now, now.timeIntervalSince(capturedAt) <= 300,
              acceptedAt.map({ capturedAt > $0 }) ?? true else { return nil }
        acceptedAt = capturedAt
        guard let window = Self.selectedWindow(in: state, at: now) else {
            previous = nil
            return nil
        }
        let sample = Sample(provider: state.name, window: window, at: capturedAt)
        let old = previous
        previous = sample
        guard let old, old.provider == sample.provider, old.window.id == window.id,
              old.window.resetsAt == window.resetsAt,
              old.window.cycleStartedAt == window.cycleStartedAt,
              old.window.durationSeconds == window.durationSeconds,
              let oldUsed = old.window.usedPercent, let used = window.usedPercent else { return nil }
        let seconds = capturedAt.timeIntervalSince(old.at)
        let delta = used - oldUsed
        guard seconds >= 5, seconds <= 180, delta > 0 else { return nil }
        let rate = delta * 60 / seconds
        // Valid but delayed snapshots still rebase the comparison above. They
        // cannot turn historical consumption into another full minute of motion.
        let expiresAt = min(now.addingTimeInterval(75), capturedAt.addingTimeInterval(75))
        guard rate.isFinite, rate > 0, expiresAt > now else { return nil }
        return QuotaActivityEstimate(percentPerMinute: rate, sampledFrom: old.at, expiresAt: expiresAt)
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
