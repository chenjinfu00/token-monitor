import SwiftUI
import Charts
import AppKit

// Avoid the Foundation State macro supplied by newer macOS SDKs.
private typealias HistoryViewState<Value> = SwiftUI.State<Value>

@MainActor
struct HistoryPanelView: View {
    @ObservedObject var history: UsageHistoryStore
    @HistoryViewState(initialValue: HistoryTimeScale.day) private var scale: HistoryTimeScale
    @HistoryViewState(initialValue: Date()) private var referenceDate: Date
    @HistoryViewState(initialValue: Date()) private var latestDate: Date
    @HistoryViewState(initialValue: true) private var followsPresent: Bool
    @HistoryViewState(initialValue: HistoryProvider.codex) private var provider: HistoryProvider
    @HistoryViewState(initialValue: "") private var windowID: String
    @HistoryViewState(initialValue: [HistoryWindowOption]()) private var knownWindows: [HistoryWindowOption]
    @HistoryViewState(initialValue: [UsageHistoryRecord]()) private var displayedRecords: [UsageHistoryRecord]
    @HistoryViewState(initialValue: HistoryPlot.empty) private var cachedPlot: HistoryPlot
    @HistoryViewState(initialValue: 0) private var renderGeneration: Int
    @HistoryViewState(initialValue: Optional<Task<Void, Never>>.none) private var renderTask: Task<Void, Never>?
    @HistoryViewState(initialValue: Optional<UUID>.none) private var selectedID: UUID?
    @HistoryViewState(initialValue: Optional<UUID>.none) private var selectedEventID: UUID?
    @HistoryViewState(initialValue: false) private var showingEventDetails: Bool
    @HistoryViewState(initialValue: false) private var showingEventList: Bool
    @HistoryViewState(initialValue: false) private var showingSettings: Bool
    @HistoryViewState(initialValue: false) private var confirmingDeletion: Bool
    @HistoryViewState(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: Date())) private var cleanupDate: Date
    @AppStorage("history.showResetMarkers") private var showsResetMarkers = true

    private var range: DateInterval { scale.range(containing: referenceDate) }
    private var accent: Color { provider == .codex ? .codexGreen : .claudeOrange }
    private var windowOptions: [HistoryWindowOption] {
        knownWindows.filter { $0.provider == provider }.sorted { left, right in
            if left.duration != right.duration { return (left.duration ?? .greatestFiniteMagnitude) < (right.duration ?? .greatestFiniteMagnitude) }
            return left.id < right.id
        }
    }
    private var effectiveWindowID: String { windowOptions.contains(where: { $0.id == windowID }) ? windowID : (windowOptions.first?.id ?? "") }
    private var matchingRecords: [UsageHistoryRecord] { displayedRecords }
    private var selected: UsageHistoryRecord? {
        guard let selectedID else { return nil }
        return cachedPlot.points.first { $0.id == selectedID }?.record
    }
    private var visibleSelection: UsageHistoryRecord? { selected ?? cachedPlot.points.last?.record }
    private var selectedEvent: HistoryPlot.Event? {
        guard let selectedEventID else { return nil }
        return cachedPlot.events.first { $0.id == selectedEventID }
    }
    private var earliestDate: Date { history.firstRecordedAt ?? latestDate }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            filters
            dateNavigation
            chartArea
            inspection
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(minWidth: 640, minHeight: 440)
        .onAppear { rememberWindows(); rebuildSeries(); refreshVisibleRange() }
        .onDisappear { renderTask?.cancel() }
        .onChange(of: range) { _ in selectedID = nil; selectedEventID = nil; rebuildSeries(); refreshVisibleRange() }
        .onChange(of: provider) { _ in selectedID = nil; selectedEventID = nil; rebuildSeries() }
        .onChange(of: windowID) { _ in selectedID = nil; selectedEventID = nil; rebuildSeries() }
        .onChange(of: history.records) { _ in rememberWindows(); rebuildSeries() }
        .onChange(of: history.revision) { _ in
            latestDate = Date()
            if followsPresent { referenceDate = latestDate }
            refreshVisibleRange()
        }
        .alert("清理 \(cleanupDateText) 之前的记录？", isPresented: $confirmingDeletion) {
            Button("取消", role: .cancel) { }
            Button("清理记录", role: .destructive) {
                selectedID = nil
                selectedEventID = nil
                history.removeHistory(before: Calendar.autoupdatingCurrent.startOfDay(for: cleanupDate))
            }
        } message: {
            Text("只删除本地时间 \(cleanupDateText) 00:00 之前的完整记录区间。该日期及之后的记录、跨过此时间的区间均保留。删除后无法恢复。")
        }
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("额度历史").font(.system(size: 22, weight: .semibold))
                Text("已使用比例 · 每个记录区间保留峰值")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            if history.isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("正在读取历史记录")
            }
            Button { showingEventList = true } label: {
                Label("重置记录 \(cachedPlot.events.count)", systemImage: "list.bullet")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(cachedPlot.events.isEmpty)
            .help("查看当前额度窗口、当前时间范围内的每次重置观测")
            .accessibilityLabel("查看全部 \(cachedPlot.events.count) 次重置观测")
            .popover(isPresented: $showingEventList, arrowEdge: .bottom) { eventList }
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 17, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("历史记录设置").accessibilityLabel("历史记录设置")
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) { settings }
        }
    }

    private var filters: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                providerButton(.codex, brand: .codex, title: "Codex")
                providerButton(.claude, brand: .claude, title: "Claude")
            }
            Divider().frame(height: 18).opacity(0.45)
            Picker("额度窗口", selection: Binding(get: { effectiveWindowID }, set: { windowID = $0 })) {
                if windowOptions.isEmpty { Text("暂无额度窗口").tag("") }
                ForEach(windowOptions) { option in Text(option.title).tag(option.id) }
            }
            .labelsHidden().pickerStyle(.menu)
            .frame(minWidth: 90, maxWidth: 170, alignment: .leading)
            .disabled(windowOptions.isEmpty)
            .help("按独立额度窗口查看；不同窗口的百分比不合并")
            Spacer(minLength: 0)
        }
    }

    private func providerButton(_ value: HistoryProvider, brand: ProviderBrand, title: String) -> some View {
        Button { provider = value } label: {
            HStack(spacing: 6) {
                ProviderBrandIcon(brand: brand).frame(width: 21, height: 21)
                Text(title).font(.system(size: 14, weight: provider == value ? .semibold : .regular))
            }
            .foregroundStyle(provider == value ? Color.primary : Color.secondary)
            .opacity(provider == value ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (provider == value ? "，已选择" : ""))
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
                Button("现在") { followsPresent = true; latestDate = Date(); referenceDate = latestDate }
                    .buttonStyle(.plain).foregroundStyle(accent).font(.system(size: 13, weight: .medium))
                    .help("滚动到最新记录")
            }
        }
    }

    @ViewBuilder private var chartArea: some View {
        if history.firstRecordedAt == nil && history.records.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: history.recordingEnabled ? "chart.xyaxis.line" : "pause.circle")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                Text(history.recordingEnabled ? "这段时间还没有记录" : "记录已暂停")
                    .font(.system(size: 15, weight: .medium))
                Text(history.firstRecordedAt == nil
                    ? "从现在开始记录，首个区间会保留实时采样到的峰值。"
                    : "可切换日期或额度窗口。没有采样的时间保持空白。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 110)
            .accessibilityElement(children: .combine)
        } else {
            ZStack {
                HistoryScrollableChart(earliest: earliestDate, latest: latestDate,
                    visibleDuration: range.duration, visibleEnd: referenceDate, onVisibleEndChange: { end in
                        followsPresent = abs(end.timeIntervalSince(latestDate)) < 1
                        referenceDate = end
                    }, content: historyChart.padding(.top, 6))
                if matchingRecords.isEmpty && !history.isLoading {
                    Text("这段时间没有有效采样")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 110)
        }
    }

    private var historyChart: some View {
        let values = cachedPlot
        return Chart {
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
                ForEach(values.events) { event in
                    if scale == .fiveHours || scale == .day {
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
            }
        }
        .accessibilityLabel("\(provider == .codex ? "Codex" : "Claude") 已使用额度峰值图，纵轴百分之零至百分之一百")
        .accessibilityValue("显示 \(values.points.count) 个峰值点，最高 \(values.points.map { $0.record.peakUsedPercent }.max().map { percent($0) } ?? "待定")；移至折线查看记录详情")
        .help("鼠标移至折线查看峰值；点击底部菱形，查看每次额度恢复或重置计划的详细观测。")
    }

    private var inspection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Capsule().fill(accent).frame(width: 17, height: 2)
                    Text("区间峰值")
                }
                if showsResetMarkers {
                    HStack(spacing: 5) {
                        Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Color.websitePurple)
                        Text("额度恢复")
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Color.timeBlue)
                        Text("重置计划")
                    }
                }
                Spacer()
                Text(scale.aggregationCaption(interval: history.interval.rawValue))
                    .lineLimit(1).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider().opacity(0.4)
            if let event = selectedEvent {
                eventInspection(event)
            } else if let record = visibleSelection {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(WidgetDateFormatter.reset(record.intervalStart)) – \(WidgetDateFormatter.reset(record.intervalEnd))")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        Text("\(record.intervalMinutes) 分钟采样 · \(record.sampleCount) 次有效观测")
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
                Text("鼠标查看峰值；点击图表底部的菱形，可查看每次重置观测。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 53, alignment: .leading)
            }
        }
        .frame(minHeight: 91, alignment: .top)
    }

    private func inspectionValue(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .medium)).monospacedDigit().foregroundStyle(color)
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            if let error = history.errorMessage {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Color.paceYellow)
                Text(error).lineLimit(2)
            } else {
                Text("订阅额度百分比，非精确 token 数 · 空白处没有有效采样")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("历史记录设置").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { showingSettings = false } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭设置")
            }
            Toggle("记录用量历史", isOn: Binding(get: { history.recordingEnabled }, set: { history.setRecordingEnabled($0) }))
                .font(.system(size: 13))
            HStack {
                Text("记录间隔").font(.system(size: 13))
                Spacer()
                Picker("记录间隔", selection: Binding(get: { history.interval }, set: { history.setInterval($0) })) {
                    ForEach(HistorySamplingInterval.allCases, id: \.rawValue) { value in Text(value.label).tag(value) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 125)
            }
            Text("区间内保留有效观测的最高使用比例与末次比例。间隔变更只影响后续记录。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("图表显示重置信息", isOn: $showsResetMarkers).font(.system(size: 13))
            Divider().opacity(0.5)
            HStack {
                Text("本机记录占用").font(.system(size: 13))
                Spacer()
                Text(storageSize).font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            if let first = history.firstRecordedAt {
                Text("始于 \(WidgetDateFormatter.reset(first))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack {
                Text("清理此日期之前").font(.system(size: 13))
                Spacer(minLength: 4)
                DatePicker("清理此日期之前", selection: $cleanupDate, in: ...Date(), displayedComponents: [.date])
                    .labelsHidden().datePickerStyle(.compact).fixedSize()
            }
            Button(role: .destructive) {
                showingSettings = false
                confirmingDeletion = true
            } label: {
                Label("删除此日期之前的记录", systemImage: "trash")
                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(history.storageBytes == 0 && history.firstRecordedAt == nil)
        }
        .padding(20).frame(width: 320)
    }

    private var storageSize: String { ByteCountFormatter.string(fromByteCount: history.storageBytes, countStyle: .file) }
    private var cleanupDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: cleanupDate)
    }

    private func rememberWindows() {
        var unique: [String: HistoryWindowOption] = [:]
        for record in history.records {
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
                return (records, HistoryPlot(records: records, range: selectedRange, scale: selectedScale))
            }.value
            guard !Task.isCancelled, generation == renderGeneration else { return }
            displayedRecords = output.0
            cachedPlot = output.1
        }
    }

    private func refreshVisibleRange() {
        history.refresh(range: range, aggregationSeconds: scale.aggregationSeconds)
    }

    private func inspect(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy, plot: HistoryPlot) {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { return }
        if showsResetMarkers && location.y >= frame.maxY - 25,
           let event = plot.events.min(by: { abs($0.observedAt.timeIntervalSince(date)) < abs($1.observedAt.timeIntervalSince(date)) }),
           let position = proxy.position(forX: event.observedAt), abs(position - (location.x - frame.minX)) <= 9 {
            selectedEventID = event.id
            selectedID = nil
            return
        }
        selectedEventID = nil
        guard let point = plot.points.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return }
        selectedID = point.record.id
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
            Text(event.hasRecovery ? "额度恢复发生在前后观测之间；点击标记查看计划变化。" : "仅观察到计划信息变化，尚不能确认额度实际恢复。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("重置观测").font(.system(size: 16, weight: .semibold))
                Text("\(cachedPlot.events.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { showingEventList = false } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭重置记录列表")
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(cachedPlot.events.reversed())) { event in
                        Button {
                            selectedEventID = event.id
                            selectedID = nil
                            showingEventList = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(WidgetDateFormatter.reset(event.observedAt))
                                        .foregroundStyle(.secondary).font(.system(size: 12)).monospacedDigit()
                                    Spacer(minLength: 4)
                                    Text("\(percent(event.primary.previousUsedPercent)) → \(percent(event.primary.usedPercent))")
                                        .foregroundStyle(eventColor(event)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                                }
                                Text(eventTitle(event)).font(.system(size: 12, weight: .medium)).foregroundStyle(eventColor(event))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(selectedEventID == event.id ? eventColor(event).opacity(0.08) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(eventTitle(event) + "，" + eventSummary(event))
                        .accessibilityHint("选择后在图表下方查看详情")
                    }
                }
            }
            Text("当前窗口与时间范围 · 选择一条查看详情")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(16).frame(width: 320, height: 320)
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
                ? "这次刷新确认额度有所恢复。实际发生时间位于前后两次观测之间，无法精确到某一分钟。"
                : "重置计划来自服务端刷新结果；计划更新或到期本身不代表额度已经恢复。")
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
        let recoveries = record.resetEvents.filter { $0.kind == .usageDrop }
        if let recovery = recoveries.last {
            return "\(WidgetDateFormatter.reset(recovery.observedAt)) 观察到\(recovery.isEarlyRecovery ? "提前额度恢复" : "额度恢复")：\(percent(recovery.previousUsedPercent)) → \(percent(recovery.usedPercent))。峰值仍包含恢复前的观测。"
        }
        if let change = record.resetEvents.last {
            return "\(WidgetDateFormatter.reset(change.observedAt)) 观察到重置时间变化；仅记录服务端信息。末次观测 \(WidgetDateFormatter.reset(record.lastObservedAt))。"
        }
        return "末次观测 \(WidgetDateFormatter.reset(record.lastObservedAt)) · 重置时间为服务端计划时间，恢复情况以实际观测为准。"
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
    case fiveHours, day, week, month, year
    var id: Self { self }
    var title: String {
        switch self {
        case .fiveHours: return "5 小时"
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        }
    }
    func range(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> DateInterval {
        switch self {
        case .fiveHours: return DateInterval(start: date.addingTimeInterval(-5 * 3600), end: date)
        case .day: return DateInterval(start: date.addingTimeInterval(-24 * 3600), end: date)
        case .week: return DateInterval(start: date.addingTimeInterval(-7 * 86400), end: date)
        case .month: return DateInterval(start: calendar.date(byAdding: .month, value: -1, to: date) ?? date.addingTimeInterval(-30 * 86400), end: date)
        case .year: return DateInterval(start: calendar.date(byAdding: .year, value: -1, to: date) ?? date.addingTimeInterval(-365 * 86400), end: date)
        }
    }
    func moved(_ date: Date, by count: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        if self == .fiveHours { return date.addingTimeInterval(Double(count) * 5 * 3600) }
        let component: Calendar.Component
        switch self {
        case .fiveHours: component = .hour
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
        case .fiveHours, .day: return format(date, "HH:mm")
        case .week, .month: return format(date, "M/d")
        case .year: return format(date, "M 月")
        }
    }
    var aggregationSeconds: TimeInterval? {
        switch self {
        case .fiveHours: return nil
        case .day: return nil
        case .week: return 3600
        case .month: return 6 * 3600
        case .year: return 86400
        }
    }
    func aggregationCaption(interval: Int) -> String {
        switch self {
        case .fiveHours, .day: return "记录区间峰值"
        case .week: return "按小时取峰值"
        case .month: return "每 6 小时取峰值"
        case .year: return "每日取峰值"
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
                let missingObservations = record.firstObservedAt.timeIntervalSince(prior.lastObservedAt) > 5 * 60
                let overlappingIntervals = record.intervalStart < prior.intervalEnd.addingTimeInterval(-1)
                let reversedObservations = record.firstObservedAt < prior.lastObservedAt
                let recoveryInPrior = prior.resetEvents.contains { $0.kind == .usageDrop }
                let recoveryInCurrent = record.resetEvents.contains { $0.kind == .usageDrop }
                if missingInterval || missingObservations || overlappingIntervals || reversedObservations || recoveryInPrior || recoveryInCurrent { segment += 1 }
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
        guard abs(end.timeIntervalSince(visibleEnd)) > 0.05 else { return }
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
