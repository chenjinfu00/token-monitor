import Foundation
import Combine
import AppKit

/// One local timer per visible quota view. Service polling is independent.
@MainActor
final class WidgetClock: ObservableObject {
    enum Mode: Equatable { case stopped, regular, compact }
    struct Input: Equatable {
        let mode: Mode
        let providers: [ProviderState]
        init(mode: Mode, providers: [ProviderState]) {
            self.mode = mode
            // Loading/status timestamps do not restart a countdown with unchanged quota data.
            self.providers = providers.map { ProviderState(name: $0.name, windows: $0.windows) }
        }
    }
    @Published private(set) var now = Date()
    private var input = Input(mode: .stopped, providers: [])
    private var timer: Timer?
    private let wakeCenter = NSWorkspace.shared.notificationCenter
    private var wakeObserver: NSObjectProtocol?
    private var clockObserver: NSObjectProtocol?

    init() {
        wakeObserver = wakeCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
        clockObserver = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
    }

    func update(_ input: Input) {
        self.input = input
        restart()
    }

    func stop() { update(Input(mode: .stopped, providers: [])) }

    private func restart() {
        timer?.invalidate()
        timer = nil
        guard input.mode != .stopped else { return }
        now = Date()
        let next: Date?
        switch input.mode {
        case .stopped: next = nil
        case .regular: next = now.addingTimeInterval(1)
        case .compact: next = EdgeCountdownRefresh.nextUpdate(providers: input.providers, after: now)
        }
        guard let next, next > now else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] fired in
            Task { @MainActor in
                guard let self, self.timer === fired else { return }
                self.restart()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { wakeCenter.removeObserver(wakeObserver) }
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
    }
}
