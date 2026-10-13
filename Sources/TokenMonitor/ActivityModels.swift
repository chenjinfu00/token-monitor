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
}

struct ProviderActivityState: Equatable {
    var runningTaskCount: Int = 0
    var tokensPerSecond: Double? = nil
    var statusNote: String? = nil

    var rotationDuration: TimeInterval? {
        guard runningTaskCount > 0 else { return nil }
        guard let rate = tokensPerSecond, rate.isFinite, rate > 0 else { return 12 }
        // A measured recent rate determines speed, with a readable upper limit.
        // Quantizing duration avoids replacing a render-server animation for tiny changes.
        return (max(2, min(12, 12 / (1 + sqrt(rate / 25)))) * 2).rounded() / 2
    }

    var helpText: String {
        guard runningTaskCount > 0 else { return statusNote ?? "空闲" }
        let tasks = runningTaskCount > 1 ? "\(runningTaskCount) 个任务正在运行" : "正在运行"
        guard let rate = tokensPerSecond, rate.isFinite, rate > 0 else {
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
            return ProviderActivityState(statusNote: reading.statusNote)
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
        return ProviderActivityState(runningTaskCount: reading.runningSessionIDs.count, tokensPerSecond: rate)
    }

    mutating func reset() { samples.removeAll(keepingCapacity: false) }
}
