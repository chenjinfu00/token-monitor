import SwiftUI

private typealias EdgeWidgetState<Value> = SwiftUI.State<Value>

enum ScreenEdge: String { case left, right, top }

@MainActor
struct EdgeHandleView: View {
    static let size = CGSize(width: 48, height: 172)
    @ObservedObject var store: MonitorStore
    let edge: ScreenEdge
    let onExpand: () -> Void
    var onDragEnded: () -> Void = {}
    var onSizeChange: (CGSize) -> Void = { _ in }
    @EdgeWidgetState(initialValue: CGSize.zero) private var reportedSize: CGSize

    @StateObject private var clock = WidgetClock()
    private var clockInput: WidgetClock.Input {
        WidgetClock.Input(mode: store.edgeClockEnabled ? .compact : .stopped,
                          providers: [store.codex, store.claude])
    }

    var body: some View {
        Group {
            let codex = EdgeQuotaSummary(provider: store.codex, at: clock.now)
            let claude = EdgeQuotaSummary(provider: store.claude, at: clock.now)
            let summary = tooltip(name: "Codex", summary: codex)
                + "\n" + tooltip(name: "Claude", summary: claude)
            Group {
                if edge == .top {
                    HStack(spacing: 12) {
                        providerSummary(codex: codex, claude: claude, tooltip: summary)
                        resetNewsLink
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 12) {
                        providerSummary(codex: codex, claude: claude, tooltip: summary)
                        resetNewsLink
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 10)
                    .frame(width: Self.size.width)
                }
            }
            .fixedSize()
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: EdgeSizePreference.self, value: geometry.size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onPreferenceChange(EdgeSizePreference.self) { size in
                let next = CGSize(width: ceil(size.width), height: ceil(size.height))
                guard next.width > 0, next.height > 0,
                      abs(next.width - reportedSize.width) > 0.5 || abs(next.height - reportedSize.height) > 0.5 else { return }
                reportedSize = next
                onSizeChange(next)
            }
        }
        .onAppear { store.edgeLocalClock = clock; clock.update(clockInput) }
        .onChange(of: clockInput) { _ in clock.update(clockInput) }
        .onDisappear { clock.stop() }
    }

    private func providerSummary(codex: EdgeQuotaSummary, claude: EdgeQuotaSummary, tooltip: String) -> some View {
        Group {
            if edge == .top {
                HStack(spacing: 12) {
                    EdgeQuotaGroup(brand: .codex, summary: codex, horizontal: true)
                    EdgeQuotaGroup(brand: .claude, summary: claude, horizontal: true)
                }
            } else {
                VStack(spacing: 12) {
                    EdgeQuotaGroup(brand: .codex, summary: codex)
                    EdgeQuotaGroup(brand: .claude, summary: claude)
                }
            }
        }
        .contentShape(Rectangle())
        .overlay(NativeCollapsedWindowInteraction(onClick: onExpand, onDragEnded: onDragEnded))
        .help(tooltip + "\n双击展开额度小窗 · 拖动可移动")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("双击展开额度小窗；" + tooltip)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onExpand() }
    }

    private var resetNewsLink: some View {
        Link(destination: URL(string: "https://codex-resets.com/zh-CN")!) {
            Image(systemName: "globe")
                .resizable().scaledToFit()
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .help("打开 codex-resets.com 的第三方公共重置消息")
        .accessibilityLabel("打开 Codex 公共重置消息")
    }

    private func tooltip(name: String, summary: EdgeQuotaSummary) -> String {
        var result = name + " · " + (summary.window?.name ?? "额度未知")
        result += " · 剩余 " + summary.percentText
        if let window = summary.window, summary.hoursText != "—", let reset = window.resetsAt {
            result += "\n距离重置 " + summary.hoursText + " · " + WidgetDateFormatter.reset(reset) + " " + WidgetDateFormatter.timeZoneLabel
        } else if summary.window?.resetsAt == nil {
            result += "\n重置时间待定"
        } else {
            result += "\n窗口已结束 · 等待更新"
        }
        return result
    }
}

private struct EdgeQuotaGroup: View {
    let brand: ProviderBrand
    let summary: EdgeQuotaSummary
    var horizontal = false

    var body: some View {
        Group {
            if horizontal {
                HStack(spacing: 4) {
                    brandSymbol
                    quotaValues
                }
            } else {
                VStack(spacing: 2) {
                    brandSymbol
                    quotaValues
                }
                .frame(width: 40)
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    private var brandSymbol: some View {
        ProviderBrandIcon(brand: brand)
            .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private var quotaValues: some View {
        Text(summary.percentText)
            .foregroundStyle(summary.remainingPercent == nil ? Color.secondary : WidgetAppearance.quotaColor(summary.pace))
            .fixedSize(horizontal: true, vertical: false)
        Text(summary.window?.resetsAt == nil ? "待定" : (summary.daysText ?? summary.hourComponentText))
            .foregroundStyle(summary.hourComponentText == "—" ? Color.secondary : .timeBlue)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct EdgeSizePreference: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        value = CGSize(width: max(value.width, next.width), height: max(value.height, next.height))
    }
}
