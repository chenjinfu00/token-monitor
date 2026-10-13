import Foundation

// Substitute empty local probes for this executable: no account files, task
// transcripts, subprocesses or network calls are involved in store integration.
enum ProviderBrand { case codex, claude }
final class CodexActivityProbe {
    func reset() {}
    func read(at now: Date) -> ProviderActivityReading { ProviderActivityReading() }
}
final class ClaudeActivityProbe {
    func reset() {}
    func read(at now: Date) -> ProviderActivityReading { ProviderActivityReading() }
}

@main
@MainActor
struct QuotaActivityStoreChecks {
    static let start = Date()
    static let deadline = start.addingTimeInterval(18_000)
    static func snapshot(_ used: Double?, at seconds: TimeInterval) -> ProviderState {
        var state = ProviderState(name: "Claude · 实时", updatedAt: start.addingTimeInterval(seconds))
        state.windows = [QuotaWindow(id: "five_hour", name: "five_hour", usedPercent: used,
            resetsAt: deadline, durationSeconds: 18_000)]
        return state
    }
    static func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    static func lease(_ store: ProviderActivityStore) -> [String: Any]? {
        store.diagnosticSnapshot()["claudeQuotaEstimate"] as? [String: Any]
    }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }

    static func automaticExpiryWithoutFurtherRefresh() {
        let store = ProviderActivityStore(); store.start(); defer { store.stop() }
        let now = Date()
        let resetAt = now.addingTimeInterval(18_000)
        func captured(_ used: Double, at timestamp: Date) -> ProviderState {
            var state = ProviderState(name: "Claude · 实时", updatedAt: timestamp)
            state.windows = [QuotaWindow(id: "five_hour", name: "five_hour", usedPercent: used,
                resetsAt: resetAt, durationSeconds: 18_000)]
            return state
        }
        let baselineAt = now.addingTimeInterval(-359)
        let positiveAt = now.addingTimeInterval(-299)
        store.observeClaudeQuota(captured(10, at: baselineAt), at: baselineAt)
        store.observeClaudeQuota(captured(11, at: positiveAt), at: now)
        require(store.claude.rotationDuration != nil, "A delayed but still valid positive capture starts inferred motion")
        require(lease(store)!["expiresAt"] as! TimeInterval == now.addingTimeInterval(1).timeIntervalSince1970,
            "Actual capture-based expiry leaves approximately one second")
        require(store.diagnosticSnapshot()["claudeQuotaExpiryTimerScheduled"] as? Bool == true,
            "Automatic expiry uses the production one-shot timer")
        // No quota refresh or retention call follows: only the real main run loop
        // delivers the expiry callback and its MainActor publication.
        let timeout = Date().addingTimeInterval(2)
        while lease(store) != nil && Date() < timeout {
            RunLoop.main.run(until: min(Date().addingTimeInterval(0.05), timeout))
        }
        require(lease(store) == nil && store.claude.rotationDuration == nil,
            "Without any further refresh, the expiry timer automatically stops inferred motion")
        require(store.diagnosticSnapshot()["claudeQuotaExpiryTimerScheduled"] as? Bool == false,
            "The automatic expiry callback clears its timer as well as its lease")
    }

    static func main() {
        let previousDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(["claudeActivityDisabled": false], forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousDomain, forName: UserDefaults.argumentDomain) }
        let store = ProviderActivityStore(); store.start(); defer { store.stop() }
        store.observeClaudeQuota(snapshot(10, at: 0), at: time(0))
        require(store.claude.rotationDuration == nil, "First confirmed snapshot is a baseline")
        store.observeClaudeQuota(snapshot(11, at: 60), at: time(60))
        let expiry = lease(store)!["expiresAt"] as! TimeInterval
        let firstSpeed = store.claude.rotationDuration!
        require(expiry == time(360).timeIntervalSince1970, "Real consumption sets a five-minute fixed deadline")
        store.retainClaudeQuotaInference(at: time(120))
        store.retainClaudeQuotaInference(at: time(180))
        require(store.claude.rotationDuration == firstSpeed && lease(store)!["expiresAt"] as! TimeInterval == expiry,
            "Repeated unconfirmed refreshes preserve confirmed animation without extending its timer")
        for error: ClaudeUsageError in [.unconfirmed, .timedOut, .unavailable, .rateLimited] {
            store.observeClaudeQuotaFailure(error, at: time(180))
            require(store.claude.rotationDuration == firstSpeed && lease(store)!["expiresAt"] as! TimeInterval == expiry,
                "Transient failures never erase or renew the confirmed lease")
            require(store.diagnosticSnapshot()["claudeQuotaExpiryTimerScheduled"] as? Bool == true,
                "Transient failure preserves the existing expiry timer")
        }
        store.observeClaudeQuota(snapshot(99, at: 60), at: time(180))
        require(lease(store)!["expiresAt"] as! TimeInterval == expiry, "Repeated capture cannot renew or replace the lease")
        store.observeClaudeQuota(snapshot(11, at: 240), at: time(240))
        require(store.claude.rotationDuration == firstSpeed && lease(store)!["expiresAt"] as! TimeInterval == expiry,
            "Unchanged confirmed quota keeps rotating at the last measured speed")
        store.observeClaudeQuota(snapshot(14, at: 300), at: time(300))
        require(store.claude.quotaPercentPerMinute == 3 && store.claude.rotationDuration! < firstSpeed,
            "Next genuine consumption updates speed through the production store")
        require(lease(store)!["expiresAt"] as! TimeInterval == time(600).timeIntervalSince1970, "Positive delta alone renews the lease")
        store.observeClaudeQuotaFailure(.timedOut, at: time(600))
        require(store.claude.rotationDuration == nil && lease(store) == nil, "Even transient failures cannot sustain motion after the original deadline")
        require(store.diagnosticSnapshot()["claudeQuotaExpiryTimerScheduled"] as? Bool == false, "Expired failure retention removes its timer")
        store.observeClaudeQuota(snapshot(15, at: 660), at: time(660))
        require(store.claude.rotationDuration == nil, "A confirmation gap over five minutes rebases rather than inventing speed")
        store.observeClaudeQuota(snapshot(16, at: 720), at: time(720))
        require(store.claude.rotationDuration != nil, "Fresh confirmed consumption resumes after rebasing")
        store.observeLocalActivity(ProviderActivityPair(claude: ProviderActivityState(lastTaskEventAt: time(721))))
        require(store.claude.rotationDuration == nil && lease(store) == nil, "Confirmed real Stop retires the lease immediately")
        // A query may finish after Stop even though its capture predates Stop.
        // Its timestamp is newer than the last accepted quota, so deduplication
        // alone cannot prevent it from rebuilding a pre-Stop comparison.
        store.observeClaudeQuota(snapshot(16, at: 720.5), at: time(722))
        require(store.claude.rotationDuration == nil && lease(store) == nil,
            "A late pre-Stop capture cannot establish a post-Stop quota baseline")
        store.observeLocalActivity(ProviderActivityPair())
        store.retainClaudeQuotaInference(at: time(722))
        require(store.claude.rotationDuration == nil, "Missing Stop snapshot cannot revive retired motion")
        store.observeClaudeQuota(snapshot(17, at: 780), at: time(780))
        require(store.claude.rotationDuration == nil, "Even after the Stop snapshot disappears, the first post-Stop quota only establishes a baseline")
        store.observeClaudeQuota(snapshot(18, at: 840), at: time(840))
        require(store.claude.rotationDuration != nil, "Independent later consumption can resume normally")
        store.observeLocalActivity(ProviderActivityPair(claude: ProviderActivityState(lastTaskEventAt: time(841), isPaused: true)))
        require(store.claude.rotationDuration == nil && lease(store) == nil, "Permission wait immediately clears retained activity")
        store.observeClaudeQuota(snapshot(19, at: 900), at: time(900))
        store.observeClaudeQuota(snapshot(20, at: 960), at: time(960))
        require(store.claude.rotationDuration == nil && lease(store) == nil, "A paused task cannot establish a delayed lease")
        store.observeLocalActivity(ProviderActivityPair())
        store.observeClaudeQuota(snapshot(21, at: 1020), at: time(1020))
        require(store.claude.rotationDuration == nil, "After permission wait clears, fresh baseline is required")
        store.observeClaudeQuota(snapshot(22, at: 1080), at: time(1080))
        require(store.claude.rotationDuration != nil, "New post-wait consumption restarts motion")
        store.observeClaudeQuota(snapshot(1, at: 1140), at: time(1140))
        require(store.claude.rotationDuration == nil && lease(store) == nil, "Percentage recovery stops a lease immediately")
        store.observeClaudeQuota(snapshot(2, at: 1200), at: time(1200))
        require(store.claude.rotationDuration != nil, "Later same-cycle consumption resumes")
        store.resetClaudeQuota()
        require(store.claude.rotationDuration == nil && lease(store) == nil, "Source/sleep reset removes timer, lease and baseline")
        store.observeClaudeQuota(snapshot(3, at: 1260), at: time(1260))
        require(store.claude.rotationDuration == nil, "First confirmation after source change remains a baseline")
        store.observeClaudeQuota(snapshot(4, at: 1320), at: time(1320))
        require(store.claude.rotationDuration != nil, "Second fresh confirmation can resume normally")
        store.observeLocalActivity(ProviderActivityPair(claude: ProviderActivityState(isPaused: true)))
        require(store.claude.rotationDuration == nil && lease(store) == nil, "A pause without an event timestamp permanently retires the lease")
        store.observeLocalActivity(ProviderActivityPair())
        store.retainClaudeQuotaInference(at: time(1321))
        require(store.claude.rotationDuration == nil, "Dropping incomplete pause metadata cannot revive an old estimate")
        store.observeClaudeQuota(snapshot(5, at: 1380), at: time(1380))
        require(store.claude.rotationDuration == nil, "First confirmation after an incomplete pause rebases")
        store.observeClaudeQuota(snapshot(6, at: 1440), at: time(1440))
        require(store.claude.rotationDuration != nil, "Independent post-pause consumption can rotate")
        UserDefaults.standard.setVolatileDomain(["claudeActivityDisabled": true], forName: UserDefaults.argumentDomain)
        store.retainClaudeQuotaInference(at: time(1441))
        require(store.claude.rotationDuration == nil && lease(store) == nil, "User disabling collection stops and permanently clears retained motion")
        UserDefaults.standard.setVolatileDomain(["claudeActivityDisabled": false], forName: UserDefaults.argumentDomain)
        store.retainClaudeQuotaInference(at: time(1442))
        require(store.claude.rotationDuration == nil, "Re-enabling collection cannot reuse a pre-disable lease")
        store.observeClaudeQuota(snapshot(7, at: 1500), at: time(1500))
        require(store.claude.rotationDuration == nil, "First confirmed quota after re-enabling is a new baseline")
        store.observeClaudeQuota(snapshot(8, at: 1560), at: time(1560))
        require(store.claude.rotationDuration != nil, "Fresh post-disable consumption resumes normally")
        for (offset, error): (Int, ClaudeUsageError) in [.executableMissing, .invalidResponse].enumerated() {
            store.observeClaudeQuotaFailure(error)
            require(store.claude.rotationDuration == nil && lease(store) == nil, "A nontransient failure clears activity immediately")
            require(store.diagnosticSnapshot()["claudeQuotaExpiryTimerScheduled"] as? Bool == false, "A nontransient failure cancels the old timer")
            let baselineAt = TimeInterval(1620 + offset * 120)
            store.observeClaudeQuota(snapshot(Double(9 + offset * 2), at: baselineAt), at: time(baselineAt))
            require(store.claude.rotationDuration == nil, "First success after a nontransient failure cannot bridge the old comparison")
            store.observeClaudeQuota(snapshot(Double(10 + offset * 2), at: baselineAt + 60), at: time(baselineAt + 60))
            require(store.claude.rotationDuration != nil, "Two new confirmed captures can resume normal inference")
        }
        store.stop()
        require(store.claude.rotationDuration == nil && lease(store) == nil, "Stopping activity monitor cancels inferred rotation")
        automaticExpiryWithoutFurtherRefresh()
        print("PASS offline production store: transient/unchanged retention, automatic timer expiry, late Stop capture, speed renewal and reset")
    }
}
