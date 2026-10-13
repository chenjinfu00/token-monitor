import Foundation

/// Predicts the next local change of the visible collapsed summary; never refreshes a service.
enum EdgeCountdownRefresh {
    private static let epsilon: TimeInterval = 0.001

    static func nextUpdate(providers: [ProviderState], after now: Date) -> Date? {
        guard now.timeIntervalSince1970.isFinite else { return nil }
        var earliest: Date?
        for provider in providers {
            let summary = EdgeQuotaSummary(provider: provider, at: now)
            let current = VisibleState(summary)
            var candidates: [Date] = []
            if let window = summary.window, let reset = window.resetsAt,
               reset.timeIntervalSince1970.isFinite, reset > now {
                if let boundary = countdownBoundary(reset: reset, after: now) { candidates.append(boundary) }
                if let boundary = paceBoundary(window: window, after: now) { candidates.append(boundary) }
            }
            // An expiry can change which quota is the most restrictive. Ignore expiries that
            // leave every displayed value unchanged, including non-overall service windows.
            for window in provider.windows {
                if let reset = window.resetsAt, reset.timeIntervalSince1970.isFinite, reset > now {
                    candidates.append(reset.addingTimeInterval(epsilon))
                }
            }
            for candidate in candidates where candidate > now && candidate.timeIntervalSince1970.isFinite {
                guard VisibleState(EdgeQuotaSummary(provider: provider, at: candidate)) != current else { continue }
                earliest = min(earliest ?? candidate, candidate)
            }
        }
        return earliest
    }

    private static func countdownBoundary(reset: Date, after now: Date) -> Date? {
        let remaining = reset.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0 else { return nil }
        let threshold: TimeInterval
        if remaining < 60 {
            let seconds = floor(remaining)
            // Both 1.x seconds and 0.x seconds show 1s until the real deadline.
            threshold = seconds >= 2 ? seconds : 0
        } else if remaining < 3600 {
            threshold = floor(remaining / 60) * 60
        } else if remaining >= 86400 {
            let days = remaining / 86400
            // Day summaries have one decimal place. Crossing one day switches to hours.
            threshold = max(86400, ((days * 10).rounded() - 0.5) / 10 * 86400)
        } else {
            let hours = remaining / 3600
            let nextHours: Double
            if hours > 10 {
                // Integer-hour rounding changes at x.5, then switches to decimals at 10h.
                nextHours = max(10, hours.rounded() - 0.5)
            } else {
                nextHours = max(1, ((hours * 10).rounded() - 0.5) / 10)
            }
            // A 1.0h display switches to minutes at 1h, before its next decimal step.
            threshold = nextHours * 3600
        }
        return max(now.addingTimeInterval(epsilon), reset.addingTimeInterval(-threshold + epsilon))
    }

    private static func paceBoundary(window: QuotaWindow, after now: Date) -> Date? {
        guard let reset = window.resetsAt, reset > now,
              let duration = window.durationSeconds, duration.isFinite, duration > 0,
              let quota = window.remainingPercent else { return nil }
        let start = window.cycleStartedAt ?? reset.addingTimeInterval(-duration)
        let span = reset.timeIntervalSince(start)
        guard start.timeIntervalSince1970.isFinite, span.isFinite, span > 0 else { return nil }
        if start > now { return start.addingTimeInterval(epsilon) }
        let timePercent: Double
        switch window.paceLevel(at: now) {
        case .behind: timePercent = quota + 15
        case .balanced: timePercent = quota - 5
        case .ahead, .unknown: return nil
        }
        guard timePercent > 0, timePercent <= 100 else { return nil }
        let crossing = reset.addingTimeInterval(-span * timePercent / 100 + epsilon)
        return max(now.addingTimeInterval(epsilon), crossing)
    }

    private struct VisibleState: Equatable {
        let windowID: String?
        let percentage: String
        let days: String?
        let time: String
        let pace: QuotaPace
        init(_ summary: EdgeQuotaSummary) {
            windowID = summary.window?.id
            percentage = summary.percentText
            days = summary.daysText
            time = summary.window?.resetsAt == nil ? "待定" : summary.hourComponentText
            pace = summary.pace
        }
    }
}
