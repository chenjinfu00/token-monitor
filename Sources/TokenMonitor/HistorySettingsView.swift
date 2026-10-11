import SwiftUI

private typealias HistorySettingsState<Value> = SwiftUI.State<Value>

@MainActor
struct HistorySettingsView: View {
    @ObservedObject var history: UsageHistoryStore
    var onClose: () -> Void = {}
    @HistorySettingsState(initialValue: false) private var confirmingDeletion: Bool
    @HistorySettingsState(initialValue: Calendar.autoupdatingCurrent.startOfDay(for: Date())) private var cleanupDate: Date
    @AppStorage("history.showResetMarkers") private var showsResetMarkers = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 20, height: 20) }
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
            Toggle("图表显示重置信息", isOn: $showsResetMarkers).font(.system(size: 13))
            Divider().opacity(0.5)
            HStack {
                Text("记录占用").font(.system(size: 13))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: history.storageBytes, countStyle: .file))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            HStack {
                Text("清理此日期之前").font(.system(size: 13))
                Spacer(minLength: 4)
                DatePicker("清理此日期之前", selection: $cleanupDate, in: ...Date(), displayedComponents: [.date])
                    .labelsHidden().datePickerStyle(.compact).fixedSize()
            }
            Button(role: .destructive) { confirmingDeletion = true } label: {
                Label("删除此日期之前的记录", systemImage: "trash")
                    .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(history.storageBytes == 0 && history.firstRecordedAt == nil)
            if let error = history.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(Color.paceRed).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 320)
        .alert("清理 \(cleanupDateText) 之前的记录？", isPresented: $confirmingDeletion) {
            Button("取消", role: .cancel) { }
            Button("清理记录", role: .destructive) {
                history.removeHistory(before: Calendar.autoupdatingCurrent.startOfDay(for: cleanupDate))
            }
        } message: {
            Text("删除本地时间 \(cleanupDateText) 00:00 之前的完整记录。该日期及之后、跨界区间保留。无法恢复。")
        }
    }

    private var cleanupDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: cleanupDate)
    }
}
