import Foundation

// Only lifecycle identifiers, timestamps and token numbers cross the probe boundary.
// Session content is never retained or written to the monitor's history.
struct ActivityTokenDelta: Equatable {
    let sessionID: String
    let at: Date
    let tokens: Int
}

struct ProviderActivityReading {
    var runningSessionIDs: Set<String> = []
    var tokenDeltas: [ActivityTokenDelta] = []
    var watchedFiles: [URL] = []
    var watchedDirectories: [URL] = []
    var statusNote: String? = nil
    var lastTaskEventAt: Date? = nil
    var isPaused = false
}

struct ProviderActivityState: Equatable {
    var runningTaskCount: Int = 0
    var tokensPerSecond: Double? = nil
    var statusNote: String? = nil
    var lastTaskEventAt: Date? = nil
    var isPaused = false
    var quotaPercentPerMinute: Double? = nil
    var isInferredFromQuota = false

    // A completed/paused real task takes precedence over delayed quota delivery.
    func mergingQuotaEstimate(percentPerMinute: Double, sampledFrom: Date) -> ProviderActivityState {
        guard percentPerMinute.isFinite, percentPerMinute > 0 else { return self }
        var result = self
        if runningTaskCount == 0 {
            guard !isPaused, (lastTaskEventAt ?? .distantPast) < sampledFrom else { return self }
            result.runningTaskCount = 1
            result.isInferredFromQuota = true
            result.statusNote = nil
        }
        if tokensPerSecond == nil { result.quotaPercentPerMinute = percentPerMinute }
        return result
    }

    var rotationDuration: TimeInterval? {
        guard runningTaskCount > 0 else { return nil }
        let scaledRate: Double
        if let rate = tokensPerSecond, rate.isFinite, rate > 0 { scaledRate = rate / 25 }
        else if let rate = quotaPercentPerMinute, rate.isFinite, rate > 0 { scaledRate = rate / 0.5 }
        else { return 12 }
        // Separate units: token/s from task events, percentage points/minute from quota.
        return (max(2, min(12, 12 / (1 + sqrt(scaledRate)))) * 2).rounded() / 2
    }

    var helpText: String {
        guard runningTaskCount > 0 else { return statusNote ?? "空闲" }
        let tasks = runningTaskCount > 1 ? "\(runningTaskCount) 个任务正在运行" : "正在运行"
        guard let rate = tokensPerSecond, rate.isFinite, rate > 0 else {
            if let quotaRate = quotaPercentPerMinute, quotaRate.isFinite, quotaRate > 0 {
                let value = String(format: "%.2f", quotaRate)
                return (isInferredFromQuota ? "近期额度消耗估计" : tasks) + " · 约 " + value + "%/分"
            }
            return tasks + " · 等待用量计数"
        }
        let value = rate >= 10 ? String(format: "%.0f", rate) : String(format: "%.1f", rate)
        return tasks + " · 近期约 " + value + " token/s"
    }
}

struct ProviderActivityPair: Equatable {
    var codex = ProviderActivityState()
    var claude = ProviderActivityState()
}

struct ProviderActivityEstimator {
    let windowSeconds: TimeInterval
    private var samples: [ActivityTokenDelta] = []

    init(windowSeconds: TimeInterval = 30) {
        self.windowSeconds = max(1, windowSeconds)
    }

    mutating func update(_ reading: ProviderActivityReading, at now: Date) -> ProviderActivityState {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        guard !reading.runningSessionIDs.isEmpty else {
            samples.removeAll(keepingCapacity: true)
            return ProviderActivityState(statusNote: reading.statusNote, lastTaskEventAt: reading.lastTaskEventAt, isPaused: reading.isPaused)
        }
        samples.removeAll { $0.at <= cutoff || $0.at > now.addingTimeInterval(2) }
        for delta in reading.tokenDeltas where delta.tokens > 0 && delta.tokens <= 1_000_000_000
            && delta.at > cutoff && delta.at <= now.addingTimeInterval(2) {
            if !samples.contains(delta) { samples.append(delta) }
        }
        // Bounded memory even if a source emits pathological numbers of updates.
        if samples.count > 1024 { samples.removeFirst(samples.count - 1024) }
        let total = samples.reduce(0.0) { $0 + Double($1.tokens) }
        let rate = total > 0 ? (total / windowSeconds * 10).rounded() / 10 : nil
        return ProviderActivityState(runningTaskCount: reading.runningSessionIDs.count, tokensPerSecond: rate, lastTaskEventAt: reading.lastTaskEventAt, isPaused: reading.isPaused)
    }

    mutating func reset() { samples.removeAll(keepingCapacity: false) }
}
