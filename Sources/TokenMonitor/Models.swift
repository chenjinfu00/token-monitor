import Foundation
import Combine
import CoreFoundation

enum QuotaPace: String {
    case ahead, balanced, behind, unknown
}

struct QuotaWindow: Identifiable, Equatable {
    let id: String
    let name: String
    let usedPercent: Double?
    let resetsAt: Date?
    let durationSeconds: TimeInterval?
    let cycleStartedAt: Date?

    init(id: String, name: String, usedPercent: Double?, resetsAt: Date?, durationSeconds: TimeInterval? = nil, cycleStartedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationSeconds = durationSeconds
        self.cycleStartedAt = cycleStartedAt
    }

    var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    func isExpired(at now: Date = Date()) -> Bool {
        resetsAt.map { $0 <= now } ?? false
    }

    func timeRemainingPercent(at now: Date = Date()) -> Double? {
        guard let reset = resetsAt, reset > now,
              let duration = durationSeconds, duration.isFinite, duration > 0 else { return nil }
        let start = cycleStartedAt ?? reset.addingTimeInterval(-duration)
        let span = reset.timeIntervalSince(start)
        guard span.isFinite, span > 0, now >= start else { return nil }
        return max(0, min(100, reset.timeIntervalSince(now) / span * 100))
    }

    // Both bars show what remains. A negative gap means quota is being used faster than time passes.
    func paceDifference(at now: Date = Date()) -> Double? {
        guard let quota = remainingPercent, let time = timeRemainingPercent(at: now) else { return nil }
        return quota - time
    }

    func paceLevel(at now: Date = Date()) -> QuotaPace {
        guard !isExpired(at: now), let gap = paceDifference(at: now), gap.isFinite else { return .unknown }
        if gap > 5 { return .ahead }
        if gap <= -15 { return .behind }
        return .balanced
    }

    func paceText(at now: Date = Date()) -> String {
        guard !isExpired(at: now) else { return "等待新的额度窗口" }
        guard let gap = paceDifference(at: now) else { return "周期或额度未知，暂不比较" }
        let points = Int(abs(gap).rounded())
        if gap < -3 { return "使用偏快 · 超前 \(points) 个百分点" }
        if gap > 3 { return "余量充足 · 低于均匀用量 \(points) 个百分点" }
        return "接近均匀节奏"
    }

    func countdown(at now: Date = Date()) -> String {
        guard let reset = resetsAt else { return "重置时间未知" }
        let seconds = Int(ceil(reset.timeIntervalSince(now)))
        guard seconds > 0 else { return "窗口已结束 · 等待更新" }
        let minutes = max(1, (seconds + 59) / 60)
        if minutes >= 1440 { return "\(minutes / 1440)天 \((minutes % 1440) / 60)小时后重置" }
        if minutes >= 60 { return "\(minutes / 60)小时 \(minutes % 60)分钟后重置" }
        return "\(minutes)分钟后重置"
    }
}

enum WidgetDateFormatter {
    static var timeZoneLabel: String { TimeZone.autoupdatingCurrent.identifier }

    private static func formatted(_ date: Date, format: String, timeZone: TimeZone) -> String {
        let value = DateFormatter()
        value.locale = Locale(identifier: "zh_CN")
        value.timeZone = timeZone
        value.dateFormat = format
        return value.string(from: date)
    }

    static func reset(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        formatted(date, format: "MM/dd HH:mm", timeZone: timeZone)
    }
    static func shortReset(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        reset(date, timeZone: timeZone)
    }
    static func resetDay(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        formatted(date, format: "MM/dd", timeZone: timeZone)
    }
    static func resetTime(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        formatted(date, format: "HH:mm", timeZone: timeZone)
    }
}

struct ProviderState: Equatable {
    let name: String
    var windows: [QuotaWindow] = []
    var updatedAt: Date? = nil
    var message: String? = nil
    var isLoading: Bool = false
    var resetCreditCount: Int? = nil

    func ageText(at now: Date = Date()) -> String {
        guard let timestamp = updatedAt else { return "尚未同步" }
        let seconds = max(0, Int(now.timeIntervalSince(timestamp)))
        let verb = name.hasPrefix("Claude Code") ? "收到" : "同步"
        if seconds < 60 { return "\(seconds)秒前\(verb)" }
        if seconds < 3600 { return "\(seconds / 60)分钟前\(verb)" }
        if seconds < 86400 { return "\(seconds / 3600)小时前\(verb)" }
        return "\(seconds / 86400)天前\(verb)"
    }
}

struct EdgeQuotaSummary {
    let window: QuotaWindow?
    let remainingPercent: Double?
    let hoursText: String
    let daysText: String?
    let hourComponentText: String
    let percentText: String
    let pace: QuotaPace

    init(provider: ProviderState, at now: Date) {
        // Summarize the most restrictive overall quota. Never combine one
        // window's percentage with another window's earlier reset deadline.
        let overall: [QuotaWindow]
        if provider.name.hasPrefix("Codex") {
            overall = provider.windows.filter { $0.id.hasPrefix("codex.") }
        } else {
            overall = provider.windows.filter { ["five_hour", "seven_day"].contains($0.id) }
        }
        let candidates = overall.isEmpty ? provider.windows : overall
        let active = candidates.filter { !$0.isExpired(at: now) }
        let withQuota = active.filter { $0.remainingPercent != nil }
        let selected = withQuota.min {
            if $0.remainingPercent != $1.remainingPercent { return $0.remainingPercent! < $1.remainingPercent! }
            return ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture)
        } ?? active.min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) } ?? candidates.first
        window = selected
        let expired = selected?.isExpired(at: now) ?? true
        remainingPercent = expired ? nil : selected?.remainingPercent
        percentText = remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        if !expired, let reset = selected?.resetsAt {
            let hours = reset.timeIntervalSince(now) / 3600
            if hours.isFinite, hours > 0 {
                // Keep the smallest positive display unit until the real
                // deadline; an ended window remains unknown until updated.
                hoursText = String(format: "%.1fh", locale: Locale(identifier: "en_US_POSIX"), max(0.1, hours))
                var days = floor(hours / 24)
                let rawRemainder = hours.truncatingRemainder(dividingBy: 24)
                let wholeHours = rawRemainder > 10
                var remainder = wholeHours ? rawRemainder.rounded() : (rawRemainder * 10).rounded() / 10
                // Carry rounded 24h into the day line rather than showing
                // an extra full day among the remaining hours.
                if days >= 1, remainder >= 24 { days += 1; remainder = 0 }
                daysText = days >= 1 ? String(format: "%.0fd", locale: Locale(identifier: "en_US_POSIX"), days) : nil
                hourComponentText = String(format: wholeHours ? "%.0fh" : "%.1fh", locale: Locale(identifier: "en_US_POSIX"), days >= 1 ? remainder : max(0.1, remainder))
            } else {
                hoursText = "—"
                daysText = nil
                hourComponentText = "—"
            }
        } else {
            hoursText = "—"
            daysText = nil
            hourComponentText = "—"
        }
        pace = expired ? .unknown : (selected?.paceLevel(at: now) ?? .unknown)
    }
}

struct CodexAccountSnapshot {
    let windows: [QuotaWindow]
    let resetCreditCount: Int?
}

struct QuotaCycleTracker {
    private var previous: [String: QuotaWindow] = [:]
    private var anchors: [String: (deadline: Date, start: Date)] = [:]

    mutating func update(_ incoming: [QuotaWindow], at now: Date) -> (windows: [QuotaWindow], recovered: Bool) {
        var recovered = false
        let windows = incoming.map { window -> QuotaWindow in
            let old = previous[window.id]
            if let anchor = anchors[window.id], anchor.deadline != window.resetsAt { anchors.removeValue(forKey: window.id) }
            if let old, !old.isExpired(at: now), let oldUsed = old.usedPercent,
               let newUsed = window.usedPercent, oldUsed - newUsed >= 5, let reset = window.resetsAt, reset > now {
                recovered = true
                // The service can replenish quota without moving its deadline. Anchor only an observed near-full recovery.
                if newUsed <= 1, old.resetsAt == reset { anchors[window.id] = (reset, now) }
            }
            return QuotaWindow(id: window.id, name: window.name, usedPercent: window.usedPercent,
                resetsAt: window.resetsAt, durationSeconds: window.durationSeconds, cycleStartedAt: anchors[window.id]?.start)
        }
        previous = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        anchors = anchors.filter { previous[$0.key] != nil }
        return (windows, recovered)
    }
}

enum QuotaParser {
    static func number(_ value: Any?) -> Double? {
        guard let value = value, !(value is NSNull), CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let result = (value as? NSNumber)?.doubleValue, result.isFinite else { return nil }
        return result
    }

    static func codex(_ result: [String: Any]) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let entries: [(String, [String: Any])]
        if let buckets, !buckets.isEmpty {
            entries = buckets.sorted { a, b in
                if a.key == b.key { return false }
                if a.key == "codex" { return true }
                if b.key == "codex" { return false }
                return a.key < b.key
            }.map { ($0.key, $0.value) }
        } else if let bucket = result["rateLimits"] as? [String: Any] {
            entries = [(bucket["limitId"] as? String ?? "codex", bucket)]
        } else { return [] }
        for (bucketID, bucket) in entries {
            for key in ["primary", "secondary"] {
                guard let window = bucket[key] as? [String: Any] else { continue }
                let duration = number(window["windowDurationMins"]).flatMap { $0 > 0 && $0 <= 525600 ? $0 : nil }
                let label: String
                if let duration {
                    if duration == 10080 { label = "每周额度" }
                    else if duration >= 1440 { label = "\(Int(duration / 1440))天额度" }
                    else if duration >= 60 && duration.truncatingRemainder(dividingBy: 60) == 0 { label = "\(Int(duration / 60))小时额度" }
                    else { label = "\(Int(duration))分钟额度" }
                } else { label = key == "primary" ? "当前额度" : "长期额度" }
                let prefix = entries.count > 1 && bucketID != "codex" ? (bucket["limitName"] as? String ?? bucketID) + " · " : ""
                windows.append(QuotaWindow(id: "\(bucketID).\(key)", name: prefix + label,
                    usedPercent: number(window["usedPercent"]), resetsAt: number(window["resetsAt"]).map(Date.init(timeIntervalSince1970:)),
                    durationSeconds: duration.map { $0 * 60 }))
            }
        }
        return windows
    }

    static func codexSnapshot(_ result: [String: Any]) -> CodexAccountSnapshot {
        let resetCredits = result["rateLimitResetCredits"] as? [String: Any]
        let count = number(resetCredits?["availableCount"]).flatMap { value -> Int? in
            guard value >= 0, value < Double(Int.max), value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        return CodexAccountSnapshot(windows: codex(result), resetCreditCount: count)
    }

    static func claude(_ snapshot: [String: Any]) -> ProviderState {
        var state = ProviderState(name: "Claude Code")
        state.updatedAt = number(snapshot["capturedAt"]).map(Date.init(timeIntervalSince1970:))
        let limits = snapshot["rateLimits"] as? [String: [String: Any]] ?? [:]
        for (key, name) in [("five_hour", "5小时额度"), ("seven_day", "每周额度"), ("spend_limit", "支出额度")] {
            guard let window = limits[key] else { continue }
            state.windows.append(QuotaWindow(id: key, name: name,
                usedPercent: number(window["used_percentage"]), resetsAt: number(window["resets_at"]).map(Date.init(timeIntervalSince1970:)),
                durationSeconds: key == "five_hour" ? 18000 : (key == "seven_day" ? 604800 : nil)))
        }
        if state.windows.isEmpty { state.message = "等待 Claude Code 回复后同步订阅额度" }
        else if snapshot["conservative"] as? Bool == true { state.message = "已保留同一窗口较高使用量 · 等待后续回复确认" }
        return state
    }
}
