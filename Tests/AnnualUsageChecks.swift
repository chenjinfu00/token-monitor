import Foundation

@main
struct AnnualUsageChecks {
    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        result.firstWeekday = 2; result.minimumDaysInFirstWeek = 4
        return result
    }
    static func date(_ year: Int = 2026, _ month: Int, _ day: Int = 1, _ hour: Int = 12, calendar: Calendar = calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func near(_ value: Double?, _ expected: Double) { require(value.map { abs($0 - expected) < 0.000001 } == true, "Incorrect observed quota total") }
    static func reset(_ at: Date, before: Double = 80, after: Double = 0, provider: HistoryProvider = .codex,
                      window: String = "codex.primary", id: UUID = UUID(), previous: Date? = nil) -> HistoryResetRecord {
        HistoryResetRecord(id: id, provider: provider, windowID: window, windowName: "5小时额度",
            observedAt: at, previousObservedAt: previous ?? at.addingTimeInterval(-60),
            previousUsedPercent: before, usedPercent: after, previousResetsAt: at, resetsAt: at.addingTimeInterval(18000))
    }
    static func weeks(_ records: [HistoryResetRecord], start: Date = date(2026, 1, 1, 0), end: Date = date(2027, 1, 1, 0),
                      current: Double? = nil, at: Date? = nil) -> [HistoryAnnualUsage.Week] {
        HistoryAnnualUsage.weeks(resetHistory: records, provider: .codex, windowID: "codex.primary",
            range: DateInterval(start: start, end: end), currentUsedPercent: current, currentObservedAt: at, calendar: calendar)
    }
    static func bin(_ values: [HistoryAnnualUsage.Week], containing date: Date) -> HistoryAnnualUsage.Week {
        values.first { $0.weekStart <= date && date < $0.weekEnd }!
    }
    static func cumulativeAbove100AndUnknownWeeks() {
        let at = date(2026, 1, 6)
        let result = weeks([reset(at, before: 90), reset(date(2026, 1, 7), before: 50, after: 0.5)])
        require((52...54).contains(result.count), "Rolling year retains every intersecting calendar week")
        let first = bin(result, containing: at)
        near(first.cumulativeUsedPercent, 139.5)
        require(first.resetCount == 2 && first.observedResetCount == 2 && first.partialResetCount == 0, "Each observed recovery contributes its measured drop without repeating residual usage")
        require(result.filter { $0.id != first.id }.allSatisfy { $0.cumulativeUsedPercent == nil && $0.resetCount == 0 }, "Unobserved weeks are unknown, not zero")
    }
    static func partialReplenishmentSegments() {
        let at = date(2026, 2, 3)
        let result = bin(weeks([reset(at, before: 70, after: 20), reset(date(2026, 2, 4), before: 80)]), containing: at)
        near(result.cumulativeUsedPercent, 130)
        require(result.resetCount == 2 && result.partialResetCount == 1, "Partial quota contributes the replenished segment rather than an invented full cycle")
    }
    static func duplicateCopiesAreNotCountedTwice() {
        let original = reset(date(2026, 2, 3), before: 60)
        let migrated = reset(original.observedAt, before: 60, id: UUID())
        let result = bin(weeks([original, original, migrated]), containing: original.observedAt)
        require(result.resetCount == 1, "UUID and migrated semantic duplicates are removed")
        near(result.cumulativeUsedPercent, 60)
    }
    static func providerWindowAndMalformedValues() {
        let at = date(2026, 3, 3)
        let result = bin(weeks([reset(at, before: 40, after: 1), reset(at, provider: .claude), reset(at, window: "codex.secondary"),
            reset(at, before: .nan), reset(at, before: 101), reset(at, after: -1), reset(at, before: 0, after: 0),
            reset(at, previous: at.addingTimeInterval(1))]), containing: at)
        require(result.resetCount == 1, "Other accounts/windows, malformed values and schedule-only observations are excluded")
        near(result.cumulativeUsedPercent, 39)
    }
    static func observationWeekAndRangeEdges() {
        let boundary = date(2026, 5, 4, 0), end = date(2026, 5, 11, 0)
        let result = weeks([reset(boundary.addingTimeInterval(-1)), reset(boundary, before: 20, previous: boundary.addingTimeInterval(-60)), reset(end)], start: boundary, end: end)
        require(result.count == 2 && result[0].resetCount == 1 && result[0].weekStart == boundary && result[1].resetCount == 1, "Assign to observedAt's week and retain observations exactly at the range endpoint")
        near(result[0].cumulativeUsedPercent, 20)
        let arbitrary = weeks([], start: date(2025, 10, 13), end: date(2026, 10, 13))
        require(arbitrary.first!.weekStart <= date(2025, 10, 13) && arbitrary.last!.weekEnd >= date(2026, 10, 13), "A rolling year retains both partial edge weeks")
    }
    static func liveTailAvoidsRepeatedResetUsage() {
        let at = date(2026, 6, 2)
        near(bin(weeks([reset(at, before: 70, after: 20)], current: 20, at: at), containing: at).cumulativeUsedPercent, 70)
        near(bin(weeks([reset(at, before: 70)], current: 0, at: at), containing: at).cumulativeUsedPercent, 70)
        let noReset = bin(weeks([], current: 0, at: at), containing: at)
        near(noReset.cumulativeUsedPercent, 0)
        require(noReset.currentUsedPercent == 0 && noReset.resetCount == 0, "A fresh live zero is observed data, unlike an unobserved week")
        let stale = bin(weeks([reset(at, before: 70)], current: 60, at: at.addingTimeInterval(-1)), containing: at)
        require(stale.currentUsedPercent == nil, "A live observation predating the latest reset is not counted twice")
    }
    static func endpointResetAndResidualDoNotDoubleCount() {
        let end = date(2026, 6, 2)
        let result = bin(weeks([reset(end, before: 70, after: 0.5)], start: date(2026, 6, 1, 0), end: end,
            current: 0.5, at: end), containing: end)
        require(result.resetCount == 1 && result.currentUsedPercent == 0.5, "A reset and live observation sharing range.end are both retained")
        near(result.cumulativeUsedPercent, 70)
        let later = bin(weeks([reset(end, before: 70, after: 0.5)], current: 1.5, at: end.addingTimeInterval(60)), containing: end)
        near(later.cumulativeUsedPercent, 71)
    }
    static func localCalendarThroughDST() {
        var local = calendar; local.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let start = date(2026, 3, 23, 0, calendar: local), end = date(2026, 3, 30, 0, calendar: local)
        let result = HistoryAnnualUsage.weeks(resetHistory: [reset(end.addingTimeInterval(-1), before: 75)], provider: .codex,
            windowID: "codex.primary", range: DateInterval(start: start, end: end), calendar: local)
        require(result.count == 2 && result[0].weekStart == start && result[0].weekEnd == end && end.timeIntervalSince(start) == 7 * 86400 - 3600, "Local calendar week boundaries preserve DST")
        near(result[0].cumulativeUsedPercent, 75)
    }
    static func main() {
        cumulativeAbove100AndUnknownWeeks(); partialReplenishmentSegments(); duplicateCopiesAreNotCountedTwice()
        providerWindowAndMalformedValues(); observationWeekAndRangeEdges(); liveTailAvoidsRepeatedResetUsage(); endpointResetAndResidualDoNotDoubleCount(); localCalendarThroughDST()
        print("8 annual weekly quota-statistics checks passed")
    }
}
