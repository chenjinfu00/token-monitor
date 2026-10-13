import Foundation

/// Observed replenished quota segments plus live usage, never an exact token count.
enum HistoryAnnualUsage {
    struct Week: Equatable, Identifiable {
        let weekStart: Date
        let weekEnd: Date
        /// Observed replenished segments plus the optional live tail, in quota percentage points.
        let cumulativeUsedPercent: Double?
        let resetCount: Int
        let partialResetCount: Int
        let currentUsedPercent: Double?
        var id: Date { weekStart }
        var observedResetCount: Int { resetCount }
        var sampleCount: Int { resetCount + (currentUsedPercent == nil ? 0 : 1) }
    }

    /// Assigns replenished quota to the local calendar week in which it was observed.
    /// Every drop contributes before-after, so residual usage is counted only in the live tail.
    /// Observations at range.end are included, including a reset and live sample at that instant.
    /// Neither historical peaks nor missing weeks are manufactured into usage samples.
    /// The optional current value must be a fresh observation of this same quota window.
    static func weeks(resetHistory: [HistoryResetRecord], provider: HistoryProvider, windowID: String,
                      range: DateInterval, currentUsedPercent: Double? = nil, currentObservedAt: Date? = nil,
                      calendar: Calendar = .autoupdatingCurrent) -> [Week] {
        guard range.duration > 0, range.start.timeIntervalSince1970.isFinite,
              range.end.timeIntervalSince1970.isFinite,
              var week = calendar.dateInterval(of: .weekOfYear, for: range.start) else { return [] }
        var starts: [Date] = []
        var ends: [Date] = []
        while week.start <= range.end {
            starts.append(week.start); ends.append(week.end)
            guard let next = calendar.dateInterval(of: .weekOfYear, for: week.end), next.end > week.end else { break }
            week = next
        }
        var bins = Array(repeating: Accumulator(), count: starts.count)
        let indices = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($0.element, $0.offset) })
        var seenIDs = Set<UUID>()
        var seenEvents = Set<EventKey>()
        let ordered = resetHistory.filter {
            $0.provider == provider && $0.windowID == windowID && $0.observedAt <= range.end && valid($0)
        }.sorted {
            $0.observedAt == $1.observedAt ? $0.id.uuidString < $1.id.uuidString : $0.observedAt < $1.observedAt
        }
        var latestResetAt: Date?
        for event in ordered {
            guard seenIDs.insert(event.id).inserted, seenEvents.insert(EventKey(event)).inserted else { continue }
            latestResetAt = event.observedAt
            guard event.observedAt >= range.start,
                  let index = calendar.dateInterval(of: .weekOfYear, for: event.observedAt).flatMap({ indices[$0.start] }) else { continue }
            let partial = event.usedPercent > 1
            bins[index].sum += event.previousUsedPercent - event.usedPercent
            bins[index].count += 1
            if partial { bins[index].partial += 1 }
        }
        if let current = currentUsedPercent, current.isFinite, (0...100).contains(current),
           let observedAt = currentObservedAt, observedAt.timeIntervalSince1970.isFinite,
           observedAt >= range.start, observedAt <= range.end,
           latestResetAt.map({ observedAt >= $0 }) ?? true,
           let index = calendar.dateInterval(of: .weekOfYear, for: observedAt).flatMap({ indices[$0.start] }) {
            bins[index].current = current
            bins[index].sum += current
        }
        return starts.indices.map { index in
            let bin = bins[index]
            return Week(weekStart: starts[index], weekEnd: ends[index],
                cumulativeUsedPercent: bin.count > 0 || bin.current != nil ? bin.sum : nil,
                resetCount: bin.count, partialResetCount: bin.partial, currentUsedPercent: bin.current)
        }
    }

    private struct Accumulator {
        var sum = 0.0
        var count = 0
        var partial = 0
        var current: Double?
    }

    private static func valid(_ event: HistoryResetRecord) -> Bool {
        event.schemaVersion == 1 && event.observedAt.timeIntervalSince1970.isFinite &&
        event.previousObservedAt.timeIntervalSince1970.isFinite && event.previousObservedAt <= event.observedAt &&
        event.previousUsedPercent.isFinite && event.usedPercent.isFinite &&
        (0...100).contains(event.previousUsedPercent) && (0...100).contains(event.usedPercent) &&
        event.previousUsedPercent > event.usedPercent &&
        [event.previousResetsAt, event.resetsAt].compactMap { $0 }.allSatisfy { $0.timeIntervalSince1970.isFinite }
    }

    /// UUID retries and migrated copies can refer to the same observation. Match semantic
    /// identity at the archive's millisecond precision, independently of display name.
    private struct EventKey: Hashable {
        let observed: Double
        let previousObserved: Double
        let before: Double
        let after: Double
        let previousDeadline: Double?
        let deadline: Double?
        init(_ event: HistoryResetRecord) {
            func stamp(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
            observed = stamp(event.observedAt); previousObserved = stamp(event.previousObservedAt)
            before = event.previousUsedPercent; after = event.usedPercent
            previousDeadline = event.previousResetsAt.map(stamp); deadline = event.resetsAt.map(stamp)
        }
    }
}
