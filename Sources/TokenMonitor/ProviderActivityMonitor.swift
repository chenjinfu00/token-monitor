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
    // Quota-based activity covers work this Mac cannot see: web, Cowork, cloud
    // tasks and other devices. Each provider keeps its own lease and timer.
    private var claudeInference = QuotaInference()
    private var codexInference = QuotaInference()
    private var claudeExpiryTimer: Timer?
    private var codexExpiryTimer: Timer?

    private var claudeDisabled: Bool { UserDefaults.standard.bool(forKey: "claudeActivityDisabled") }

    func observeClaudeQuota(_ state: ProviderState, at now: Date = Date()) {
        guard isStarted, !isSleeping else { return }
        guard !claudeDisabled else {
            resetClaudeQuota()
            return
        }
        guard claudeInference.observe(state, local: localClaude, at: now) else { return }
        rescheduleExpiry(for: .claude, at: now)
        publish(at: now)
    }

    func observeClaudeQuotaFailure(_ error: ClaudeUsageError, at now: Date = Date()) {
        switch error {
        case .unconfirmed, .timedOut, .unavailable, .rateLimited, .serviceRejected, .endpointUnavailable:
            // A transient failure has no new numbers or lifecycle evidence.
            // Let the last genuine consumption deadline expire on its own.
            retainClaudeQuotaInference(at: now)
        case .executableMissing, .invalidResponse, .signedOut, .noSubscriptionLimits:
            resetClaudeQuota()
        }
    }

    func retainClaudeQuotaInference(at now: Date = Date()) {
        // An unconfirmed query carries no new evidence. Keep only the existing
        // confirmed lease and its original timer; do not change the baseline.
        if claudeInference.expire(at: now) { cancelExpiry(for: .claude) }
        publish(at: now)
    }

    func resetClaudeQuota() {
        claudeInference.reset()
        cancelExpiry(for: .claude)
        publish()
    }

    func observeCodexQuota(_ state: ProviderState, at now: Date = Date()) {
        guard isStarted, !isSleeping else { return }
        guard codexInference.observe(state, local: localCodex, at: now) else { return }
        rescheduleExpiry(for: .codex, at: now)
        publish(at: now)
    }

    // Codex query failures carry no new numbers: the lease runs out on its own.
    func observeCodexQuotaFailure(at now: Date = Date()) {
        if codexInference.expire(at: now) { cancelExpiry(for: .codex) }
        publish(at: now)
    }

    func resetCodexQuota() {
        codexInference.reset()
        cancelExpiry(for: .codex)
        publish()
    }

    private func cancelExpiry(for brand: ProviderBrand) {
        switch brand {
        case .claude: claudeExpiryTimer?.invalidate(); claudeExpiryTimer = nil
        case .codex: codexExpiryTimer?.invalidate(); codexExpiryTimer = nil
        }
    }

    // One one-shot timer per lease ends inferred motion even if no query follows.
    private func rescheduleExpiry(for brand: ProviderBrand, at now: Date) {
        cancelExpiry(for: brand)
        let estimate: QuotaActivityEstimate?
        switch brand {
        case .claude: estimate = claudeInference.estimate
        case .codex: estimate = codexInference.estimate
        }
        guard let expected = estimate?.expiresAt else { return }
        let timer = Timer(timeInterval: max(0.01, expected.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                switch brand {
                case .claude:
                    guard self.claudeInference.endLease(expiringAt: expected) else { return }
                    self.claudeExpiryTimer = nil
                case .codex:
                    guard self.codexInference.endLease(expiringAt: expected) else { return }
                    self.codexExpiryTimer = nil
                }
                self.publish()
            }
        }
        timer.tolerance = 0.25
        switch brand {
        case .claude: claudeExpiryTimer = timer
        case .codex: codexExpiryTimer = timer
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func observeLocalActivity(_ pair: ProviderActivityPair) {
        localCodex = pair.codex
        localClaude = pair.claude
        if claudeInference.observeLocal(localClaude) { cancelExpiry(for: .claude) }
        if codexInference.observeLocal(localCodex) { cancelExpiry(for: .codex) }
        publish()
    }

    private func publish(at now: Date = Date()) {
        let nextClaude: ProviderActivityState
        if claudeDisabled {
            claudeInference.forgetCaptures()
            cancelExpiry(for: .claude)
            nextClaude = ProviderActivityState(statusNote: "Claude 活动采集已停用")
        } else {
            nextClaude = claudeInference.merged(into: localClaude, at: now)
        }
        let nextCodex = codexInference.merged(into: localCodex, at: now)
        if codex != nextCodex { codex = nextCodex }
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
        func estimateSnapshot(_ estimate: QuotaActivityEstimate?) -> Any {
            estimate.map {
                ["percentPerMinute": $0.percentPerMinute, "sampledFrom": $0.sampledFrom.timeIntervalSince1970,
                 "expiresAt": $0.expiresAt.timeIntervalSince1970] as [String: Any]
            } ?? NSNull()
        }
        return ["started": isStarted, "sleeping": isSleeping,
                "claudeActivityDisabled": claudeDisabled,
                "claudeActivityHooksEnabled": UserDefaults.standard.bool(forKey: "claudeActivityEnabled"),
                "codex": stateSnapshot(codex), "claude": stateSnapshot(claude),
                "codexLocal": stateSnapshot(localCodex), "claudeLocal": stateSnapshot(localClaude),
                "claudeQuotaEstimate": estimateSnapshot(claudeInference.estimate),
                "codexQuotaEstimate": estimateSnapshot(codexInference.estimate),
                "claudeQuotaExpiryTimerScheduled": claudeExpiryTimer?.isValid ?? false,
                "codexQuotaExpiryTimerScheduled": codexExpiryTimer?.isValid ?? false,
                "claudeTelemetryEnabled": UserDefaults.standard.bool(forKey: ClaudeTelemetryReceiver.enabledKey),
                "claudeTelemetry": ClaudeTelemetryReceiver.shared.diagnosticSnapshot(),
                "lastClaudeQuotaAt": claudeInference.lastQuotaAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull(),
                "lastCodexQuotaAt": codexInference.lastQuotaAt.map { $0.timeIntervalSince1970 } as Any? ?? NSNull()]
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
                self.resetQuotaInference()
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

    private func resetQuotaInference() {
        codexInference.reset()
        cancelExpiry(for: .codex)
        resetClaudeQuota()
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
        resetQuotaInference()
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
        resetQuotaInference()
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
        let hooksEnabled = UserDefaults.standard.bool(forKey: "claudeActivityEnabled")
        let telemetryEnabled = !claudeDisabled && UserDefaults.standard.bool(forKey: ClaudeTelemetryReceiver.enabledKey)
        var claudeReading = claudeDisabled ? ProviderActivityReading() : claude.read(at: now)
        if telemetryEnabled {
            // Exported events arrive between file events; read them promptly.
            ClaudeTelemetryReceiver.shared.start { [weak self] in
                guard let self else { return }
                self.queue.async { self.requestRead() }
            }
            claudeReading = ClaudeTelemetryReceiver.shared.snapshot(at: now)
                .merged(into: claudeReading, hooksEnabled: hooksEnabled)
        } else {
            ClaudeTelemetryReceiver.shared.stop()
        }
        var pair = ProviderActivityPair(codex: codexEstimator.update(codexReading, at: now),
            claude: claudeEstimator.update(claudeReading, at: now))
        if pair.claude.runningTaskCount == 0 {
            if claudeDisabled { pair.claude.statusNote = "Claude 活动采集已停用" }
            else if !hooksEnabled && !telemetryEnabled {
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
