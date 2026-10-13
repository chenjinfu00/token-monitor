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
                self.codex = ProviderActivityState()
                self.claude = ProviderActivityState()
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
                if self.codex != pair.codex { self.codex = pair.codex }
                if self.claude != pair.claude { self.claude = pair.claude }
            }
        }
    }

    private func sleep() {
        guard isStarted else { return }
        isSleeping = true
        generation += 1
        worker.stop()
        codex = ProviderActivityState()
        claude = ProviderActivityState()
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
        codex = ProviderActivityState()
        claude = ProviderActivityState()
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
