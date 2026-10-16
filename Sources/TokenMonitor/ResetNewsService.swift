import Foundation

struct WebsiteResetReference: Equatable {
    enum TargetKind: String { case center, deadline, forecastWindow }
    enum Confidence: String {
        case unknown, low, medium, high, announced
        var label: String {
            switch self {
            case .unknown: return "置信度待定"
            case .low: return "较低置信度"
            case .medium: return "中等置信度"
            case .high: return "较高置信度"
            case .announced: return "已公告"
            }
        }
    }
    let startAt: Date
    let referenceAt: Date
    let windowStartAt: Date
    let windowEndAt: Date
    let targetKind: TargetKind
    var confidencePercent: Double? = nil

    var confidence: Confidence {
        if targetKind == .deadline { return .announced }
        guard let value = confidencePercent, value.isFinite,
              (0...100).contains(value), value.rounded() == value else { return .unknown }
        return value >= 70 ? .high : value >= 40 ? .medium : .low
    }

    var confidenceDescription: String {
        if confidence == .announced { return "网站公告 · 执行待确认" }
        guard confidence != .unknown, let value = confidencePercent else { return "网站未提供置信度" }
        return "网站估计概率：\(Int(value))% · " + confidence.label
    }

    func remainingPercent(at now: Date) -> Double {
        max(0, min(100, referenceAt.timeIntervalSince(now) / referenceAt.timeIntervalSince(startAt) * 100))
    }

    func description(at now: Date) -> String {
        guard now < referenceAt else { return "网站目标已到 · 等待确认" }
        let minutes = max(1, Int(ceil(referenceAt.timeIntervalSince(now) / 60)))
        let time: String
        if minutes >= 1440 { time = "\(minutes / 1440)天 \((minutes % 1440) / 60)小时" }
        else if minutes >= 60 { time = "\(minutes / 60)小时 \(minutes % 60)分钟" }
        else { time = "\(minutes)分钟" }
        let label = targetKind == .forecastWindow ? "网站预测窗口：" : "网站目标："
        return label + "\(time)后 · 账户恢复待确认"
    }
}

struct ResetNewsState {
    var headline: String? = nil
    var detail: String? = nil
    var sourceURL: URL? = URL(string: "https://codex-resets.com/zh-CN")
    var updatedAt: Date? = nil
    var isLoading: Bool = false
    var message: String? = "正在读取公共重置信息…"
    var expiresAt: Date? = nil
    var sourceIsStale: Bool = false
    var reference: WebsiteResetReference? = nil

    func freshnessWarning(at now: Date) -> String? {
        guard sourceIsStale || expiresAt.map({ $0 <= now }) == true else { return nil }
        return "网站快照已过期 · 公共消息仅供参考"
    }

    func canShowReference(at now: Date) -> Bool {
        guard let reference, now >= reference.startAt, now < reference.referenceAt,
              now < reference.windowEndAt, freshnessWarning(at: now) == nil else { return false }
        return message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}

enum ResetNewsParser {
    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: string) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    // Validate provenance without opening a source URL or displaying remote text.
    private static func validSource(_ event: [String: Any], allowObserved: Bool) -> Bool {
        guard let source = event["source"] as? [String: Any] else { return false }
        if allowObserved, source["type"] as? String == "observed" { return true }
        guard source["type"] as? String == "x_post", source["author"] as? String == "thsottiaux",
              let rawURL = source["url"] as? String, let url = URL(string: rawURL),
              url.scheme == "https", ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil,
              url.pathComponents.count == 4, url.path.hasPrefix("/thsottiaux/status/") else { return false }
        if let id = event["id"] as? String { return url.lastPathComponent == id }
        return !url.lastPathComponent.isEmpty
    }

    private static func eventDate(_ event: [String: Any]?, at now: Date, allowObserved: Bool = true) -> Date? {
        guard let event, let id = event["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ["regular", "banked"].contains(event["reset_type"] as? String ?? ""),
              let timestamp = date(event["announced_at"]), timestamp <= now,
              validSource(event, allowObserved: allowObserved) else { return nil }
        return timestamp
    }

    static func prediction(_ data: [String: Any]?, at now: Date) -> WebsiteResetReference? {
        if let scheduled = scheduledPrediction(data, at: now) { return scheduled }
        guard let watch = data?["active_watch"] as? [String: Any],
              ["elevated", "strong"].contains(watch["level"] as? String ?? ""),
              validSource(watch, allowObserved: true),
              let observedAt = date(watch["observed_at"]), observedAt <= now,
              let expiresAt = date(watch["expires_at"]), expiresAt > now,
              let span = forecastSpan(watch["forecast_window"]),
              expiresAt > observedAt,
              expiresAt.timeIntervalSince(observedAt) <= span + 3600 else { return nil }
        if let latest = data?["latest_reset"] as? [String: Any], latest["reset_type"] as? String == "regular",
           let resetAt = eventDate(latest, at: now), resetAt >= observedAt { return nil }
        // The site's banner uses expires_at as the end of a numeric "within"
        // forecast (rounded to an hour). It is a prediction window, never an
        // announced execution time. An expiry without that window is insufficient.
        let chance = QuotaParser.number(watch["reset_chance_percent"]).flatMap { value -> Double? in
            value.isFinite && (0...100).contains(value) && value.rounded() == value ? value : nil
        }
        return WebsiteResetReference(startAt: observedAt, referenceAt: expiresAt,
            windowStartAt: observedAt, windowEndAt: expiresAt, targetKind: .forecastWindow,
            confidencePercent: chance)
    }

    private static func forecastSpan(_ value: Any?) -> TimeInterval? {
        guard let text = value as? String, text.utf8.count <= 80,
              let expression = try? NSRegularExpression(pattern: #"^within\s+([0-9]+(?:\.[0-9]+)?)\s*(m|mins?|minutes?|h|hrs?|hours?|d|days?)$"#, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let amountRange = Range(match.range(at: 1), in: text), let amount = Double(text[amountRange]),
              let unitRange = Range(match.range(at: 2), in: text) else { return nil }
        let unit = text[unitRange].lowercased()
        let seconds = amount * (unit.hasPrefix("d") ? 86400 : unit.hasPrefix("h") ? 3600 : 60)
        return seconds.isFinite && seconds > 0 && seconds < 366 * 86400 ? seconds : nil
    }

    private static func scheduledPrediction(_ data: [String: Any]?, at now: Date) -> WebsiteResetReference? {
        // An explicit announcement remains preferable to a speculative watch.
        guard let scheduled = data?["scheduled_reset"] as? [String: Any],
              scheduled["status"] as? String == "scheduled", scheduled["reset_type"] as? String == "regular",
              let announcedAt = eventDate(scheduled, at: now, allowObserved: false),
              let target = date(scheduled["scheduled_for"]), target > now, target > announcedAt,
              target.timeIntervalSince(announcedAt) < 366 * 86400 else { return nil }
        if let latest = data?["latest_reset"] as? [String: Any], latest["reset_type"] as? String == "regular",
           let resetAt = eventDate(latest, at: now), resetAt > announcedAt { return nil }
        return WebsiteResetReference(startAt: announcedAt, referenceAt: target,
            windowStartAt: target, windowEndAt: target, targetKind: .deadline)
    }

    static func parse(status: [String: Any], at now: Date, expiresAt: Date? = nil,
                      sourceIsStale: Bool = false) throws -> ResetNewsState {
        guard let data = status["data"] as? [String: Any], let meta = status["meta"] as? [String: Any],
              meta["api_version"] as? String == "v1", let generatedAt = date(meta["generated_at"]),
              generatedAt <= now.addingTimeInterval(300), data["stats"] is [String: Any],
              ["latest_reset", "scheduled_reset", "active_watch"].allSatisfy({
                  data[$0] is NSNull || data[$0] is [String: Any]
              }) else { throw ResetNewsError.unavailable }
        var state = ResetNewsState()
        state.updatedAt = generatedAt
        state.expiresAt = expiresAt
        state.sourceIsStale = sourceIsStale
        state.message = nil
        var details: [String] = []
        let latest = data["latest_reset"] as? [String: Any]
        if let timestamp = eventDate(latest, at: now), let latest {
            let title: String
            if latest["reset_type"] as? String == "banked" {
                title = "网站记录备用重置额度发放"
                details.append("备用重置额度需要手动使用；发放不会立即恢复本账户用量。")
            } else if (latest["source"] as? [String: Any])?["type"] as? String == "observed" {
                title = "网站观察到全局重置"
            } else { title = "网站记录全局重置" }
            state.headline = title + " · " + WidgetDateFormatter.reset(timestamp)
        } else { state.headline = "尚无可核验的公共重置记录" }

        if state.freshnessWarning(at: now) == nil { state.reference = prediction(data, at: now) }
        if let scheduled = data["scheduled_reset"] as? [String: Any],
           scheduled["status"] as? String == "scheduled", eventDate(scheduled, at: now, allowObserved: false) != nil {
            if scheduled["reset_type"] as? String == "banked" {
                details.append("网站记录备用重置额度发放公告；需要手动使用。")
            } else if let target = date(scheduled["scheduled_for"]) {
                if target > now {
                    details.append("网站公告目标：" + WidgetDateFormatter.reset(target) + " · 执行待确认")
                } else { details.append("网站公告目标已到 · 尚未确认执行") }
            } else { details.append("网站有重置公告，但未给出明确时间。") }
        }

        if let watch = data["active_watch"] as? [String: Any],
           ["elevated", "strong"].contains(watch["level"] as? String ?? ""),
           let observedAt = date(watch["observed_at"]), observedAt <= now,
           let watchExpiry = date(watch["expires_at"]), watchExpiry > now,
           validSource(watch, allowObserved: true) {
            if let chance = QuotaParser.number(watch["reset_chance_percent"]),
               chance >= 0, chance <= 100, chance.rounded() == chance {
                details.append("网站估计概率：\(Int(chance))% · 不代表确定重置时间")
            } else { details.append("网站有重置预测信号 · 尚无明确重置时间") }
        }
        if state.reference == nil { details.append("网站未提供当前可用的明确重置时间，额外时间条已隐藏。") }
        state.detail = details.joined(separator: "\n")
        return state
    }
}

enum ResetNewsError: Error {
    case unavailable
    case throttled(TimeInterval)
}

enum ResetNewsService {
    private static let client = Client()

    static func retryDelay(_ header: String?, at now: Date) -> TimeInterval {
        let value = header?.trimmingCharacters(in: .whitespacesAndNewlines)
        var delay = value.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        if delay == nil, let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            delay = formatter.date(from: value)?.timeIntervalSince(now)
        }
        return max(60, min(delay ?? 300, 86400))
    }

    static func cacheLifetime(_ header: String?, age: String?) -> TimeInterval {
        let fields = header?.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        if fields.contains("no-store") || fields.contains("no-cache") { return 0 }
        let maxAge = fields.first(where: { $0.hasPrefix("max-age=") }).flatMap { Double($0.dropFirst(8).replacingOccurrences(of: "\"", with: "")) }
        let elapsed = age.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0
        let lifetime = maxAge.flatMap { $0.isFinite ? $0 : nil } ?? 60
        return max(0, min(86400, lifetime) - elapsed)
    }

    static func isOlderSnapshot(_ incoming: [String: Any], than cached: [String: Any]) -> Bool {
        guard let incomingTime = ResetNewsParser.date((incoming["meta"] as? [String: Any])?["generated_at"]),
              let cachedTime = ResetNewsParser.date((cached["meta"] as? [String: Any])?["generated_at"]) else { return false }
        return incomingTime < cachedTime
    }

    static func read() async throws -> ResetNewsState { try await client.read() }

    private actor Client {
        private var cachedBody: [String: Any]?
        private var etag: String?
        private var cacheControl: String?
        private var cachedExpiry: Date?
        private var cachedIsStale = false

        // Public GET only: no account credentials, cookies or quota data are sent.
        // Revalidate every minute with ETag even within max-age for fresh announcements.
        func read() async throws -> ResetNewsState {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 15
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            var request = URLRequest(url: URL(string: "https://codex-resets.com/api/v1/status")!, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("TokenMonitor/0.7.0 (personal macOS desktop widget)", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            let (bodyData, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ResetNewsError.unavailable }
            let now = Date()
            if response.statusCode == 429 {
                throw ResetNewsError.throttled(ResetNewsService.retryDelay(response.value(forHTTPHeaderField: "Retry-After"), at: now))
            }
            let body: [String: Any]
            if response.statusCode == 304, let cachedBody { body = cachedBody }
            else {
                guard response.statusCode == 200, bodyData.count < 1_048_576,
                      let parsed = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else { throw ResetNewsError.unavailable }
                body = parsed
            }
            let policy = response.value(forHTTPHeaderField: "Cache-Control") ?? cacheControl
            let expiry = now.addingTimeInterval(ResetNewsService.cacheLifetime(policy, age: response.value(forHTTPHeaderField: "Age")))
            let stale = response.value(forHTTPHeaderField: "Warning")?.split(separator: ",").contains(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("110") || $0.trimmingCharacters(in: .whitespaces).hasPrefix("111")
            }) ?? false
            let state = try ResetNewsParser.parse(status: body, at: now, expiresAt: expiry, sourceIsStale: stale)
            // Different CDN nodes can return older entities. Do not replace a
            // newer announcement or extend its age using a regressed response.
            if response.statusCode == 200, let cachedBody,
               ResetNewsService.isOlderSnapshot(body, than: cachedBody) {
                return try ResetNewsParser.parse(status: cachedBody, at: now,
                    expiresAt: cachedExpiry, sourceIsStale: cachedIsStale)
            }
            if policy?.lowercased().contains("no-store") == true {
                cachedBody = nil; etag = nil; cacheControl = nil; cachedExpiry = nil
            } else {
                cachedBody = body
                etag = response.value(forHTTPHeaderField: "ETag") ?? (response.statusCode == 304 ? etag : nil)
                cacheControl = policy
                cachedExpiry = expiry
                cachedIsStale = stale
            }
            return state
        }
    }
}
