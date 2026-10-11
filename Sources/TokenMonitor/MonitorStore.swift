import Foundation
import AppKit
import Combine

@MainActor
final class MonitorStore: ObservableObject {
    let history: UsageHistoryStore
    @Published var codex = ProviderState(name: "Codex", message: "正在读取额度…")
    @Published var claude = ProviderState(name: "Claude · 实时", message: "正在通过官方 Claude Code 查询额度")
    @Published var compact = UserDefaults.standard.bool(forKey: "compact")
    // Pause immediately, even if an offscreen hosting view defers its onChange callback.
    weak var quotaLocalClock: WidgetClock?
    weak var edgeLocalClock: WidgetClock?
    @Published var quotaClockEnabled = false {
        didSet { if !quotaClockEnabled { quotaLocalClock?.stop() } }
    }
    @Published var edgeClockEnabled = false {
        didSet { if !edgeClockEnabled { edgeLocalClock?.stop() } }
    }
    @Published var isConnectingClaude = false
    @Published var claudeConnected = false
    @Published var claudeNeedsLogin = false
    @Published var claudeUsesStatusLine = UserDefaults.standard.bool(forKey: "claudeUsesStatusLine")
    @Published var setupMessage: String? = nil
    @Published var resetNews = ResetNewsState()
    private var codexTimer: Timer?
    private var claudeTimer: Timer?
    private var newsTimer: Timer?
    private var nextNewsFetch = Date.distantPast
    private var codexCycleTracker = QuotaCycleTracker()
    private var lastRecoveryAt: Date?
    private var lastClaudeData: Data?
    private var refreshTask: Task<Void, Never>?
    private var isCheckingClaudeAuth = false
    private var claudeRefreshTask: Task<Void, Never>?
    private var nextClaudeFetch = Date.distantPast
    private var claudeRetryDelay: TimeInterval = 300
    private var claudeIsThrottled = false
    private var claudeFetchGeneration = 0
    private var lastClaudeFetchStarted = Date.distantPast
    private let demo: Bool

    static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TOKEN_MONITOR_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Token Monitor", isDirectory: true)
    }

    init(demo: Bool = false) {
        self.demo = demo
        self.history = UsageHistoryStore(demo: demo)
        if demo {
            let now = Date()
            codex = ProviderState(name: "Codex · 演示", windows: [
                QuotaWindow(id: "five", name: "5小时额度", usedPercent: 32, resetsAt: now.addingTimeInterval(7560), durationSeconds: 18000),
                QuotaWindow(id: "week", name: "每周额度", usedPercent: 61, resetsAt: now.addingTimeInterval(208800), durationSeconds: 604800)
            ], updatedAt: now)
            claude = ProviderState(name: "Claude Code · 演示", windows: [
                QuotaWindow(id: "five", name: "5小时额度", usedPercent: 48, resetsAt: now.addingTimeInterval(11820), durationSeconds: 18000),
                QuotaWindow(id: "week", name: "每周额度", usedPercent: 23, resetsAt: now.addingTimeInterval(396000), durationSeconds: 604800)
            ], updatedAt: now)
            resetNews = ResetNewsState(headline: "演示：公共重置信息", detail: "公共消息与账户额度分别展示", sourceURL: URL(string: "https://codex-resets.com/zh-CN"), updatedAt: now, message: nil)
            history.updateLive(provider: .codex, state: codex, at: now)
            history.updateLive(provider: .claude, state: claude, at: now)
            history.updateResetNews(resetNews, at: now)
            return
        }
        readClaude()
        refreshNow()
        codexTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        claudeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.claudeUsesStatusLine else { return }
                self.readClaude()
            }
        }
        newsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNews() }
        }
    }

    func refreshNow(force: Bool = false) {
        guard !demo else { return }
        readClaude()
        checkClaudeConnection()
        if !claudeUsesStatusLine { refreshClaude(force: force) }
        refreshNews()
        guard !codex.isLoading else { return }
        codex.isLoading = true
        refreshTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> Result<CodexAccountSnapshot, ProbeError> in
                do { return .success(QuotaParser.codexSnapshot(try CodexProbe.read())) }
                catch let error as ProbeError { return .failure(error) }
                catch { return .failure(.serviceUnavailable) }
            }.value
            guard let self else { return }
            self.codex.isLoading = false
            switch outcome {
            case .success(let snapshot):
                let now = Date()
                let tracked = self.codexCycleTracker.update(snapshot.windows, at: now)
                self.codex.windows = tracked.windows
                self.codex.resetCreditCount = snapshot.resetCreditCount
                self.codex.updatedAt = now
                self.history.observe(provider: .codex, state: self.codex, at: now)
                if tracked.recovered { self.lastRecoveryAt = now }
                if snapshot.windows.isEmpty { self.codex.message = "账户未返回订阅额度 · 请确认使用 ChatGPT 登录" }
                else if let recovered = self.lastRecoveryAt, now.timeIntervalSince(recovered) < 86400 {
                    self.codex.message = "已观察到额度回补 · " + recovered.formatted(date: .omitted, time: .shortened)
                } else { self.codex.message = nil }
            case .failure(let error):
                self.codex.message = error.message
            }
        }
    }

    private func refreshNews() {
        guard !demo, !resetNews.isLoading, Date() >= nextNewsFetch else { return }
        resetNews.isLoading = true
        nextNewsFetch = Date().addingTimeInterval(60)
        Task {
            do { resetNews = try await ResetNewsService.read() }
            catch {
                resetNews.isLoading = false
                resetNews.message = "公共重置信息暂不可用 · 稍后自动重试"
                if case ResetNewsError.throttled(let delay) = error { nextNewsFetch = Date().addingTimeInterval(max(300, delay)) }
            }
            history.updateResetNews(resetNews)
        }
    }

    private func checkClaudeConnection() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stateFile = home.appendingPathComponent(".claude/token-monitor/install-state.json")
        let settingsFile = home.appendingPathComponent(".claude/settings.json")
        if let stateData = try? Data(contentsOf: stateFile),
           let settingsData = try? Data(contentsOf: settingsFile),
           let installState = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
           let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
           let command = installState["installedCommand"] as? String,
           let status = settings["statusLine"] as? [String: Any] {
            claudeConnected = status["command"] as? String == command && FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/token-monitor/bridge.py").path)
        } else { claudeConnected = false }
        // The official quota query needs no statusLine setup. Authentication
        // flags from a separate probe must not erase a successful quota result.
        guard claudeUsesStatusLine else { return }
        guard !isCheckingClaudeAuth else { return }
        isCheckingClaudeAuth = true
        Task {
            let loggedIn = await Task.detached(priority: .utility) { ClaudeAuthProbe.isLoggedIn() }.value
            isCheckingClaudeAuth = false
            if let loggedIn {
                claudeNeedsLogin = !loggedIn
                if !loggedIn {
                    claude.windows = []
                    claude.updatedAt = nil
                    lastClaudeData = nil
                    claude.message = "Claude Code 尚未登录 · 登录后正常回复即可同步"
                } else if claude.windows.isEmpty {
                    claude.message = claudeConnected ? "等待 Claude Code 正常回复后同步额度" : "启用额度采集后，正常使用 Claude Code"
                }
            }
        }
    }

    func loginClaude() {
        guard let script = Bundle.main.url(forResource: "Claude Login", withExtension: "command") else {
            setupMessage = "请在终端运行 claude auth login --claudeai"
            return
        }
        NSWorkspace.shared.open(script)
        setupMessage = "请在打开的登录页面完成授权，然后正常使用 Claude Code"
    }

    private func readClaude() {
        guard claudeUsesStatusLine else { return }
        guard !claudeNeedsLogin else { return }
        let file = Self.dataDirectory.appendingPathComponent("claude-quota.json")
        guard let data = try? Data(contentsOf: file) else {
            if claude.updatedAt != nil { claude.message = "本地额度快照暂不可读" }
            else { claude.message = statusLineDiagnosticMessage() }
            return
        }
        guard data != lastClaudeData else {
            if claude.windows.isEmpty { claude.message = statusLineDiagnosticMessage() }
            return
        }
        do {
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (snapshot["schemaVersion"] as? Int) == 1,
                  QuotaParser.number(snapshot["capturedAt"]) != nil else { throw ProbeError.invalidResponse }
            claude = QuotaParser.claude(snapshot)
            history.observe(provider: .claude, state: claude, at: Date())
            if claude.windows.isEmpty { claude.message = statusLineDiagnosticMessage() }
            lastClaudeData = data
        } catch { claude.message = "本地额度快照暂不可读 · 等待下次回复" }
    }

    private func statusLineDiagnosticMessage() -> String {
        let file = Self.dataDirectory.appendingPathComponent("statusline-diagnostics.json")
        guard let data = try? Data(contentsOf: file), data.count <= 4096,
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              status["schemaVersion"] as? Int == 1, status["callbackReceived"] as? Bool == true else {
            return "状态栏采集已配置 · 尚未收到回调"
        }
        if status["hasAPIResponse"] as? Bool == true {
            return "状态栏已收到响应 · 本次未提供订阅额度字段"
        }
        return "状态栏回调已连接 · 等待首个真实响应中的额度字段"
    }

    private func refreshClaude(force: Bool = false) {
        let now = Date()
        guard !demo, !claudeUsesStatusLine, !claude.isLoading,
              now.timeIntervalSince(lastClaudeFetchStarted) >= 5,
              now >= nextClaudeFetch || (force && !claudeIsThrottled) else { return }
        lastClaudeFetchStarted = now
        claudeFetchGeneration += 1
        let generation = claudeFetchGeneration
        claude.isLoading = true
        nextClaudeFetch = Date().addingTimeInterval(60)
        claudeRefreshTask = Task {
            let outcome = await Task.detached(priority: .utility) { () -> Result<ProviderState, ClaudeUsageError> in
                do { return .success(try ClaudeUsageProbe.read()) }
                catch let error as ClaudeUsageError { return .failure(error) }
                catch { return .failure(.unavailable) }
            }.value
            guard !claudeUsesStatusLine, generation == claudeFetchGeneration else { return }
            claude.isLoading = false
            switch outcome {
            case .success(let snapshot):
                claude = snapshot
                history.observe(provider: .claude, state: claude, at: Date())
                claudeNeedsLogin = false
                claudeIsThrottled = false
                claudeRetryDelay = 300
            case .failure(let error):
                claude.message = error.message + (claude.updatedAt == nil ? "" : " · 保留上次确认值")
                if case .rateLimited = error {
                    claudeIsThrottled = true
                    nextClaudeFetch = Date().addingTimeInterval(claudeRetryDelay)
                    claudeRetryDelay = min(3600, claudeRetryDelay * 2)
                }
            }
        }
    }

    func useClaudeStatusLine(_ enabled: Bool) {
        guard !demo, claudeUsesStatusLine != enabled else { return }
        claudeUsesStatusLine = enabled
        claudeFetchGeneration += 1
        UserDefaults.standard.set(enabled, forKey: "claudeUsesStatusLine")
        claude = ProviderState(name: enabled ? "Claude Code" : "Claude · 实时",
            message: enabled ? "等待 Claude Code 状态栏返回额度" : "正在通过官方 Claude Code 查询额度")
        lastClaudeData = nil
        claudeNeedsLogin = false
        setupMessage = nil
        if !claudeIsThrottled { nextClaudeFetch = .distantPast }
        refreshNow(force: true)
    }

    func connectClaude() {
        guard !demo, !isConnectingClaude else { return }
        guard let script = Bundle.main.url(forResource: "claude_bridge", withExtension: "py") else {
            setupMessage = "请从构建好的 Token Monitor.app 启动"
            return
        }
        isConnectingClaude = true
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                let process = Process()
                let candidates = ["/opt/anaconda3/bin/python", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
                    + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
                    + ["/usr/bin/python3"]
                let python = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
                guard let python else { return "未找到连接工具所需的 Python" }
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script.path, "install"]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errors
                do {
                    try process.run()
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus != 0 else { return nil }
                    // Classify local installation failures without displaying settings or raw logs.
                    let diagnostic = String(decoding: data.prefix(4096), as: UTF8.self)
                    if diagnostic.contains("Permission denied") || diagnostic.contains("Operation not permitted") { return "无法写入 Claude 设置 · 请检查目录权限" }
                    if diagnostic.contains("not a supported command") { return "现有 Claude 状态栏格式不支持自动连接" }
                    if diagnostic.contains("Expecting") || diagnostic.contains("Expected a JSON") || diagnostic.contains("Invalid") { return "Claude 设置格式有误 · 请修复 settings.json 后重试" }
                    return "连接未完成 · 请查看安装说明"
                } catch { return "连接工具无法启动 · 请查看安装说明" }
            }.value
            isConnectingClaude = false
            setupMessage = failure ?? "终端额度采集已启用 · 使用已有 Claude Code 会话，正常回复后显示"
            if failure == nil { claudeConnected = true }
            readClaude()
            checkClaudeConnection()
        }
    }

    func stop() {
        history.stop()
        codexTimer?.invalidate()
        claudeTimer?.invalidate()
        newsTimer?.invalidate()
        refreshTask?.cancel()
        claudeRefreshTask?.cancel()
    }
}
