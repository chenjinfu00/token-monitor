import Foundation

/// A linear quota budget, independent of the measured usage curve.
struct QuotaPacingGuide: Identifiable, Equatable {
    enum Source: String {
        case official, codexResetForecast
        var label: String { self == .official ? "官方周期" : "网站提前重置预测" }
    }
    enum Anchor: String { case liveCycleStart, officialWindowDuration, observedReset }
    struct Point: Identifiable, Equatable {
        let date: Date
        let usedPercent: Double
        var id: Date { date }
    }

    let provider: HistoryProvider
    let windowID: String
    let source: Source
    let anchor: Anchor
    let startAt: Date
    let targetAt: Date
    var id: String { [provider.rawValue, windowID, source.rawValue, String(startAt.timeIntervalSince1970), String(targetAt.timeIntervalSince1970)].joined(separator: "|") }
    var sourceURL: URL? { source == .codexResetForecast ? URL(string: "https://codex-resets.com/zh-CN") : nil }

    private init(provider: HistoryProvider, windowID: String, source: Source, anchor: Anchor,
                 startAt: Date, targetAt: Date) {
        self.provider = provider; self.windowID = windowID; self.source = source
        self.anchor = anchor; self.startAt = startAt; self.targetAt = targetAt
    }

    static func make(provider: HistoryProvider, window: QuotaWindow,
                     resetHistory: [HistoryResetRecord] = [], reference: WebsiteResetReference? = nil,
                     at now: Date = Date()) -> [QuotaPacingGuide] {
        guard finite(now), let deadline = window.resetsAt, finite(deadline), deadline > now else { return [] }
        let start: Date
        let anchor: Anchor
        if let explicit = window.cycleStartedAt, usable(explicit, deadline: deadline, now: now) {
            start = explicit; anchor = .liveCycleStart
        } else if let duration = window.durationSeconds, duration.isFinite, duration > 0 {
            let nominal = deadline.addingTimeInterval(-duration)
            guard usable(nominal, deadline: deadline, now: now) else { return [] }
            let recovered = resetHistory.filter { row in
                matching(row, provider: provider, windowID: window.id, deadline: deadline, now: now) &&
                row.usedPercent <= 1 && row.observedAt > nominal &&
                row.previousResetsAt.map { finite($0) && abs($0.timeIntervalSince(deadline)) <= 1 } == true
            }.max { $0.observedAt < $1.observedAt }
            if let recovered {
                // A persisted near-full recovery survives loss of the live in-memory anchor on restart.
                start = recovered.observedAt; anchor = .observedReset
            } else { start = nominal; anchor = .officialWindowDuration }
        } else {
            // Only a matching provider/window and the current deadline identify this cycle.
            // The observation is a known anchor, not a claim about the exact execution instant.
            let latest = resetHistory.filter {
                matching($0, provider: provider, windowID: window.id, deadline: deadline, now: now)
            }.max { $0.observedAt < $1.observedAt }
            guard let observed = latest else { return [] }
            start = observed.observedAt; anchor = .observedReset
        }
        let official = QuotaPacingGuide(provider: provider, windowID: window.id, source: .official,
            anchor: anchor, startAt: start, targetAt: deadline)
        guard provider == .codex, let reference, reference.targetKind == .deadline,
              finite(reference.startAt), reference.startAt <= now,
              finite(reference.referenceAt), reference.referenceAt > reference.startAt,
              reference.referenceAt > now, reference.referenceAt > start, reference.referenceAt < deadline,
              finite(reference.windowEndAt), reference.windowEndAt > now else { return [official] }
        return [official, QuotaPacingGuide(provider: provider, windowID: window.id,
            source: .codexResetForecast, anchor: anchor, startAt: start, targetAt: reference.referenceAt)]
    }

    /// Percentages outside the cycle clamp to its endpoints, never below 0% or above 100%.
    func percent(at date: Date) -> Double {
        guard Self.finite(date) else { return 0 }
        return max(0, min(100, date.timeIntervalSince(startAt) / targetAt.timeIntervalSince(startAt) * 100))
    }

    /// Draw only the portion of the real cycle intersecting the visible chart range.
    func clippedPoints(in range: DateInterval) -> [Point] {
        guard Self.finite(range.start), Self.finite(range.end) else { return [] }
        let lower = max(startAt, range.start)
        let upper = min(targetAt, range.end)
        guard upper > lower else { return [] }
        return [Point(date: lower, usedPercent: percent(at: lower)), Point(date: upper, usedPercent: percent(at: upper))]
    }

    private static func matching(_ row: HistoryResetRecord, provider: HistoryProvider, windowID: String,
                                 deadline: Date, now: Date) -> Bool {
        row.provider == provider && row.windowID == windowID && row.schemaVersion == 1 &&
        row.previousUsedPercent.isFinite && row.usedPercent.isFinite &&
        (0...100).contains(row.previousUsedPercent) && (0...100).contains(row.usedPercent) &&
        row.previousUsedPercent > row.usedPercent && finite(row.previousObservedAt) &&
        row.previousObservedAt < row.observedAt && usable(row.observedAt, deadline: deadline, now: now) &&
        row.resetsAt.map { finite($0) && abs($0.timeIntervalSince(deadline)) <= 1 } == true
    }

    private static func finite(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }
    private static func usable(_ start: Date, deadline: Date, now: Date) -> Bool {
        let span = deadline.timeIntervalSince(start)
        return finite(start) && start <= now && span.isFinite && span > 0
    }
}
