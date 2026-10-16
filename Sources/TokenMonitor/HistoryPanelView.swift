import SwiftUI
import Charts
import AppKit

// Avoid the Foundation State macro supplied by newer macOS SDKs.
private typealias HistoryViewState<Value> = SwiftUI.State<Value>

@MainActor
struct HistoryPanelView: View {
    @ObservedObject var history: UsageHistoryStore
    var onToggleExpanded: () -> Void = {}
    var onClose: () -> Void = {}
    var onRefresh: () -> Void = {}
    @HistoryViewState(initialValue: HistoryTimeScale.day) private var scale: HistoryTimeScale
    @HistoryViewState(initialValue: Date()) private var referenceDate: Date
    @HistoryViewState(initialValue: Date()) private var latestDate: Date
    @HistoryViewState(initialValue: true) private var followsPresent: Bool
    @HistoryViewState(initialValue: HistoryProvider.codex) private var provider: HistoryProvider
    @HistoryViewState(initialValue: "") private var windowID: String
    @HistoryViewState(initialValue: [HistoryWindowOption]()) private var knownWindows: [HistoryWindowOption]
    @HistoryViewState(initialValue: [UsageHistoryRecord]()) private var displayedRecords: [UsageHistoryRecord]
    @HistoryViewState(initialValue: HistoryPlot.empty) private var cachedPlot: HistoryPlot
    @HistoryViewState(initialValue: [HistoryAnnualUsage.Week]()) private var cachedAnnualWeeks: [HistoryAnnualUsage.Week]
    @HistoryViewState(initialValue: 0) private var renderGeneration: Int
    @HistoryViewState(initialValue: Optional<Task<Void, Never>>.none) private var renderTask: Task<Void, Never>?
    @HistoryViewState(initialValue: Optional<UUID>.none) private var selectedID: UUID?
    @HistoryViewState(initialValue: Optional<UUID>.none) private var selectedEventID: UUID?
    @HistoryViewState(initialValue: false) private var showingEventDetails: Bool
    @HistoryViewState(initialValue: false) private var showingEventList: Bool
    @HistoryViewState(initialValue: Optional<HistoryResetRecord>.none) private var pinnedReset: HistoryResetRecord?
    @HistoryViewState(initialValue: Optional<Date>.none) private var selectedWeekID: Date?
    @AppStorage("history.showResetMarkers") private var showsResetMarkers = true

    private var range: DateInterval { scale.range(containing: referenceDate) }
    private var accent: Color { provider == .codex ? .codexGreen : .claudeOrange }
    private var pacingGuides: [QuotaPacingGuide] {
        guard let window = history.liveWindows[provider]?.first(where: { $0.id == effectiveWindowID }) else { return [] }
        return QuotaPacingGuide.make(provider: provider, window: window, resetHistory: history.resetHistory,
                                    reference: history.websiteReference, at: latestDate)
    }
    private var timelineEnd: Date {
        if scale == .year { return latestDate }
        guard let target = pacingGuides.first(where: { $0.source == .official })?.targetAt else { return latestDate }
        return target.addingTimeInterval(range.duration * 0.08)
    }
    private var presentEnd: Date {
        if scale == .year { return latestDate }
        guard let target = pacingGuides.first(where: { $0.source == .official })?.targetAt else { return latestDate }
        return latestDate.addingTimeInterval(min(target.timeIntervalSince(latestDate) + range.duration * 0.06, range.duration * 0.35))
    }
    private var windowOptions: [HistoryWindowOption] {
        knownWindows.filter { $0.provider == provider }.sorted { left, right in
            if left.duration != right.duration { return (left.duration ?? .greatestFiniteMagnitude) < (right.duration ?? .greatestFiniteMagnitude) }
            return left.id < right.id
        }
    }
    private var effectiveWindowID: String { windowOptions.contains(where: { $0.id == windowID }) ? windowID : (windowOptions.first?.id ?? "") }
    private var matchingRecords: [UsageHistoryRecord] { displayedRecords }
    private var annualWeeks: [HistoryAnnualUsage.Week] { cachedAnnualWeeks }
    private var currentAnnualObservation: (used: Double?, observedAt: Date?) {
        let updated = history.liveUpdatedAt[provider]
        let window = history.liveWindows[provider]?.first { $0.id == effectiveWindowID }
        let isFresh = updated.map { latestDate.timeIntervalSince($0) <= 300 && $0.timeIntervalSince(latestDate) <= 30 } ?? false
        return (isFresh && window?.isExpired(at: latestDate) != true ? window?.usedPercent : nil,
                isFresh ? updated : nil)
    }
    private var annualYMaximum: Double {
        max(100, (annualWeeks.compactMap(\.cumulativeUsedPercent).max() ?? 0) * 1.12)
    }
    private var visibleAnnualWeek: HistoryAnnualUsage.Week? {
        if let selectedWeekID { return annualWeeks.first { $0.id == selectedWeekID } }
        return annualWeeks.last { $0.cumulativeUsedPercent != nil }
    }
    private var selected: UsageHistoryRecord? {
        guard let selectedID else { return nil }
        return cachedPlot.points.first { $0.id == selectedID }?.record
    }
    private var visibleSelection: UsageHistoryRecord? { selected ?? cachedPlot.points.last?.record }
    private var selectedEvent: HistoryPlot.Event? {
        if let pinnedReset { return resetEvent(pinnedReset) }
        guard let selectedEventID else { return nil }
        return visibleEvents.first { $0.id == selectedEventID }
    }
    private var visibleEvents: [HistoryPlot.Event] {
        var grouped: [Date: [HistoryResetEvent]] = [:]
        var seen = Set<UUID>()
        for event in cachedPlot.events.flatMap(\.events) where seen.insert(event.id).inserted {
            grouped[event.observedAt, default: []].append(event)
        }
        for record in history.resetHistory where record.provider == provider && record.windowID == effectiveWindowID
            && record.observedAt >= range.start && record.observedAt <= range.end {
            let event = resetEvent(record).primary
            if seen.insert(event.id).inserted { grouped[event.observedAt, default: []].append(event) }
        }
        return grouped.values.map { HistoryPlot.Event(events: $0) }.sorted { $0.observedAt < $1.observedAt }
    }
    private var earliestDate: Date {
        let recorded = min(history.firstRecordedAt ?? latestDate, history.resetHistory.map(\.observedAt).min() ?? latestDate)
        let cycle = pacingGuides.map(\.startAt).min() ?? recorded
        return min(recorded, cycle, scale.range(containing: presentEnd).start)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            filters
            dateNavigation
            chartArea
            inspection
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(minWidth: 640, minHeight: 440)
        .onAppear {
            latestDate = history.liveNow
            rememberWindows()
            if followsPresent { referenceDate = presentEnd }
            rebuildSeries(); refreshVisibleRange(); history.refreshResetHistory()
        }
        .onDisappear { renderTask?.cancel() }
        .onChange(of: scale) { _ in if followsPresent { referenceDate = presentEnd } }
        .onChange(of: range) { _ in prepareSelectionForViewChange(); rebuildSeries(); refreshVisibleRange() }
        .onChange(of: provider) { _ in
            if followsPresent { referenceDate = presentEnd }
            else if referenceDate > timelineEnd { referenceDate = timelineEnd }
            prepareSelectionForViewChange(); rebuildSeries()
        }
        .onChange(of: windowID) { _ in
            if followsPresent { referenceDate = presentEnd }
            else if referenceDate > timelineEnd { referenceDate = timelineEnd }
            prepareSelectionForViewChange(); rebuildSeries()
        }
        .onChange(of: history.records) { _ in rememberWindows(); rebuildSeries() }
        .onChange(of: history.resetHistory) { _ in rememberWindows(); rebuildSeries() }
        .onChange(of: history.liveWindows) { _ in
            rememberWindows()
            if followsPresent { referenceDate = presentEnd }
            else if referenceDate > timelineEnd { referenceDate = timelineEnd }
            if scale == .year { rebuildSeries() }
        }
        .onChange(of: history.liveUpdatedAt) { _ in if scale == .year { rebuildSeries() } }
        .onChange(of: history.websiteReference) { _ in if followsPresent { referenceDate = presentEnd } }
        .onChange(of: history.liveNow) { now in
            latestDate = now
            if followsPresent { referenceDate = presentEnd }
            else if referenceDate > timelineEnd { referenceDate = timelineEnd }
            if scale == .year && !followsPresent { rebuildSeries() }
        }
        .onChange(of: history.revision) { _ in
            latestDate = history.liveNow
            if followsPresent { referenceDate = presentEnd }
            refreshVisibleRange()
        }
    }

    private var filters: some View {
        HStack(spacing: 14) {
            WindowControlBar(onHide: onClose, onResize: onToggleExpanded,
                             onRefresh: onRefresh, isRefreshing: history.isLoading, onDoubleClick: onToggleExpanded) {
                EmptyView()
            }
            Picker("额度窗口", selection: Binding(get: { effectiveWindowID }, set: { windowID = $0 })) {
                if windowOptions.isEmpty { Text("暂无额度窗口").tag("") }
                ForEach(windowOptions) { option in Text(option.title).tag(option.id) }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(minWidth: 90, maxWidth: 170, alignment: .leading)
            .disabled(windowOptions.isEmpty)
            .help("按独立额度窗口查看；不同窗口的百分比不合并")
            Spacer(minLength: 12)
                .frame(minHeight: 26)
                .overlay { NativeWindowDragRegion(onDoubleClick: onToggleExpanded) }
            if let error = history.errorMessage {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.paceYellow)
                    .frame(width: 20, height: 26).help(error).accessibilityLabel(error)
            }
            Button { history.refreshResetHistory(); showingEventList = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 16, weight: .medium)).frame(width: 24, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("重置历史").accessibilityLabel("重置历史")
            .popover(isPresented: $showingEventList, arrowEdge: .bottom) { eventList }
            HStack(spacing: 2) {
                providerButton(.codex, brand: .codex, title: "Codex")
                providerButton(.claude, brand: .claude, title: "Claude")
            }
        }
    }

    // The rotating brand icon is an AppKit layer that lets every click through
    // (its hitTest returns nil), so on its own it gives the button no hit area:
    // clicks on it never reached this action. contentShape hands the whole tile
    // to the button, as the compact window's brand button already does.
    private func providerButton(_ value: HistoryProvider, brand: ProviderBrand, title: String) -> some View {
        let isSelected = provider == value
        return Button { provider = value } label: {
            ProviderBrandIcon(brand: brand)
                .frame(width: 20, height: 20)
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.12 : 0)))
                .opacity(isSelected ? 1 : 0.55)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "正在显示 " + title : "切换到 " + title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var dateNavigation: some View {
        VStack(spacing: 11) {
            Picker("时间尺度", selection: $scale) {
                ForEach(HistoryTimeScale.allCases) { value in Text(value.title).tag(value) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 9) {
                Text(scale.rangeTitle(range)).font(.system(size: 14, weight: .medium)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 3)
                Button("现在") { followsPresent = true; latestDate = history.liveNow; referenceDate = presentEnd }
                    .buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 13, weight: .medium))
                    .help("滚动到最新记录")
            }
        }
    }

    @ViewBuilder private var chartArea: some View {
        if history.firstRecordedAt == nil && history.records.isEmpty && history.resetHistory.isEmpty
            && (scale == .year ? annualWeeks.allSatisfy({ $0.cumulativeUsedPercent == nil }) : pacingGuides.isEmpty) {
            VStack(spacing: 9) {
                Image(systemName: history.recordingEnabled ? "chart.xyaxis.line" : "pause.circle")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text(history.recordingEnabled ? "待记录" : "已暂停")
                    .font(.system(size: 15, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 110)
            .accessibilityElement(children: .combine)
        } else {
            ZStack {
                HistoryScrollableChart(earliest: earliestDate, latest: timelineEnd,
                    visibleDuration: range.duration, visibleEnd: referenceDate, onVisibleEndChange: { end in
                        followsPresent = abs(end.timeIntervalSince(presentEnd)) < 1
                        referenceDate = end
                    }, content: selectedChart.padding(.top, 6))
                if (scale == .year ? annualWeeks.allSatisfy({ $0.cumulativeUsedPercent == nil })
                    : matchingRecords.isEmpty && pacingGuides.isEmpty) && !history.isLoading {
                    Text(scale == .year ? "待记录" : "这段时间没有有效采样")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 110)
        }
    }

    @ViewBuilder private var selectedChart: some View {
        if scale == .year { annualChart } else { historyChart }
    }

    private var annualChart: some View {
        let weeks = annualWeeks
        return Chart {
            ForEach(weeks) { week in
                let lower = max(range.start, week.weekStart)
                let upper = min(range.end, week.weekEnd)
                let padding = upper.timeIntervalSince(lower) * 0.12
                if let amount = week.cumulativeUsedPercent {
                    RectangleMark(xStart: .value("周开始", lower.addingTimeInterval(padding)),
                            xEnd: .value("周结束", upper.addingTimeInterval(-padding)),
                            yStart: .value("额度基线", 0.0), yEnd: .value("累计已用额度", amount))
                        .foregroundStyle(accent.opacity(week.id == selectedWeekID ? 1 : 0.76))
                        .cornerRadius(2)
                }
            }
            if showsResetMarkers {
                ForEach(visibleEvents) { event in
                    PointMark(x: .value("重置观测", event.observedAt), y: .value("重置标记", annualYMaximum * 0.025))
                        .symbol(.diamond).symbolSize(event.id == selectedEventID ? 60 : 20)
                        .foregroundStyle(eventColor(event))
                }
            }
            if let event = selectedEvent {
                RuleMark(x: .value("选中重置观测", event.observedAt))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(eventColor(event))
            }
        }
        .chartYScale(domain: 0...annualYMaximum)
        .chartXScale(domain: range.start...range.end)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(percent(amount)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { value in
                AxisTick().foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(scale.axisLabel(date)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase { inspectAnnual(at: location, proxy: proxy, geometry: geometry) }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        inspectAnnual(at: value.location, proxy: proxy, geometry: geometry)
                    }.onEnded { _ in if selectedEvent != nil { showingEventDetails = true } })
            }
        }
        .accessibilityLabel("\(provider.name) 每周累计额度柱状图")
        .help("按周累计已用窗口额度，允许超过 100%；空周不补零。")
    }

    private var historyChart: some View {
        let values = cachedPlot
        let events = visibleEvents
        let guides = pacingGuides
        return Chart {
            if range.end > latestDate {
                RectangleMark(xStart: .value("未来开始", max(range.start, latestDate)), xEnd: .value("未来结束", range.end),
                              yStart: .value("额度下限", 0), yEnd: .value("额度上限", 100))
                    .foregroundStyle(Color.secondary.opacity(0.035))
            }
            ForEach(guides) { guide in
                ForEach(guide.clippedPoints(in: range), id: \.date) { point in
                    LineMark(x: .value("参考时间", point.date), y: .value("线性额度参考", point.usedPercent),
                             series: .value("连续采样段", guide.source == .official ? -1 : -2))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                        .foregroundStyle(guideColor(guide))
                }
                if guide.targetAt >= range.start && guide.targetAt <= range.end {
                    RuleMark(x: .value("下次重置", guide.targetAt))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 4]))
                        .foregroundStyle(guideColor(guide).opacity(0.3))
                    PointMark(x: .value("下次重置", guide.targetAt), y: .value("周期额度", 100))
                        .symbolSize(28).foregroundStyle(guideColor(guide))
                }
            }
            if latestDate >= range.start && latestDate <= range.end && range.end > latestDate {
                RuleMark(x: .value("现在", latestDate))
                    .lineStyle(StrokeStyle(lineWidth: 0.6))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
            ForEach(values.points) { point in
                LineMark(x: .value("记录区间", point.date), y: .value("已使用峰值", point.record.peakUsedPercent),
                         series: .value("连续采样段", point.segment))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(accent)
                if values.points.count < 90 || point.isIsolated {
                    PointMark(x: .value("记录区间", point.date), y: .value("已使用峰值", point.record.peakUsedPercent))
                        .symbolSize(point.isIsolated ? 28 : 14).foregroundStyle(accent)
                }
            }
            if showsResetMarkers {
                ForEach(events) { event in
                    if scale == .day {
                        RuleMark(x: .value("重置观测", event.observedAt))
                            .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 4]))
                            .foregroundStyle(eventColor(event).opacity(event.hasRecovery ? 0.42 : 0.2))
                    }
                    PointMark(x: .value("重置观测", event.observedAt), y: .value("重置标记", 3))
                        .symbol(.diamond).symbolSize(event.id == selectedEventID ? 70 : 32)
                        .foregroundStyle(eventColor(event))
                        .accessibilityLabel(eventTitle(event))
                        .accessibilityValue(eventSummary(event))
                }
            }
            if let event = selectedEvent {
                RuleMark(x: .value("选中重置观测", event.observedAt))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4])).foregroundStyle(eventColor(event))
            }
            if let selected, let point = values.points.first(where: { $0.record.id == selected.id }) {
                RuleMark(x: .value("选中区间", point.date))
                    .lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(Color.secondary.opacity(0.5))
                PointMark(x: .value("选中区间", point.date), y: .value("已使用峰值", selected.peakUsedPercent))
                    .symbolSize(60).foregroundStyle(accent)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: range.start...range.end)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let amount = value.as(Int.self) {
                        Text("\(amount)%").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisTick().foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(scale.axisLabel(date)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active(let location) = phase {
                            inspect(at: location, proxy: proxy, geometry: geometry, plot: values)
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        inspect(at: value.location, proxy: proxy, geometry: geometry, plot: values)
                    }.onEnded { _ in
                        if selectedEvent != nil { showingEventDetails = true }
                    })
                    pacingLabels(guides, proxy: proxy, geometry: geometry)
                }
            }
        }
        .accessibilityLabel("\(provider == .codex ? "Codex" : "Claude") 已使用额度峰值图，纵轴百分之零至百分之一百")
        .accessibilityValue("显示 \(values.points.count) 个峰值点，最高 \(values.points.map { $0.record.peakUsedPercent }.max().map { percent($0) } ?? "待定")；移至折线查看记录详情")
        .help("鼠标移至折线查看峰值；点击底部菱形，查看每次额度恢复或重置计划的详细观测。")
    }

    private func guideColor(_ guide: QuotaPacingGuide) -> Color {
        guide.source == .official ? .timeBlue : (guide.forecastConfidence?.color ?? .secondary)
    }

    private func guideLabelX(_ guide: QuotaPacingGuide, proxy: ChartProxy, frame: CGRect) -> CGFloat {
        let inset: CGFloat = 61
        let target = guide.targetAt >= range.start && guide.targetAt <= range.end
            ? (proxy.position(forX: guide.targetAt).map { frame.minX + $0 } ?? frame.maxX - inset)
            : frame.maxX - inset
        return max(frame.minX + inset, min(frame.maxX - inset, target))
    }

    private func pacingLabels(_ guides: [QuotaPacingGuide], proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        let frame = geometry[proxy.plotAreaFrame]
        let firstX = guides.first.map { guideLabelX($0, proxy: proxy, frame: frame) }
        return ForEach(Array(guides.enumerated()), id: \.element.id) { index, guide in
            let confidence = guide.source == .official ? "" : "；" + (guide.forecastConfidence?.label ?? "置信度未知")
            let x = guideLabelX(guide, proxy: proxy, frame: frame)
            let offset: CGFloat = index > 0 && abs(x - (firstX ?? x)) < 124 ? 23 : 0
            Button { revealGuide(guide) } label: {
                HStack(spacing: 4) {
                    Image(systemName: guide.source == .official ? "arrow.clockwise" : "globe")
                        .font(.system(size: 11, weight: .medium))
                    Text(WidgetDateFormatter.reset(guide.targetAt))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).foregroundStyle(guideColor(guide))
            .position(x: x, y: frame.minY + 14 + offset)
            .help("\(guide.source == .official ? "官方重置" : "Codex Reset 提前预测") \(WidgetDateFormatter.reset(guide.targetAt))\(confidence)。虚线为当前周期从 0% 至 100% 的线性额度参考；点击定位。")
            .accessibilityLabel("\(guide.source == .official ? "官方重置" : "提前预测")，\(WidgetDateFormatter.reset(guide.targetAt))\(confidence)")
            .accessibilityHint("定位到该重置时间")
        }
    }

    private func revealGuide(_ guide: QuotaPacingGuide) {
        followsPresent = false
        pinnedReset = nil
        selectedID = nil
        selectedEventID = nil
        referenceDate = min(timelineEnd, guide.targetAt.addingTimeInterval(range.duration * 0.06))
    }

    private var inspection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)
            if let event = selectedEvent {
                eventInspection(event)
            } else if scale == .year, let week = visibleAnnualWeek {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(WidgetDateFormatter.reset(week.weekStart)) – \(WidgetDateFormatter.reset(min(week.weekEnd, latestDate)))")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text("\(week.observedResetCount) 次恢复")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    inspectionValue("累计已用", value: week.cumulativeUsedPercent.map(percent) ?? "—", color: accent)
                }
            } else if scale != .year, let record = visibleSelection {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(WidgetDateFormatter.reset(record.intervalStart)) – \(WidgetDateFormatter.reset(record.intervalEnd))")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text("\(record.intervalMinutes) 分钟 · \(record.sampleCount) 次")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    inspectionValue("峰值", value: percent(record.peakUsedPercent), color: accent)
                    inspectionValue("末次", value: percent(record.lastUsedPercent), color: .primary)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("计划重置").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(record.resetsAt.map { WidgetDateFormatter.reset($0) } ?? "待定")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }
                }
                Text(recordDetail(record))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("—")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
            }
        }
        .frame(minHeight: 62, alignment: .top)
    }

    private func inspectionValue(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit().foregroundStyle(color)
        }
    }

    private func rememberWindows() {
        var unique: [String: HistoryWindowOption] = [:]
        for (source, windows) in history.liveWindows {
            for window in windows {
                unique[source.rawValue + ":" + window.id] = HistoryWindowOption(provider: source, id: window.id,
                                                                              name: window.name, duration: window.durationSeconds)
            }
        }
        for record in history.records {
            let option = HistoryWindowOption(provider: record.provider, id: record.windowID,
                                             name: record.windowName, duration: record.durationSeconds)
            unique[record.provider.rawValue + ":" + record.windowID] = option
        }
        for record in history.resetHistory {
            let option = HistoryWindowOption(provider: record.provider, id: record.windowID,
                                             name: record.windowName, duration: record.durationSeconds)
            unique[record.provider.rawValue + ":" + record.windowID] = option
        }
        var next = knownWindows
        for option in unique.values {
            if let index = next.firstIndex(where: { $0.provider == option.provider && $0.id == option.id }) {
                next[index] = option
            } else { next.append(option) }
        }
        if next != knownWindows { knownWindows = next }
    }

    private func rebuildSeries() {
        renderGeneration += 1
        let generation = renderGeneration
        renderTask?.cancel()
        let source = history.records
        let resets = history.resetHistory
        let current = currentAnnualObservation
        let selectedProvider = provider
        let selectedWindow = effectiveWindowID
        let selectedRange = range
        let selectedScale = scale
        renderTask = Task {
            let output = await Task.detached(priority: .userInitiated) {
                let records = source.filter {
                    $0.provider == selectedProvider && $0.windowID == selectedWindow
                        && $0.intervalStart < selectedRange.end && $0.intervalEnd > selectedRange.start
                }.sorted { $0.intervalStart < $1.intervalStart }
                let annual = selectedScale == .year
                    ? HistoryAnnualUsage.weeks(resetHistory: resets, provider: selectedProvider,
                                               windowID: selectedWindow, range: selectedRange,
                                               currentUsedPercent: current.used, currentObservedAt: current.observedAt)
                    : []
                return (records, HistoryPlot(records: records, range: selectedRange, scale: selectedScale), annual)
            }.value
            guard !Task.isCancelled, generation == renderGeneration else { return }
            displayedRecords = output.0
            cachedPlot = output.1
            cachedAnnualWeeks = output.2
        }
    }

    private func refreshVisibleRange() {
        guard range.start < latestDate else { return }
        history.refresh(range: DateInterval(start: range.start, end: min(range.end, latestDate)),
                        aggregationSeconds: scale.aggregationSeconds)
    }

    private func inspect(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, plot: HistoryPlot) {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { return }
        pinnedReset = nil
        if showsResetMarkers && location.y >= frame.maxY - 25,
           let event = visibleEvents.min(by: { abs($0.observedAt.timeIntervalSince(date)) < abs($1.observedAt.timeIntervalSince(date)) }),
           let position = proxy.position(forX: event.observedAt), abs(position - (location.x - frame.minX)) <= 9 {
            selectedEventID = event.id
            selectedID = nil
            return
        }
        selectedEventID = nil
        guard let point = plot.points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return }
        selectedID = point.record.id
    }

    private func inspectAnnual(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { return }
        pinnedReset = nil
        selectedID = nil
        if showsResetMarkers && location.y >= frame.maxY - 25,
           let event = visibleEvents.min(by: { abs($0.observedAt.timeIntervalSince(date)) < abs($1.observedAt.timeIntervalSince(date)) }),
           let position = proxy.position(forX: event.observedAt), abs(position - (location.x - frame.minX)) <= 9 {
            selectedEventID = event.id
            return
        }
        selectedEventID = nil
        selectedWeekID = annualWeeks.first { date >= $0.weekStart && date < $0.weekEnd }?.id
    }

    private func eventInspection(_ event: HistoryPlot.Event) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(eventTitle(event)).font(.system(size: 13, weight: .medium)).foregroundStyle(eventColor(event))
                Text(WidgetDateFormatter.reset(event.observedAt)).font(.system(size: 12)).monospacedDigit()
                Spacer()
                Text("\(percent(event.primary.previousUsedPercent)) → \(percent(event.primary.usedPercent))")
                    .font(.system(size: 17, weight: .medium)).monospacedDigit().foregroundStyle(eventColor(event))
                Button { showingEventDetails = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("查看此次观测的全部重置信息")
                    .accessibilityLabel("查看此次观测的全部重置信息")
                    .popover(isPresented: $showingEventDetails, arrowEdge: .top) { eventDetails(event) }
            }
            Text("观测区间 \(WidgetDateFormatter.reset(event.primary.previousObservedAt)) – \(WidgetDateFormatter.reset(event.observedAt))")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("重置历史").font(.system(size: 16, weight: .semibold))
                Text("\(history.resetHistory.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if history.isLoadingResetHistory { ProgressView().controlSize(.small) }
                Button { showingEventList = false } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭重置历史")
            }
            if history.resetHistory.isEmpty && !history.isLoadingResetHistory {
                Text("暂无重置记录").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(history.resetHistory.sorted { $0.observedAt > $1.observedAt }) { record in
                            Button { selectReset(record) } label: {
                                HStack(alignment: .center, spacing: 8) {
                                    ProviderBrandIcon(brand: record.provider == .codex ? .codex : .claude)
                                        .frame(width: 18, height: 18)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(resetHistoryDate(record.observedAt)).font(.system(size: 12)).monospacedDigit()
                                            Spacer(minLength: 4)
                                            Text("重置前 \(percent(record.previousUsedPercent))")
                                                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Color.websitePurple)
                                        }
                                        Text("\(record.provider.name) · \(record.windowName)")
                                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(record.provider.name)，\(resetHistoryDate(record.observedAt))，重置前使用 \(percent(record.previousUsedPercent))")
                            .accessibilityHint("定位到这次重置")
                        }
                    }
                }
            }
        }.padding(16).frame(width: 340, height: 320)
    }

    private func selectReset(_ record: HistoryResetRecord) {
        latestDate = Date()
        let span = range.duration
        let firstEnd = min(latestDate, earliestDate.addingTimeInterval(span))
        provider = record.provider
        windowID = record.windowID
        pinnedReset = record
        selectedEventID = record.id
        selectedID = nil
        followsPresent = false
        referenceDate = min(latestDate, max(firstEnd, record.observedAt.addingTimeInterval(span / 2)))
        showingEventList = false
    }

    private func prepareSelectionForViewChange() {
        selectedID = nil
        selectedWeekID = nil
        if let record = pinnedReset, record.provider == provider, record.windowID == effectiveWindowID,
           record.observedAt >= range.start, record.observedAt <= range.end {
            selectedEventID = record.id
        } else {
            pinnedReset = nil
            selectedEventID = nil
        }
    }

    private func resetEvent(_ record: HistoryResetRecord) -> HistoryPlot.Event {
        HistoryPlot.Event(events: [HistoryResetEvent(id: record.id, kind: .usageDrop,
            observedAt: record.observedAt, previousObservedAt: record.previousObservedAt,
            previousUsedPercent: record.previousUsedPercent, usedPercent: record.usedPercent,
            previousResetsAt: record.previousResetsAt, resetsAt: record.resetsAt)])
    }

    private func resetHistoryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func eventDetails(_ event: HistoryPlot.Event) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(eventTitle(event)).font(.system(size: 17, weight: .semibold)).foregroundStyle(eventColor(event))
                Spacer()
                Button { showingEventDetails = false } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭重置信息")
            }
            Text(provider == .codex ? "Codex · \(windowOptions.first(where: { $0.id == effectiveWindowID })?.title ?? "额度")" : "Claude · \(windowOptions.first(where: { $0.id == effectiveWindowID })?.title ?? "额度")")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(percent(event.primary.previousUsedPercent)).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.system(size: 14))
                Text(percent(event.primary.usedPercent)).foregroundStyle(eventColor(event))
            }.font(.system(size: 26, weight: .medium)).monospacedDigit()
            Divider().opacity(0.45)
            eventDetailRow("前次观测", value: WidgetDateFormatter.reset(event.primary.previousObservedAt))
            eventDetailRow("此次观测", value: WidgetDateFormatter.reset(event.observedAt))
            eventDetailRow("原计划重置", value: event.primary.previousResetsAt.map { WidgetDateFormatter.reset($0) } ?? "待定")
            eventDetailRow("新计划重置", value: event.primary.resetsAt.map { WidgetDateFormatter.reset($0) } ?? "待定")
            Text(event.events.map { eventKindTitle($0.kind) }.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(eventColor(event))
            Text(event.hasRecovery
                ? "恢复发生于两次观测之间。"
                : "计划信息，尚未确认额度恢复。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 350)
    }

    private func eventDetailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 13))
    }

    private func eventColor(_ event: HistoryPlot.Event) -> Color {
        event.hasRecovery ? .websitePurple : (event.primary.kind == .deadlineChanged ? .timeBlue : .secondary)
    }
    private func eventTitle(_ event: HistoryPlot.Event) -> String {
        if event.hasRecovery { return event.primary.isEarlyRecovery ? "提前额度恢复" : "额度恢复" }
        return event.primary.kind == .deadlineChanged ? "重置计划更新" : "计划重置已到期"
    }
    private func eventKindTitle(_ kind: HistoryResetEvent.Kind) -> String {
        switch kind {
        case .usageDrop: return "已使用比例下降"
        case .deadlineChanged: return "重置时间变化"
        case .priorDeadlinePassed: return "原计划已到期"
        }
    }
    private func eventSummary(_ event: HistoryPlot.Event) -> String {
        "\(WidgetDateFormatter.reset(event.observedAt))，\(percent(event.primary.previousUsedPercent)) 至 \(percent(event.primary.usedPercent))；\(event.events.map { eventKindTitle($0.kind) }.joined(separator: "、"))"
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func recordDetail(_ record: UsageHistoryRecord) -> String {
        "峰值 \(WidgetDateFormatter.reset(record.peakObservedAt ?? record.firstObservedAt)) · 末次 \(WidgetDateFormatter.reset(record.lastObservedAt))"
    }

}

private struct HistoryWindowOption: Identifiable, Equatable {
    let provider: HistoryProvider
    let id: String
    let name: String
    let duration: TimeInterval?
    var title: String {
        if !name.isEmpty { return name.replacingOccurrences(of: "5小时", with: "5 小时") }
        if let duration {
            if abs(duration - 5 * 3600) < 60 { return "5 小时额度" }
            if abs(duration - 7 * 86400) < 60 { return "每周额度" }
        }
        return name
    }
}

enum HistoryTimeScale: String, CaseIterable, Identifiable {
    case day, week, month, year
    var id: Self { self }
    var title: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        }
    }
    func range(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        switch self {
        case .day: return DateInterval(start: date.addingTimeInterval(-24 * 3600), end: date)
        case .week: return DateInterval(start: date.addingTimeInterval(-7 * 86400), end: date)
        case .month: return DateInterval(start: calendar.date(byAdding: .month, value: -1, to: date) ?? date.addingTimeInterval(-30 * 86400), end: date)
        case .year: return DateInterval(start: calendar.date(byAdding: .year, value: -1, to: date) ?? date.addingTimeInterval(-365 * 86400), end: date)
        }
    }
    func moved(_ date: Date, by count: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let component: Calendar.Component
        switch self {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return calendar.date(byAdding: component, value: count, to: date) ?? date
    }
    func rangeTitle(_ range: DateInterval) -> String {
        let pattern = self == .year || self == .month ? "yyyy/MM/dd HH:mm" : "MM/dd HH:mm"
        return format(range.start, pattern) + " – " + format(range.end, pattern)
    }
    func axisLabel(_ date: Date) -> String {
        switch self {
        case .day: return format(date, "HH:mm")
        case .week, .month: return format(date, "M/d")
        case .year: return format(date, "M 月")
        }
    }
    var aggregationSeconds: TimeInterval? {
        switch self {
        case .day: return nil
        case .week: return 3600
        case .month: return 6 * 3600
        case .year: return 86400
        }
    }
    func aggregationCaption(interval: Int) -> String {
        switch self {
        case .day: return "记录区间峰值"
        case .week: return "按小时取峰值"
        case .month: return "每 6 小时取峰值"
        case .year: return "每周累计"
        }
    }
    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

struct HistoryPlot {
    struct Event: Identifiable {
        var id: UUID { primary.id }
        let events: [HistoryResetEvent]
        var primary: HistoryResetEvent { events.first(where: { $0.kind == .usageDrop }) ?? events.first(where: { $0.kind == .deadlineChanged }) ?? events[0] }
        var observedAt: Date { primary.observedAt }
        var hasRecovery: Bool { events.contains { $0.kind == .usageDrop } }
    }
    struct Point: Identifiable {
        var id: UUID { record.id }
        let date: Date
        let record: UsageHistoryRecord
        let segment: Int
        var isIsolated = false
    }
    let points: [Point]
    let recoveries: [HistoryResetEvent]
    let events: [Event]
    static var empty: HistoryPlot { HistoryPlot(records: [], range: DateInterval(start: .distantPast, duration: 1), scale: .day) }

    init(records: [UsageHistoryRecord], range: DateInterval, scale: HistoryTimeScale) {
        var output: [Point] = []
        var segment = 0
        var prior: UsageHistoryRecord?
        var grouped: [Int: [Point]] = [:]
        for record in records.sorted(by: { $0.intervalStart < $1.intervalStart }) {
            guard record.peakUsedPercent.isFinite, (0...100).contains(record.peakUsedPercent),
                  record.intervalStart < range.end, record.intervalEnd > range.start else { continue }
            if let prior {
                let missingInterval = record.intervalStart.timeIntervalSince(prior.intervalEnd) > 1
                let expectedGap = max(5 * 60, Double(max(prior.intervalMinutes, record.intervalMinutes)) * 60 * 1.5)
                let missingObservations = record.firstObservedAt.timeIntervalSince(prior.lastObservedAt) > expectedGap
                let overlappingIntervals = record.intervalStart < prior.intervalEnd.addingTimeInterval(-1)
                let reversedObservations = record.firstObservedAt < prior.lastObservedAt
                let previousPeak = prior.peakObservedAt ?? prior.firstObservedAt
                let currentPeak = record.peakObservedAt ?? record.firstObservedAt
                let recoveryBetweenPeaks = (prior.resetEvents + record.resetEvents).contains {
                    $0.kind == .usageDrop && $0.observedAt > previousPeak && $0.observedAt <= currentPeak
                }
                if missingInterval || missingObservations || overlappingIntervals || reversedObservations || recoveryBetweenPeaks { segment += 1 }
            }
            let date = record.peakObservedAt ?? record.firstObservedAt
            if date >= range.start && date <= range.end {
                grouped[segment, default: []].append(Point(date: date, record: record, segment: segment))
            }
            prior = record
        }
        for key in grouped.keys.sorted() {
            let source = grouped[key]!
            let sampled: [Point]
            if let seconds = scale.aggregationSeconds {
                var bins: [Date: Point] = [:]
                for point in source {
                    let bin: Date
                    if scale == .year {
                        bin = Calendar.autoupdatingCurrent.startOfDay(for: point.date)
                    } else {
                        bin = range.start.addingTimeInterval(floor(point.date.timeIntervalSince(range.start) / seconds) * seconds)
                    }
                    if let current = bins[bin], current.record.peakUsedPercent >= point.record.peakUsedPercent { continue }
                    bins[bin] = point
                }
                sampled = bins.keys.sorted().compactMap { bins[$0] }
            } else { sampled = source }
            output += sampled.map { point in
                var value = point
                value.isIsolated = sampled.count == 1
                return value
            }
        }
        points = output
        var seen = Set<UUID>()
        let uniqueEvents = records.flatMap(\.resetEvents).filter { event in
            guard event.observedAt >= range.start, event.observedAt <= range.end,
                  seen.insert(event.id).inserted else { return false }
            return true
        }.sorted { $0.observedAt < $1.observedAt }
        recoveries = uniqueEvents.filter { $0.kind == .usageDrop }
        events = Dictionary(grouping: uniqueEvents, by: \.observedAt).map { Event(events: $0.value) }
            .sorted { $0.observedAt < $1.observedAt }
    }
}

/// Only the empty document spans the archive. The chart itself stays viewport-sized.
@MainActor
private struct HistoryScrollableChart<Content: View>: NSViewRepresentable {
    let earliest: Date
    let latest: Date
    let visibleDuration: TimeInterval
    let visibleEnd: Date
    let onVisibleEndChange: (Date) -> Void
    let content: Content

    func makeNSView(context: Context) -> HistoryChartScrollView<Content> {
        HistoryChartScrollView(content: content)
    }

    func updateNSView(_ view: HistoryChartScrollView<Content>, context: Context) {
        view.configure(content: content, earliest: earliest, latest: latest,
                       duration: visibleDuration, end: visibleEnd, onChange: onVisibleEndChange)
    }
}

@MainActor
private final class HistoryChartClipView: NSClipView {
}

@MainActor
private final class HistoryChartScrollView<Content: View>: NSScrollView {
    private let canvas = NSView()
    private let chart: NSHostingView<Content>
    private var earliest = Date()
    private var latest = Date()
    private var duration: TimeInterval = 86400
    private var visibleEnd = Date()
    private var pixelsPerSecond: CGFloat = 0
    private var isConfiguring = false
    private var onChange: (Date) -> Void = { _ in }

    init(content: Content) {
        chart = NSHostingView(rootView: content)
        super.init(frame: .zero)
        let clip = HistoryChartClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: clip)
        contentView = clip
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = true
        hasVerticalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        canvas.addSubview(chart)
        documentView = canvas
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func clipBoundsChanged(_ notification: Notification) { didScroll() }

    func configure(content: Content, earliest: Date, latest: Date, duration: TimeInterval,
                   end: Date, onChange: @escaping (Date) -> Void) {
        self.earliest = earliest
        self.latest = latest
        self.duration = max(1, duration)
        visibleEnd = min(end, latest)
        self.onChange = onChange
        chart.rootView = content
        arrangeViewport()
    }

    override func layout() {
        let wasConfiguring = isConfiguring
        isConfiguring = true
        super.layout()
        isConfiguring = wasConfiguring
        arrangeViewport()
    }

    private var start: Date { min(earliest, latest.addingTimeInterval(-duration)) }

    private func arrangeViewport() {
        guard !isConfiguring, contentView.bounds.width > 1, contentView.bounds.height > 1 else { return }
        isConfiguring = true
        defer { isConfiguring = false }
        let size = contentView.bounds.size
        pixelsPerSecond = size.width / duration
        let fullWidth = max(size.width, latest.timeIntervalSince(start) * pixelsPerSecond)
        let documentFrame = NSRect(x: 0, y: 0, width: fullWidth, height: size.height)
        if canvas.frame != documentFrame { canvas.frame = documentFrame }
        let offset = max(0, min(fullWidth - size.width,
                               visibleEnd.timeIntervalSince(start) * pixelsPerSecond - size.width))
        contentView.scroll(to: NSPoint(x: offset, y: 0))
        reflectScrolledClipView(contentView)
        positionChart()
    }

    private func positionChart() {
        let frame = NSRect(origin: NSPoint(x: contentView.bounds.minX, y: 0), size: contentView.bounds.size)
        if chart.frame != frame { chart.frame = frame }
    }

    private func didScroll() {
        guard !isConfiguring, pixelsPerSecond > 0 else { return }
        positionChart()
        let end = min(latest, start.addingTimeInterval((contentView.bounds.minX + contentView.bounds.width) / pixelsPerSecond))
        // Native clipping rounds programmatic offsets; a sub-point change is not a user pan.
        guard abs(end.timeIntervalSince(visibleEnd)) > max(0.05, 1 / Double(pixelsPerSecond)) else { return }
        visibleEnd = end
        onChange(end)
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > 0.01 {
            super.scrollWheel(with: event)
        } else if abs(event.scrollingDeltaY) > 0.01 {
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let maximum = max(0, canvas.bounds.width - contentView.bounds.width)
            let offset = max(0, min(maximum, contentView.bounds.minX - event.scrollingDeltaY * factor))
            contentView.scroll(to: NSPoint(x: offset, y: 0))
            reflectScrolledClipView(contentView)
        } else { super.scrollWheel(with: event) }
    }
}
