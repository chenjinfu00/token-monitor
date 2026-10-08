import SwiftUI
import AppKit

// The explicit alias avoids the State macro in newer Command Line Tools SDKs.
private typealias WidgetState<Value> = SwiftUI.State<Value>

@MainActor
struct MonitorView: View {
    @ObservedObject var store: MonitorStore
    var onClose: () -> Void
    var onToggleCompact: () -> Void
    var onToggleEdge: () -> Void = {}
    var onHeightChange: (CGFloat) -> Void = { _ in }
    @WidgetState(initialValue: CGFloat.zero) private var providerHeight: CGFloat
    @WidgetState(initialValue: CGFloat.zero) private var reportedHeight: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 7) {
                providerArea(at: context.date)
                ResetNewsRow(state: store.resetNews, now: context.date)
            }
            .padding(10)
            .frame(width: store.compact ? 360 : 390)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: PanelHeightPreference.self, value: geometry.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onPreferenceChange(PanelHeightPreference.self) { height in
                let next = ceil(height)
                guard next > 0, abs(next - reportedHeight) > 0.5 else { return }
                reportedHeight = next
                onHeightChange(next)
            }
        }
    }

    private func providerArea(at now: Date) -> some View {
        let heightCap: CGFloat = store.compact ? 270 : 300
        let cards = providerCards(at: now)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ProviderHeightPreference.self, value: geometry.size.height)
                }
            }
        return Group {
            if providerHeight > heightCap {
                ScrollView { cards }
                    .scrollIndicators(.hidden)
                    .frame(height: heightCap)
            } else {
                cards
            }
        }
        .onPreferenceChange(ProviderHeightPreference.self) { height in
            let next = ceil(height)
            if next > 0, abs(next - providerHeight) > 0.5 { providerHeight = next }
        }
    }

    private func providerCards(at now: Date) -> some View {
        let refreshAction: () -> Void = { store.refreshNow(force: true) }
        let connectAction: (() -> Void)? = !store.claudeUsesStatusLine || store.claudeConnected ? nil : { store.connectClaude() }
        let loginAction: (() -> Void)? = store.claudeNeedsLogin ? { store.loginClaude() } : nil
        return VStack(spacing: 6) {
            ProviderCard(state: store.codex, accent: .codexGreen, symbol: "terminal",
                compact: store.compact, now: now, sourceDescription: "Codex 官方服务端额度", websiteNews: store.resetNews,
                refresh: refreshAction,
                toggleEdge: onToggleEdge, close: onClose, onDoubleClick: onToggleEdge)
            Divider().opacity(0.35).padding(.horizontal, 8)
            ProviderCard(state: store.claude, accent: .claudeOrange, symbol: "sparkle",
                compact: store.compact, now: now,
                sourceDescription: store.claudeUsesStatusLine ? "Claude Code 状态栏回调" : "官方 Claude Code 服务端实时额度",
                setupMessage: store.setupMessage, isConnecting: store.isConnectingClaude,
                connect: connectAction, login: loginAction, onDoubleClick: onToggleEdge)
        }
    }
}

private struct ProviderCard: View {
    let state: ProviderState
    let accent: Color
    let symbol: String
    let compact: Bool
    let now: Date
    let sourceDescription: String
    var websiteNews: ResetNewsState? = nil
    var setupMessage: String? = nil
    var refresh: (() -> Void)? = nil
    var toggleEdge: (() -> Void)? = nil
    var close: (() -> Void)? = nil
    var isConnecting = false
    var connect: (() -> Void)? = nil
    var login: (() -> Void)? = nil
    var onDoubleClick: (() -> Void)? = nil

    private var isStale: Bool { state.updatedAt.map { now.timeIntervalSince($0) > 300 } ?? false }
    private var windows: [QuotaWindow] { compact ? Array(state.windows.prefix(2)) : state.windows }
    private var status: String {
        [state.message, setupMessage].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: compact ? 5 : 6) {
            header
            ForEach(windows) { window in quotaWindow(window) }
            if let news = websiteNews, let reference = news.reference, news.canShowReference(at: now) {
                websiteReference(reference)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(accent)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 26, height: 26)
            Text(state.name.hasPrefix("Claude") ? "Claude" : "Codex")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 40, minHeight: 26, alignment: .leading)
                .help(state.name + "\n" + state.ageText(at: now) + "\n双击收起额度小窗 · 拖动可移动")
                .overlay { NativeWindowDragRegion(onDoubleClick: onDoubleClick) }
            if state.name.contains("演示") {
                Text("演示").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let count = state.resetCreditCount {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("\(count)").monospacedDigit()
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(accent)
                .help("官方同步的提前重置机会：\(count)次")
                .accessibilityLabel("提前重置机会 \(count)次")
            }
            InfoButton(symbol: isStale ? "clock.badge.exclamationmark" : "info.circle",
                label: "查看 \(state.name.hasPrefix("Claude") ? "Claude" : "Codex") 同步与重置时间",
                color: isStale ? .orange : .secondary) {
                providerDetails
            }
            Spacer(minLength: 2)
                .frame(minHeight: 26)
                .overlay { NativeWindowDragRegion(onDoubleClick: onDoubleClick) }
                .help("双击收起额度小窗 · 拖动可移动")
            if state.isLoading {
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16).accessibilityLabel("正在同步额度")
            }
            if let connect {
                IconAction(symbol: isConnecting ? "hourglass" : "link", label: "启用 Claude Code 额度采集", action: connect)
                    .disabled(isConnecting)
            }
            if let login {
                IconAction(symbol: "person.crop.circle", label: "登录 Claude Code", action: login)
            }
            if let refresh { IconAction(symbol: "arrow.clockwise", label: "立即刷新额度", action: refresh) }
            if let toggleEdge { IconAction(symbol: "sidebar.right", label: "收起到屏幕边缘", action: toggleEdge) }
            if let close { IconAction(symbol: "xmark", label: "隐藏悬浮窗", action: close) }
        }
        .frame(minHeight: 30)
    }

    private func quotaWindow(_ window: QuotaWindow) -> some View {
        let expired = window.isExpired(at: now)
        return HStack(spacing: 3) {
            ResetTimeButton(slotLabel: shortWindow(window), title: window.name + " · 重置时间",
                timestamp: window.resetsAt, now: now, description: resetDescription(window))
                .frame(width: 94, alignment: .leading)
            VStack(spacing: 3) {
                RatioRow(kind: .battery, label: "额度剩余", remaining: expired ? nil : window.remainingPercent,
                    unavailable: expired ? "窗口已结束，等待更新" : "尚未获取额度",
                    color: quotaColor(window.paceLevel(at: now)))
                RatioRow(kind: .hourglass, label: "时间剩余", remaining: expired ? nil : window.timeRemainingPercent(at: now),
                    unavailable: expired ? "窗口已结束，等待更新" : "周期未知，暂不比较", color: .timeBlue)
            }
        }
        .padding(.vertical, 2)
    }

    private func websiteReference(_ reference: WebsiteResetReference) -> some View {
        HStack(spacing: 3) {
            ResetTimeButton(slotLabel: "预测", title: "网站预测时间", timestamp: reference.referenceAt,
                now: now,
                description: reference.description(at: now) + "\n" + websiteReferenceDescription(reference, sourceURL: websiteNews?.sourceURL),
                color: .websitePurple)
                .frame(width: 94, alignment: .leading)
            RatioRow(kind: .hourglass, label: "网站预测窗口剩余", remaining: reference.remainingPercent(at: now),
                unavailable: "网站未提供预测时间", color: .websitePurple)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(reference.description(at: now) + "；网站预测并非账户确认的重置时间")
    }

    private func resetDescription(_ window: QuotaWindow) -> String {
        guard let reset = window.resetsAt else { return "重置时间待定" }
        return window.countdown(at: now) + "\n重置时间：\(WidgetDateFormatter.reset(reset))\n\(WidgetDateFormatter.timeZoneLabel)"
    }

    private var providerDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.name).font(.system(size: 16, weight: .semibold))
            Text("来源：\(state.name.contains("演示") ? "演示数据" : sourceDescription)")
                .font(.system(size: 14))
            Text("同步：\(state.updatedAt.map { WidgetDateFormatter.reset($0) } ?? "尚未同步")")
                .font(.system(size: 14)).monospacedDigit()
            if state.isLoading { Text("正在同步额度…").font(.system(size: 14)).foregroundStyle(.secondary) }
            if isStale {
                Text("较早快照 · \(state.ageText(at: now))").font(.system(size: 14)).foregroundStyle(.orange)
            }
            if !status.isEmpty { Text(status).font(.system(size: 14)).foregroundStyle(.secondary) }
            if state.windows.isEmpty {
                Text("尚未取得额度").font(.system(size: 14)).foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(state.windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(window.name).font(.system(size: 14, weight: .semibold))
                        Text("重置：\(window.resetsAt.map { WidgetDateFormatter.reset($0) } ?? "待定")")
                            .font(.system(size: 14)).monospacedDigit()
                    }
                }
            }
            Text(WidgetDateFormatter.timeZoneLabel).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private enum RatioGlyphKind { case battery, hourglass }

private struct RatioRow: View {
    let kind: RatioGlyphKind
    let label: String
    let remaining: Double?
    let unavailable: String
    let color: Color

    private var iconColor: Color { remaining == nil ? .secondary : color }
    private var tooltip: String {
        guard let remaining else { return unavailable }
        let percentage = label + "：" + percentageLabel(remaining)
        guard kind == .hourglass else { return percentage }
        return percentage + "\n沙漏阶段：" + hourglassPhase(remaining)
    }

    var body: some View {
        HStack(spacing: 5) {
            RatioGlyph(kind: kind, remaining: remaining, color: iconColor)
            QuotaBar(remaining: remaining, color: color)
            Text(remaining.map { percentageLabel($0) } ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(remaining == nil ? Color.secondary : color)
                .lineLimit(1)
                .frame(width: 44, alignment: .trailing)
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remaining.map { label + " " + percentageLabel($0) } ?? unavailable)
    }
}

private struct RatioGlyph: View {
    let kind: RatioGlyphKind
    let remaining: Double?
    let color: Color

    private var fraction: CGFloat? {
        guard let remaining, remaining.isFinite else { return nil }
        return CGFloat(max(0, min(100, remaining)) / 100)
    }

    private var hourglassSymbol: String {
        guard let fraction else { return "hourglass" }
        if fraction >= 2.0 / 3.0 { return "hourglass.tophalf.filled" }
        if fraction <= 1.0 / 3.0 { return "hourglass.bottomhalf.filled" }
        return "hourglass"
    }

    var body: some View {
        Group {
            switch kind {
            case .battery:
                ZStack {
                    Image(systemName: "battery.0")
                        .resizable().scaledToFit()
                        .frame(width: 20, height: 14)
                        .foregroundStyle(color)
                    if let fraction, fraction > 0 {
                        Image(systemName: "battery.100")
                            .resizable().scaledToFit()
                            .frame(width: 20, height: 14)
                            .foregroundStyle(color)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: 20 * fraction, height: 14)
                            }
                    }
                }
            case .hourglass:
                Image(systemName: hourglassSymbol).foregroundStyle(color)
            }
        }
        .font(.system(size: 16, weight: .medium))
        .symbolRenderingMode(.monochrome)
        .frame(width: 22, height: 18)
        .accessibilityHidden(true)
    }
}

private struct QuotaBar: View {
    let remaining: Double?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if let remaining {
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * max(0, min(100, remaining)) / 100)
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct ResetNewsRow: View {
    let state: ResetNewsState
    let now: Date

    private var warning: String {
        [state.message, state.freshnessWarning(at: now)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var sourceHost: String { state.sourceURL?.host ?? "codex-resets.com" }

    var body: some View {
        HStack(spacing: 6) {
            if let url = state.sourceURL {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Image(systemName: "globe").font(.system(size: 15, weight: .medium))
                        Text(sourceHost)
                    }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    .frame(minHeight: 30)
                }
                .buttonStyle(.plain)
                .help("打开第三方公共重置消息：\(sourceHost)")
                .accessibilityLabel("打开 \(sourceHost) 公共重置消息来源")
            }
            if state.isLoading {
                ProgressView().controlSize(.small)
                    .frame(width: 16, height: 16).accessibilityLabel("正在更新网站消息")
            }
            Spacer(minLength: 3)
            InfoButton(symbol: warning.isEmpty ? "info.circle" : "exclamationmark.triangle",
                label: warning.isEmpty ? "查看公共重置消息与更新时间" : "查看公共重置消息与警告",
                color: warning.isEmpty ? .secondary : .orange) { newsDetails }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 30)
    }

    private var newsDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("公共重置信息").font(.system(size: 16, weight: .semibold))
            if let headline = state.headline, !headline.isEmpty {
                Text(headline).font(.system(size: 14, weight: .medium))
            }
            if let detail = state.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            if !warning.isEmpty {
                Text(warning).font(.system(size: 14)).foregroundStyle(.orange)
            }
            if let timestamp = state.updatedAt {
                Text("更新：\(WidgetDateFormatter.reset(timestamp))")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct IconAction: View {
    let symbol: String
    let label: String
    var color: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color).frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(GlassIconButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct GlassIconButtonStyle: ButtonStyle {
    @WidgetState(initialValue: false) private var isHovered: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.13 : (isHovered ? 0.075 : 0))))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct InfoButton<Details: View>: View {
    var symbol = "info.circle"
    let label: String
    var color: Color = .secondary
    @ViewBuilder let details: () -> Details
    @WidgetState(initialValue: false) private var showsDetails: Bool

    var body: some View {
        IconAction(symbol: symbol, label: label, color: color) { showsDetails.toggle() }
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                details()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 340, alignment: .leading)
                    .padding(16)
            }
    }
}

private struct ResetTimeButton: View {
    let slotLabel: String
    let title: String
    let timestamp: Date?
    let now: Date
    let description: String
    var color: Color = .primary
    @WidgetState(initialValue: false) private var showsDetails: Bool

    var body: some View {
        Button { showsDetails.toggle() } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(timestamp.map { WidgetDateFormatter.shortReset($0) } ?? "待定")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
                Text(resetCountdown(timestamp, at: now))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(description)
        .accessibilityLabel(slotLabel + "；" + title + "；" + description)
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(description).font(.system(size: 14)).monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 320, alignment: .leading)
            .padding(16)
        }
    }
}

private func shortWindow(_ window: QuotaWindow) -> String {
    if window.name.contains("周") { return "每周" }
    if let duration = window.durationSeconds, duration > 0 {
        if duration.truncatingRemainder(dividingBy: 86400) == 0 { return "\(Int(duration / 86400))天" }
        if duration.truncatingRemainder(dividingBy: 3600) == 0 { return "\(Int(duration / 3600))小时" }
        return "\(Int(duration / 60))分钟"
    }
    return window.id == "spend_limit" ? "支出" : "额度"
}

private func quotaColor(_ pace: QuotaPace) -> Color {
    WidgetAppearance.quotaColor(pace)
}

private func percentageLabel(_ value: Double) -> String {
    guard value.isFinite else { return "—" }
    return "\(Int(max(0, min(100, value)).rounded()))%"
}

private func hourglassPhase(_ remaining: Double) -> String {
    if remaining >= 100 * 2.0 / 3.0 { return "前段" }
    if remaining <= 100 / 3.0 { return "后段" }
    return "中段"
}

private func resetCountdown(_ reset: Date?, at now: Date) -> String {
    guard let reset else { return "待定" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "等待更新" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "还需\(minutes / 1440)天\((minutes % 1440) / 60)时" }
    if minutes >= 60 { return "还需\(minutes / 60)时\(minutes % 60)分" }
    return "还需\(minutes)分"
}

private func websiteReferenceDescription(_ reference: WebsiteResetReference, sourceURL: URL?) -> String {
    "来源：\(sourceURL?.host ?? "codex-resets.com")\n网站预测窗口并非账户确认的重置时间。"
        + "\n公告起点：\(WidgetDateFormatter.reset(reference.startAt))"
        + "\n预计参考点：\(WidgetDateFormatter.reset(reference.referenceAt))"
        + "\n网站预测窗口开始：\(WidgetDateFormatter.reset(reference.windowStartAt))"
        + "\n网站预测窗口结束：\(WidgetDateFormatter.reset(reference.windowEndAt))"
        + "\n" + WidgetDateFormatter.timeZoneLabel
}

private struct ProviderHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PanelHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
