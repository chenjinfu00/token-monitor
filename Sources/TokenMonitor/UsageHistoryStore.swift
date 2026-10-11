import Foundation
import Combine

/// Bridges live quota observations to the local archive and the history window.
/// The service refresh cadence remains independent of the archive interval.
@MainActor
final class UsageHistoryStore: ObservableObject {
    @Published private(set) var records: [UsageHistoryRecord] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var interval: HistorySamplingInterval
    @Published private(set) var storageBytes: Int64 = 0
    @Published private(set) var firstRecordedAt: Date?
    @Published private(set) var revision = 0
    @Published private(set) var recordingEnabled: Bool

    private let directory: URL
    private var demoRecords: [UsageHistoryRecord]?
    private var recorder: UsageHistoryRecorder?
    private var timer: Timer?
    private var queryGeneration = 0
    private var archiveRevision = 0
    private var cachedRange: DateInterval?
    private var cachedArchiveRevision = -1
    private var cachedAggregation: TimeInterval?
    private var cachedArchive: [UsageHistoryRecord] = []
    private var queryTask: Task<Void, Never>?

    init(directory: URL? = nil,
         demo: Bool = false, demoRecords: [UsageHistoryRecord]? = nil) {
        let directory = directory ?? MonitorStore.dataDirectory.appendingPathComponent("History", isDirectory: true)
        self.directory = directory
        self.demoRecords = demoRecords ?? (demo ? [] : nil)
        interval = HistorySamplingInterval(rawValue: UserDefaults.standard.integer(forKey: "historySamplingMinutes")) ?? .fifteenMinutes
        recordingEnabled = UserDefaults.standard.object(forKey: "historyRecordingEnabled") as? Bool ?? true
        if let fixtures = self.demoRecords {
            firstRecordedAt = fixtures.map(\.firstObservedAt).min()
            return
        }
        do {
            recorder = try UsageHistoryRecorder(directory: directory, interval: interval)
            firstRecordedAt = recorder?.firstRecordedAt
            refreshStorageSize()
        } catch {
            errorMessage = "历史记录暂不可用：" + error.localizedDescription
        }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance(at: Date()) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func observe(provider: HistoryProvider, state: ProviderState, at now: Date) {
        guard recordingEnabled, demoRecords == nil, let capturedAt = state.updatedAt, let recorder else { return }
        let observations = state.windows.compactMap { window -> HistoryObservation? in
            guard let used = window.usedPercent else { return nil }
            return HistoryObservation(windowID: window.id, name: window.name,
                usedPercent: used, resetsAt: window.resetsAt, durationSeconds: window.durationSeconds)
        }
        guard !observations.isEmpty else { return }
        let previousIDs = Set(recorder.pendingRecords.map(\.id))
        do {
            try recorder.observe(provider: provider, observations: observations, capturedAt: capturedAt, now: now)
            firstRecordedAt = recorder.firstRecordedAt
            if !previousIDs.isSubset(of: Set(recorder.pendingRecords.map(\.id))) {
                archiveRevision += 1
                refreshStorageSize()
            }
            revision += 1
            errorMessage = nil
        } catch {
            errorMessage = "历史记录未保存：" + error.localizedDescription
        }
    }

    private func advance(at now: Date) {
        guard let recorder else { return }
        let pending = recorder.pendingRecords.map(\.id)
        do {
            try recorder.flush(at: now)
            if pending != recorder.pendingRecords.map(\.id) {
                archiveRevision += 1
                refreshStorageSize()
                revision += 1
            }
        } catch { errorMessage = "历史记录未保存：" + error.localizedDescription }
    }

    func refresh(range: DateInterval, aggregationSeconds: TimeInterval? = nil) {
        queryGeneration += 1
        let generation = queryGeneration
        queryTask?.cancel()
        if let demoRecords {
            records = demoRecords.filter { $0.firstObservedAt < range.end && $0.lastObservedAt >= range.start }
            isLoading = false
            return
        }
        let directory = directory
        let pending = recorder?.pendingRecords ?? []
        if let cachedRange, cachedRange.start <= range.start, cachedRange.end >= range.end,
           cachedArchiveRevision == archiveRevision, cachedAggregation == aggregationSeconds {
            apply(archived: cachedArchive, pending: pending, range: range)
            isLoading = false
            refreshStorageSize()
            return
        }
        let archiveVersion = archiveRevision
        let aggregation = aggregationSeconds
        let queryRange = DateInterval(start: max(Date(timeIntervalSince1970: 0), range.start.addingTimeInterval(-range.duration)),
            end: range.end.addingTimeInterval(range.duration))
        isLoading = true
        queryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            let outcome = await Task.detached(priority: .utility) {
                Result { try UsageHistoryRecorder.readForChart(directory: directory, range: queryRange, aggregationSeconds: aggregation) }
            }.value
            guard let self, self.queryGeneration == generation, !Task.isCancelled else { return }
            self.isLoading = false
            switch outcome {
            case .success(let archived):
                self.cachedRange = queryRange
                self.cachedAggregation = aggregation
                self.cachedArchiveRevision = archiveVersion
                self.cachedArchive = archived
                self.apply(archived: archived, pending: pending, range: range)
                self.refreshStorageSize()
            case .failure(let error):
                self.records = []
                self.errorMessage = "历史记录暂不可读：" + error.localizedDescription
            }
        }
    }

    private func apply(archived: [UsageHistoryRecord], pending: [UsageHistoryRecord], range: DateInterval) {
        var byID = Dictionary(archived.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for record in pending where record.firstObservedAt < range.end && record.lastObservedAt >= range.start {
            byID[record.id] = record
        }
        records = byID.values.sorted { $0.firstObservedAt < $1.firstObservedAt }
        if let first = records.map(\.firstObservedAt).min() {
            firstRecordedAt = firstRecordedAt.map { min($0, first) } ?? first
        }
    }

    func setInterval(_ value: HistorySamplingInterval) {
        guard value != interval else { return }
        do {
            try recorder?.setInterval(value, at: Date())
            archiveRevision += 1
            interval = value
            if demoRecords == nil { UserDefaults.standard.set(value.rawValue, forKey: "historySamplingMinutes") }
            errorMessage = nil
            refreshStorageSize()
            revision += 1
        } catch { errorMessage = "采样间隔未更改：" + error.localizedDescription }
    }

    func setRecordingEnabled(_ value: Bool) {
        guard value != recordingEnabled else { return }
        do {
            if !value { try recorder?.flush(at: Date(), force: true) }
            archiveRevision += 1
            recordingEnabled = value
            if demoRecords == nil { UserDefaults.standard.set(value, forKey: "historyRecordingEnabled") }
            errorMessage = nil
            refreshStorageSize()
            revision += 1
        } catch { errorMessage = "记录设置未更改：" + error.localizedDescription }
    }

    func removeHistory(before cutoff: Date) {
        queryGeneration += 1
        queryTask?.cancel()
        isLoading = false
        do {
            try recorder?.remove(before: cutoff, at: Date())
            if let fixtures = demoRecords {
                demoRecords = fixtures.filter { $0.intervalEnd > cutoff }
                firstRecordedAt = demoRecords?.map(\.firstObservedAt).min()
            } else { firstRecordedAt = recorder?.firstRecordedAt }
            archiveRevision += 1
            cachedArchive = []
            cachedRange = nil
            records = records.filter { $0.intervalEnd > cutoff }
            errorMessage = nil
            refreshStorageSize()
            revision += 1
        } catch {
            archiveRevision += 1
            cachedRange = nil
            cachedArchive = []
            refreshStorageSize()
            errorMessage = "清理未完成：" + error.localizedDescription
            revision += 1
        }
    }

    func clearHistory() {
        queryGeneration += 1
        queryTask?.cancel()
        isLoading = false
        do {
            try recorder?.clear(at: Date())
            if demoRecords != nil { demoRecords = [] }
            archiveRevision += 1
            cachedArchive = []
            cachedRange = nil
            records = []
            firstRecordedAt = nil
            isLoading = false
            errorMessage = nil
            refreshStorageSize()
            revision += 1
        } catch { errorMessage = "历史记录未删除：" + error.localizedDescription }
    }

    private func refreshStorageSize() {
        do { storageBytes = Int64(try recorder?.storageBytes() ?? 0) }
        catch { errorMessage = "无法读取记录大小：" + error.localizedDescription }
    }

    func closePanel() {
        queryGeneration += 1
        queryTask?.cancel()
        isLoading = false
        records = []
        cachedRange = nil
        cachedArchive = []
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queryTask?.cancel()
        do {
            try recorder?.flush(at: Date(), force: true)
            refreshStorageSize()
        } catch { errorMessage = "历史记录未保存：" + error.localizedDescription }
    }
}
