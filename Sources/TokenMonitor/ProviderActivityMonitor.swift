import Foundation
import AppKit
import Combine
import Darwin

@MainActor
final class ProviderActivityStore: ObservableObject {
    @Published private(set) var codex = ProviderActivityState()
    @Published private(set) var claude = ProviderActivityState()
    private let worker = ProviderActivityWorker()
    private var isStarted = false
    private var isSleeping = false
    private var generation = 0
    private var notifications: [NSObjectProtocol] = []
    private var clockObserver: NSObjectProtocol?
    private var localCodex = ProviderActivityState()
    private var localClaude = ProviderActivityState()
    private var claudeQuotaEstimator = QuotaActivityEstimator()
    private var claudeQuotaEstimate: QuotaActivityEstimate?
    private var lastClaudeQuotaAt: Date?
    private var lastClaudeInterruptionAt: Date?
    private var quotaExpiryTimer: Timer?

    func observeClaudeQuota(_ state: ProviderState, at now: Date = Date()) {
        guard isStarted, !isSleeping else { return }
        guard !UserDefaults.standard.bool(forKey: "claudeActivityDisabled") else {
            resetClaudeQuota()
            return
        }
        guard let timestamp = state.updatedAt else { resetClaudeQuota(); return }
        // Replayed snapshots neither stop current activity nor extend its deadline.
        guard timestamp > (lastClaudeQuotaAt ?? .distantPast) else { return }
        guard timestamp <= now.addingTimeInterval(2) else { resetClaudeQuota(); return }
        // A query captured before Stop/pause may arrive afterwards. It cannot
        // establish a baseline for activity that would span that interruption.
        guard timestamp > (lastClaudeInterruptionAt ?? .distantPast) else { return }
        lastClaudeQuotaAt = timestamp
        guard !localClaude.isPaused else {
            clearClaudeQuotaInference()
            publish(at: now)
            return
        }
        claudeQuotaEstimate = claudeQuotaEstimator.observe(state, at: now)
        quotaExpiryTimer?.invalidate()
        quotaExpiryTimer = nil
        if let estimate = claudeQuotaEstimate {
            let expected = estimate.expiresAt
            let timer = Timer(timeInterval: max(0.01, expected.timeIntervalSince(now)), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.claudeQuotaEstimate?.expiresAt == expected else { return }
                    self.claudeQuotaEstimate = nil
                    self.quotaExpiryTimer = nil
                    self.publish()
                }
            }
            timer.tolerance = 0.25
            quotaExpiryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        publish(at: now)
    }

    func observeClaudeQuotaFailure(_ error: ClaudeUsageError, at now: Date = Date()) {
        switch error {
        case .unconfirmed, .timedOut, .unavailable, .rateLimited:
            // A transient failure has no new numbers or lifecycle evidence.
            // Let the last genuine consumption deadline expire on its own.
            retainClaudeQuotaInference(at: now)
        case .executableMissing, .invalidResponse:
            resetClaudeQuota()
        }
    }

    func retainClaudeQuotaInference(at now: Date = Date()) {
        // An unconfirmed query carries no new evidence. Keep only the existing
        // confirmed lease and its original timer; do not change the baseline.
        if claudeQuotaEstimate.map({ $0.expiresAt <= now }) ?? false {
            claudeQuotaEstimate = nil
            quotaExpiryTimer?.invalidate()
            quotaExpiryTimer = nil
        }
        publish(at: now)
    }

    private func clearClaudeQuotaInference() {
        claudeQuotaEstimator.reset()
        claudeQuotaEstimate = nil
        quotaExpiryTimer?.invalidate()
        quotaExpiryTimer = nil
    }

    func resetClaudeQuota() {
        clearClaudeQuotaInference()
        lastClaudeQuotaAt = nil
        lastClaudeInterruptionAt = nil
        publish()
    }

    func observeLocalActivity(_ pair: ProviderActivityPair) {
        localCodex = pair.codex
        localClaude = pair.claude
        if localClaude.isPaused {
            if let interruptedAt = localClaude.lastTaskEventAt {
                lastClaudeInterruptionAt = max(interruptedAt, lastClaudeInterruptionAt ?? .distantPast)
            }
            // Permission waits retire the lease even if event metadata is incomplete.
            clearClaudeQuotaInference()
        } else if localClaude.runningTaskCount == 0,
                  let interruptedAt = localClaude.lastTaskEventAt,
                  interruptedAt > (lastClaudeInterruptionAt ?? .distantPast) {
            lastClaudeInterruptionAt = interruptedAt
            // Losing the subsequent Stop snapshot cannot revive the retired lease.
            clearClaudeQuotaInference()
        }
        publish()
    }

    private func publish(at now: Date = Date()) {
        var nextClaude = localClaude
        if UserDefaults.standard.bool(forKey: "claudeActivityDisabled") {
            clearClaudeQuotaInference()
            lastClaudeQuotaAt = nil
            nextClaude = ProviderActivityState(statusNote: "Claude 活动采集已停用")
        } else if let estimate = claudeQuotaEstimate, estimate.expiresAt > now,
                  estimate.sampledFrom > (lastClaudeInterruptionAt ?? .distantPast) {
            nextClaude = localClaude.mergingQuotaEstimate(percentPerMinute: estimate.percentPerMinute, sampledFrom: estimate.sampledFrom)
        }
        if codex != localCodex { codex = localCodex }
        if claude != nextClaude { claude = nextClaude }
    }

    func diagnosticSnapshot() -> [String: Any] {
        func stateSnapshot(_ state: ProviderActivityState) -> [String: Any] {
            ["runningTaskCount": state.runningTaskCount,
             "tokensPerSecond": state.tokensPerSecond as Any? ?? NSNull(),
             "quotaPercentPerMinute": state.quotaPercentPerMinute as Any? ?? NSNull(),
             "rotationDuration": state.rotationDuration as Any? ?? NSNull(),
             "isInferredFromQuota": state.isInferredFromQuota,
             "isPaused": state.isPaused,
             "lastTaskEventAt": state.lastTaskEventAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()]
        }
        let estimate: Any = claudeQuotaEstimate.map {
            ["percentPerMinute": $0.percentPerMinute, "sampledFrom": $0.sampledFrom.timeIntervalSince1970,
             "expiresAt": $0.expiresAt.timeIntervalSince1970] as [String: Any]
        } ?? NSNull()
        return ["started": isStarted, "sleeping": isSleeping,
                "claudeActivityDisabled": UserDefaults.standard.bool(forKey: "claudeActivityDisabled"),
                "codex": stateSnapshot(codex), "claude": stateSnapshot(claude),
                "claudeLocal": stateSnapshot(localClaude), "claudeQuotaEstimate": estimate,
                "claudeQuotaExpiryTimerScheduled": quotaExpiryTimer?.isValid ?? false,
                "lastClaudeQuotaAt": lastClaudeQuotaAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()]
    }

    func state(for brand: ProviderBrand) -> ProviderActivityState {
        switch brand { case .codex: return codex; case .claude: return claude }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        resumeWorker()
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isStarted, !self.isSleeping else { return }
                self.localCodex = ProviderActivityState()
                self.localClaude = ProviderActivityState()
                self.resetClaudeQuota()
                self.resumeWorker()
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        })
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        })
    }

    private func resumeWorker() {
        generation += 1
        let expected = generation
        worker.start { [weak self] pair in
            DispatchQueue.main.async {
                guard let self, self.isStarted, !self.isSleeping, self.generation == expected else { return }
                self.observeLocalActivity(pair)
            }
        }
    }

    private func sleep() {
        guard isStarted else { return }
        isSleeping = true
        generation += 1
        worker.stop()
        localCodex = ProviderActivityState()
        localClaude = ProviderActivityState()
        resetClaudeQuota()
    }

    private func wake() {
        guard isStarted else { return }
        isSleeping = false
        resumeWorker()
    }

    func stop() {
        isStarted = false
        isSleeping = false
        generation += 1
        worker.stop()
        for observer in notifications { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        notifications.removeAll()
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
        clockObserver = nil
        localCodex = ProviderActivityState()
        localClaude = ProviderActivityState()
        resetClaudeQuota()
    }
}

// One utility queue watches metadata and appended log bytes for both providers.
// The timer only discovers resumed sessions and checks liveness/rate expiration;
// file notifications deliver normal start/stop/usage changes promptly.
private final class ProviderActivityWorker {
    private let queue = DispatchQueue(label: "local.tokenmonitor.activity", qos: .utility)
    private let codex = CodexActivityProbe()
    private let claude = ClaudeActivityProbe()
    private var codexEstimator = ProviderActivityEstimator()
    private var claudeEstimator = ProviderActivityEstimator()
    private var callback: ((ProviderActivityPair) -> Void)?
    private var timer: DispatchSourceTimer?
    private var watches: [String: DispatchSourceFileSystemObject] = [:]
    private var pendingRead: DispatchWorkItem?
    private var lastReadUptime = -Double.infinity
    private var interval: TimeInterval = 0
    private var lastState = ProviderActivityPair()

    func start(_ callback: @escaping (ProviderActivityPair) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            self.callback = callback
            codex.reset()
            claude.reset()
            codexEstimator.reset()
            claudeEstimator.reset()
            lastState = ProviderActivityPair()
            lastReadUptime = -Double.infinity
            read()
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    private func stopOnQueue() {
        pendingRead?.cancel()
        pendingRead = nil
        timer?.cancel()
        timer = nil
        interval = 0
        for source in watches.values { source.cancel() }
        watches.removeAll()
        callback = nil
    }

    private func requestRead() {
        guard callback != nil, pendingRead == nil else { return }
        let delay = max(0.15, 0.75 - (ProcessInfo.processInfo.systemUptime - lastReadUptime))
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRead = nil
            self.read()
        }
        pendingRead = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func read() {
        guard let callback else { return }
        let now = Date()
        lastReadUptime = ProcessInfo.processInfo.systemUptime
        let codexReading = codex.read(at: now)
        let claudeDisabled = UserDefaults.standard.bool(forKey: "claudeActivityDisabled")
        let claudeReading = claudeDisabled ? ProviderActivityReading() : claude.read(at: now)
        var pair = ProviderActivityPair(codex: codexEstimator.update(codexReading, at: now),
            claude: claudeEstimator.update(claudeReading, at: now))
        if pair.claude.runningTaskCount == 0 {
            if claudeDisabled { pair.claude.statusNote = "Claude 活动采集已停用" }
            else if !UserDefaults.standard.bool(forKey: "claudeActivityEnabled") {
                pair.claude.statusNote = "Claude 活动采集尚未启用"
            } else if pair.claude.lastTaskEventAt == nil {
                pair.claude.statusNote = "等待任务信号"
            }
        }
        if pair != lastState { lastState = pair; callback(pair) }
        updateWatches(codexReading.watchedFiles + codexReading.watchedDirectories
            + claudeReading.watchedFiles + claudeReading.watchedDirectories)
        scheduleTimer(active: pair.codex.runningTaskCount > 0 || pair.claude.runningTaskCount > 0)
    }

    private func scheduleTimer(active: Bool) {
        let nextInterval: TimeInterval = active ? 5 : 15
        guard nextInterval != interval else { return }
        interval = nextInterval
        if timer == nil {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.setEventHandler { [weak self] in self?.requestRead() }
            timer = source
            source.schedule(deadline: .now() + nextInterval, repeating: nextInterval, leeway: .seconds(1))
            source.resume()
        } else {
            timer?.schedule(deadline: .now() + nextInterval, repeating: nextInterval, leeway: .seconds(1))
        }
    }

    private func updateWatches(_ urls: [URL]) {
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        for path in Array(watches.keys) where !wanted.contains(path) {
            watches.removeValue(forKey: path)?.cancel()
        }
        for path in wanted where watches[path] == nil {
            let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, let source = self.watches[path] else { return }
                if !source.data.intersection([.delete, .rename, .revoke]).isEmpty {
                    self.watches.removeValue(forKey: path)?.cancel()
                }
                self.requestRead()
            }
            source.setCancelHandler { Darwin.close(fd) }
            watches[path] = source
            source.resume()
        }
    }
}
