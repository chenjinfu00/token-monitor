import Foundation

@main
struct HistoryChecks {
    static let base = Date(timeIntervalSince1970: floor(1_900_000_000 / 900) * 900)
    static let range = DateInterval(start: base.addingTimeInterval(-86_400), end: base.addingTimeInterval(86_400))

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("token-history-checks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func observation(_ used: Double?, id: String = "codex.primary", reset: Date? = nil) -> HistoryObservation {
        HistoryObservation(windowID: id, name: "5小时额度", usedPercent: used,
            resetsAt: reset ?? base.addingTimeInterval(18_000), durationSeconds: 18_000)
    }
    static func observe(_ recorder: UsageHistoryRecorder, _ used: Double?, seconds: Double,
                        provider: HistoryProvider = .codex, reset: Date? = nil) throws {
        let now = base.addingTimeInterval(seconds)
        try recorder.observe(provider: provider, observations: [observation(used, reset: reset)], capturedAt: now, now: now)
    }
    static func require(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func peakAndResetWithinOneInterval() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 80, seconds: 10)
        try observe(recorder, 90, seconds: 120)
        try observe(recorder, 5, seconds: 180)
        require(try UsageHistoryRecorder.read(directory: url, range: range).isEmpty, "Live polling must not write an incomplete quota interval")
        let resetBytes = try recorder.storageBytes()
        require(resetBytes > 0, "Observed resets are journaled immediately even before the interval boundary")
        let pending = recorder.pendingRecords[0]
        require(pending.peakUsedPercent == 90 && pending.lastUsedPercent == 5, "Keep interval peak and post-reset usage separately")
        require(pending.sampleCount == 3, "Count real observations")
        require(pending.peakObservedAt == base.addingTimeInterval(120), "Keep true peak timestamp before an intra-bucket reset")
        require(pending.resetEvents.count == 1 && pending.resetEvents[0].kind == .usageDrop, "Record measured quota recovery")
        require(pending.resetEvents[0].isEarlyRecovery, "Recovery before original deadline is early")
        require(pending.resetEvents[0].previousUsedPercent == 90 && pending.resetEvents[0].usedPercent == 5, "Keep recovery endpoints")
        let stableID = pending.id
        try recorder.flush(at: base.addingTimeInterval(899))
        require(try recorder.storageBytes() == resetBytes, "Flush before boundary writes no regular quota snapshot")
        try recorder.flush(at: base.addingTimeInterval(900))
        let rows = try UsageHistoryRecorder.read(directory: url, range: range)
        require(rows.count == 1 && rows[0].id == stableID && rows[0].peakUsedPercent == 90, "Persist exactly one interval row with stable ID")
        require(recorder.pendingRecords.isEmpty, "Completed rows leave pending memory")
        require(try recorder.storageBytes() > 0, "Archive size includes records and baseline")
    }

    static func freshSnapshotsAndProviders() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 20, seconds: 20)
        try observe(recorder, 99, seconds: 20)
        try observe(recorder, 30, seconds: 30, provider: .claude)
        let stale = base.addingTimeInterval(-400)
        try recorder.observe(provider: .claude, observations: [observation(100)], capturedAt: stale, now: base.addingTimeInterval(40))
        let future = base.addingTimeInterval(400)
        try recorder.observe(provider: .claude, observations: [observation(100)], capturedAt: future, now: base.addingTimeInterval(40))
        let invalid: [HistoryObservation] = [observation(nil, id: "missing"), observation(.nan, id: "nan"),
            observation(101, id: "too-high"), observation(-1, id: "negative"), observation(50, id: "expired", reset: base)]
        try recorder.observe(provider: .codex, observations: invalid, capturedAt: base.addingTimeInterval(40), now: base.addingTimeInterval(40))
        let rows = recorder.pendingRecords
        require(rows.count == 2, "Invalid, stale, expired, and future data are not samples")
        require(rows.first { $0.provider == .codex }!.sampleCount == 1, "Duplicate capturedAt must not inflate observation count")
        require(rows.first { $0.provider == .codex }!.peakUsedPercent == 20, "Duplicate old snapshot must not change peak")
        require(rows.first { $0.provider == .claude }!.lastUsedPercent == 30, "Providers have separate baseline/peak state")
    }

    static func restartRetainsRecoveryBaseline() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        var recorder: UsageHistoryRecorder? = try UsageHistoryRecorder(directory: url)
        try observe(recorder!, 95, seconds: 50)
        try recorder!.flush(at: base.addingTimeInterval(900))
        recorder = nil
        let reopened = try UsageHistoryRecorder(directory: url)
        require(reopened.firstRecordedAt == base.addingTimeInterval(50), "Recording start survives restart")
        try observe(reopened, 95, seconds: 50)
        require(reopened.pendingRecords.isEmpty, "Restart must not resample the same baseline")
        try observe(reopened, 2, seconds: 910)
        require(reopened.pendingRecords[0].resetEvents.first?.previousUsedPercent == 95, "Restart recovery connects observed baseline")
        try reopened.flush(at: base.addingTimeInterval(1800))
        require(try reopened.read(range: range).count == 2, "Restart does not duplicate existing archived interval")
    }

    static func deadlineMetadataIsNotConfirmedReset() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 20, seconds: 10, reset: base.addingTimeInterval(100))
        try observe(recorder, 22, seconds: 110, reset: base.addingTimeInterval(2000))
        let events = recorder.pendingRecords[0].resetEvents
        require(events.map(\.kind).contains(.deadlineChanged), "Store changed schedule")
        require(events.map(\.kind).contains(.priorDeadlinePassed), "Store previous deadline crossing")
        require(!events.map(\.kind).contains(.usageDrop), "A changed or elapsed deadline alone must not claim replenishment")
    }

    static func gapsAndIntervalChanges() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 30, seconds: 10)
        try observe(recorder, 35, seconds: 3700)
        require(try recorder.read(range: range).count == 2, "An hour asleep produces two observed buckets, not fake intermediate rows")
        try recorder.setInterval(.oneHour, at: base.addingTimeInterval(3750))
        require(recorder.pendingRecords.isEmpty, "Changing interval preserves and closes pending history")
        try observe(recorder, 40, seconds: 3760)
        let current = recorder.pendingRecords[0]
        require(current.intervalMinutes == 60 && current.intervalStart >= base.addingTimeInterval(3750), "New interval starts after explicit setting split")
        try recorder.flush(at: base.addingTimeInterval(3770), force: true)
        let rows = try recorder.read(range: range)
        require(rows.count == 3 && rows.last!.lastObservedAt == base.addingTimeInterval(3760), "Force flush keeps the final true snapshot")
        require(rows.last!.intervalEnd == base.addingTimeInterval(3770), "Partial interval ends at graceful stop")
    }

    static func corruptionAndTailRecovery() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 90, seconds: 10)
        try recorder.flush(at: base.addingTimeInterval(900))
        let archive = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        let writer = try FileHandle(forWritingTo: archive)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("broken line\n".utf8))
        try writer.write(contentsOf: Data(repeating: 65, count: 150_000))
        try writer.write(contentsOf: Data("\n{\"truncated\":".utf8))
        try writer.close()
        try Data("invalid checkpoint".utf8).write(to: url.appendingPathComponent("latest.json"))
        let recovered = try UsageHistoryRecorder(directory: url)
        try observe(recovered, 1, seconds: 910)
        require(recovered.pendingRecords[0].resetEvents.first?.previousUsedPercent == 90, "Bad checkpoint recovers last valid archive baseline")
        try recovered.flush(at: base.addingTimeInterval(1800))
        let rows = try recovered.read(range: range)
        require(rows.count == 2 && rows.last!.lastUsedPercent == 1, "Corrupt lines and an incomplete tail never discard subsequent valid history")
    }

    static func clearOnlyOwnedHistoryAndResetBaselines() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try Data("keep".utf8).write(to: url.appendingPathComponent("claude-quota.json"))
        try Data("keep".utf8).write(to: url.appendingPathComponent("usage-invalid.jsonl"))
        try observe(recorder, 90, seconds: 10)
        try recorder.flush(at: base.addingTimeInterval(900))
        try observe(recorder, 95, seconds: 910)
        try recorder.clear(at: base.addingTimeInterval(920))
        try recorder.flush(at: base.addingTimeInterval(1800), force: true)
        require(try recorder.storageBytes() == 0, "Deleted memory cannot reappear on a later flush")
        require(try recorder.read(range: range).isEmpty, "Clear removes old archived and pending rows")
        require(FileManager.default.fileExists(atPath: url.appendingPathComponent("claude-quota.json").path), "Clear never deletes neighboring quota snapshots")
        require(FileManager.default.fileExists(atPath: url.appendingPathComponent("usage-invalid.jsonl").path), "Clear uses a strict whitelist")
        require(recorder.firstRecordedAt == nil, "Clear resets initial recording timestamp")
        try observe(recorder, 1, seconds: 930)
        require(recorder.pendingRecords[0].resetEvents.isEmpty, "Clear also resets before/after recovery baseline")
    }

    static func legacyRecordsWithoutPeakTimeRemainReadable() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 40, seconds: 60)
        try recorder.flush(at: base.addingTimeInterval(900))
        let archive = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        let data = try Data(contentsOf: archive)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "peakObservedAt")
        var legacy = try JSONSerialization.data(withJSONObject: object)
        legacy.append(10)
        try legacy.write(to: archive)
        let rows = try UsageHistoryRecorder.read(directory: url, range: range)
        require(rows.count == 1 && rows[0].peakObservedAt == nil, "Older records decode when optional peak timestamp is absent")
        require(rows[0].firstObservedAt == base.addingTimeInterval(60), "Legacy charts can use a truthful first-observed fallback")
    }

    static func fixture(_ seconds: Double, used: Double, events: [HistoryResetEvent] = [],
                        provider: HistoryProvider = .codex, duration: Double = 60) -> UsageHistoryRecord {
        let start = base.addingTimeInterval(seconds)
        let observed = start.addingTimeInterval(1)
        return UsageHistoryRecord(id: UUID(), schemaVersion: 1, provider: provider,
            windowID: "primary", windowName: "5小时额度", intervalStart: start,
            intervalEnd: start.addingTimeInterval(duration), firstObservedAt: observed,
            lastObservedAt: observed, peakUsedPercent: used, lastUsedPercent: used,
            resetsAt: base.addingTimeInterval(18_000), durationSeconds: 18_000,
            resetEvents: events, sampleCount: 1, intervalMinutes: Int(duration / 60), peakObservedAt: observed)
    }

    static func writeFixtures(_ rows: [UsageHistoryRecord], directory: URL) throws {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        var handles: [String: FileHandle] = [:]
        defer { handles.values.forEach { try? $0.close() } }
        for row in rows {
            let filename = "usage-" + formatter.string(from: row.intervalStart) + ".jsonl"
            if handles[filename] == nil {
                let url = directory.appendingPathComponent(filename)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                handles[filename] = try FileHandle(forWritingTo: url)
            }
            var data = try encoder.encode(row)
            data.append(10)
            try handles[filename]!.write(contentsOf: data)
        }
    }

    static func streamingChartReductionKeepsIndependentSeriesAndTruePeaks() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = utc.startOfDay(for: base)
        let offset = start.timeIntervalSince(base)
        var rows: [UsageHistoryRecord] = []
        for minute in 0..<(3 * 1440) {
            for provider in HistoryProvider.allCases {
                rows.append(fixture(offset + Double(minute * 60), used: Double(minute % 100), provider: provider))
            }
        }
        try writeFixtures(rows, directory: url)
        let year = DateInterval(start: start, end: start.addingTimeInterval(365 * 86400))
        let summarized = try UsageHistoryRecorder.readForChart(directory: url, range: year, aggregationSeconds: 86400, calendar: utc)
        require(summarized.count == 6, "Thousands of one-minute rows reduce to three daily summaries per provider")
        require(summarized.allSatisfy { $0.peakUsedPercent == 99 && $0.sampleCount == 1440 }, "Streaming daily summaries retain peak and effective observation count")
        require(summarized.allSatisfy { $0.peakObservedAt != nil && $0.lastObservedAt > $0.firstObservedAt }, "Daily peak timestamp and true coverage are retained")
        let hour = DateInterval(start: start, end: start.addingTimeInterval(3600))
        let hourly = try UsageHistoryRecorder.readForChart(directory: url, range: hour, aggregationSeconds: 3600, calendar: utc)
        require(hourly.count == 2 && hourly.allSatisfy { $0.peakUsedPercent == 59 && $0.sampleCount == 60 }, "Hourly bins keep providers separate and preserve maxima")
        require(try UsageHistoryRecorder.readForChart(directory: url, range: hour, aggregationSeconds: nil).count == 120, "A nil chart interval returns unreduced five-hour/day data")
    }

    static func chartReductionPreservesEveryEventAndDiscontinuity() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        func event(_ kind: HistoryResetEvent.Kind, prior: Double, current: Double, before: Double, after: Double) -> HistoryResetEvent {
            HistoryResetEvent(id: UUID(), kind: kind, observedAt: base.addingTimeInterval(current + 1),
                previousObservedAt: base.addingTimeInterval(prior + 1), previousUsedPercent: before,
                usedPercent: after, previousResetsAt: base.addingTimeInterval(500), resetsAt: base.addingTimeInterval(2000))
        }
        let schedule = event(.deadlineChanged, prior: 60, current: 120, before: 10, after: 70)
        let passed = event(.priorDeadlinePassed, prior: 120, current: 180, before: 70, after: 75)
        let recovery = event(.usageDrop, prior: 540, current: 600, before: 80, after: 1)
        let rows = [fixture(60, used: 10), fixture(120, used: 70, events: [schedule]),
            fixture(180, used: 75, events: [passed]), fixture(540, used: 80),
            fixture(600, used: 1, events: [recovery]), fixture(660, used: 2)]
        try writeFixtures(rows, directory: url)
        let summarized = try UsageHistoryRecorder.readForChart(directory: url, range: range, aggregationSeconds: 3600)
        require(summarized.count == 4, "A true gap and recovery isolate summaries even in the same hour")
        let retained = Set(summarized.flatMap(\.resetEvents).map(\.id))
        require(retained == Set([schedule.id, passed.id, recovery.id]), "Aggregation never drops schedule, elapsed-deadline, or replenishment details")
        let first = summarized[0]
        require(first.sampleCount == 3 && first.peakUsedPercent == 75 && first.intervalEnd == base.addingTimeInterval(240), "A pre-gap summary never fabricates coverage over the outage")
        require(summarized[2].resetEvents.first?.kind == .usageDrop && summarized[2].sampleCount == 1, "Mixed/recovery rows remain isolated from both neighbors")
    }

    static func localDayAggregationRespectsDaylightSaving() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        let next = calendar.date(byAdding: .day, value: 1, to: day)!
        require(next.timeIntervalSince(day) == 25 * 3600, "Fixture covers the 25-hour autumn transition")
        var rows: [UsageHistoryRecord] = []
        for hour in 0..<26 {
            let start = day.addingTimeInterval(Double(hour * 3600))
            let last = start.addingTimeInterval(3599)
            rows.append(UsageHistoryRecord(id: UUID(), schemaVersion: 1, provider: .codex, windowID: "primary",
                windowName: "5小时额度", intervalStart: start, intervalEnd: start.addingTimeInterval(3600),
                firstObservedAt: start.addingTimeInterval(1), lastObservedAt: last,
                peakUsedPercent: Double(hour), lastUsedPercent: Double(hour), resetsAt: nil,
                durationSeconds: 18_000, resetEvents: [], sampleCount: 60, intervalMinutes: 60, peakObservedAt: last))
        }
        try writeFixtures(rows, directory: url)
        let summarized = try UsageHistoryRecorder.readForChart(directory: url,
            range: DateInterval(start: day, end: next.addingTimeInterval(3600)), aggregationSeconds: 86400, calendar: calendar)
        require(summarized.count == 2 && summarized[0].sampleCount == 1500 && summarized[0].peakUsedPercent == 24, "A local autumn day keeps all 25 hours in one daily bin")
        require(summarized[1].firstObservedAt >= next, "The following local day begins at its calendar boundary")
    }

    static func smallScheduledResetAndMultipleRecoveryDetails() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 2, seconds: 10, reset: base.addingTimeInterval(100))
        try observe(recorder, 1.8, seconds: 60, reset: base.addingTimeInterval(100))
        require(recorder.pendingRecords[0].resetEvents.isEmpty, "An unrelated 0.2-point correction does not infer replenishment")
        try observe(recorder, 0, seconds: 110, reset: base.addingTimeInterval(2000))
        try observe(recorder, 80, seconds: 170, reset: base.addingTimeInterval(2000))
        try observe(recorder, 1, seconds: 230, reset: base.addingTimeInterval(2000))
        let details = recorder.pendingRecords[0].resetEvents
        require(details.filter { $0.kind == .usageDrop }.count == 2, "Retain both small scheduled reset and large recovery in one sampling interval")
        require(details.first { $0.kind == .usageDrop }?.previousUsedPercent == 1.8, "Small reset retains its observed before/after percentages")
        try recorder.flush(at: base.addingTimeInterval(900))
        let reopened = try UsageHistoryRecorder(directory: url)
        let rows = try reopened.read(range: range)
        require(rows[0].resetEvents == details, "Every event and its precise observation metadata survive restart")
    }

    static func deleteBeforeDateKeepsCrossingIntervalAndNewPending() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        try observe(recorder, 80, seconds: 10)
        try recorder.flush(at: base.addingTimeInterval(900))
        try observe(recorder, 90, seconds: 910)
        try recorder.flush(at: base.addingTimeInterval(1800))
        try observe(recorder, 95, seconds: 1810)
        try recorder.remove(before: base.addingTimeInterval(1200), at: base.addingTimeInterval(1820))
        let rows = try recorder.read(range: range)
        require(rows.count == 2 && rows[0].intervalStart == base.addingTimeInterval(900), "Keep an entire interval crossing the selected date and newer pending history")
        require(recorder.firstRecordedAt == base.addingTimeInterval(910), "Earliest remaining observation includes a retained crossing interval")
        let reopened = try UsageHistoryRecorder(directory: url)
        try observe(reopened, 1, seconds: 1825)
        require(reopened.pendingRecords[0].resetEvents.isEmpty, "Checkpoint cannot use an observation before the deletion cutoff as a recovery baseline")
        try recorder.remove(before: base.addingTimeInterval(2700), at: base.addingTimeInterval(1820))
        try recorder.flush(at: base.addingTimeInterval(2800), force: true)
        require(try recorder.read(range: range).isEmpty, "Removed pending intervals cannot reappear during a later flush")
        let bytes = try recorder.storageBytes()
        require(recorder.firstRecordedAt == nil && bytes < 1024, "Removing eligible history leaves only a compact anti-revival cleanup marker")
    }

    static func deleteAcrossMonthsRebuildsRestartCheckpoint() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = (1...3).map { calendar.date(from: DateComponents(year: 2026, month: $0, day: 10))! }
        let rows = dates.enumerated().map { fixture($0.element.timeIntervalSince(base), used: Double(($0.offset + 1) * 30)) }
        try writeFixtures(rows, directory: url)
        let recorder = try UsageHistoryRecorder(directory: url)
        let cutoff = calendar.date(from: DateComponents(year: 2026, month: 2, day: 1))!
        try Data("keep".utf8).write(to: url.appendingPathComponent("claude-quota.json"))
        try recorder.remove(before: cutoff, at: dates[2].addingTimeInterval(10))
        let surviving = try recorder.read(range: DateInterval(start: dates[0], end: dates[2].addingTimeInterval(3600)))
        require(surviving.count == 2 && surviving[0].firstObservedAt == dates[1].addingTimeInterval(1), "Delete only older months and rebuild first-recorded date")
        require(FileManager.default.fileExists(atPath: url.appendingPathComponent("claude-quota.json").path), "Date deletion keeps neighboring non-history files")
        let reopened = try UsageHistoryRecorder(directory: url)
        require(reopened.firstRecordedAt == dates[1].addingTimeInterval(1), "Rebuilt earliest record persists across restart")
        let now = dates[2].addingTimeInterval(120)
        try reopened.observe(provider: .codex, observations: [HistoryObservation(windowID: "primary", name: "5小时额度", usedPercent: 1, resetsAt: now.addingTimeInterval(18_000))], capturedAt: now, now: now)
        require(reopened.pendingRecords[0].resetEvents.first?.previousUsedPercent == 90, "Restart recovery uses the newest surviving baseline")
    }

    static func dateDeletionSkipsCorruptLinesAndRefusesSymlinks() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        try writeFixtures([fixture(0, used: 30), fixture(960, used: 40)], directory: url)
        let archive = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" }!
        let writer = try FileHandle(forWritingTo: archive)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("broken line\n{unfinished:".utf8))
        try writer.close()
        let recorder = try UsageHistoryRecorder(directory: url)
        try recorder.remove(before: base.addingTimeInterval(900), at: base.addingTimeInterval(1000))
        require(try recorder.read(range: range).count == 1, "Atomic rewrite keeps valid newer data despite damaged lines and tail")
        let target = url.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let checkpoint = url.appendingPathComponent("latest.json")
        try FileManager.default.removeItem(at: checkpoint)
        try FileManager.default.createSymbolicLink(at: checkpoint, withDestinationURL: target)
        var rejected = false
        do { try recorder.remove(before: base.addingTimeInterval(1800), at: base.addingTimeInterval(1000)) }
        catch HistoryStorageError.symbolicLink { rejected = true }
        require(rejected, "A history symlink must be rejected before any deletion")
        require(try Data(contentsOf: target) == Data("keep".utf8), "Deletion never follows a symlink to another file")
        require(try UsageHistoryRecorder.read(directory: url, range: range).count == 1, "Rejected deletion leaves the archive intact")
    }

    static func immediateResetJournalSurvivesRestartWithoutQuotaFlush() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        var recorder: UsageHistoryRecorder? = try UsageHistoryRecorder(directory: url)
        try observe(recorder!, 95, seconds: 10)
        require(try recorder!.storageBytes() == 0, "Ordinary observations remain memory-only")
        try observe(recorder!, 1, seconds: 120)
        require(recorder!.resetRevision == 1, "A newly persisted reset changes only the reset revision")
        require(try UsageHistoryRecorder.read(directory: url, range: range).isEmpty, "An immediate reset never forces the regular quota interval to disk")
        recorder = nil
        let rows = try UsageHistoryRecorder.readResetHistory(directory: url)
        require(rows.count == 1 && rows[0].previousUsedPercent == 95 && rows[0].usedPercent == 1, "Before/after quota survives a restart before the 15-minute flush")
        require(rows[0].provider == .codex && rows[0].windowID == "codex.primary" && rows[0].previousObservedAt == base.addingTimeInterval(10), "Independent reset log retains its provider, window, and last real observation")
        let reopened = try UsageHistoryRecorder(directory: url)
        try observe(reopened, 1, seconds: 120)
        require(reopened.pendingRecords.isEmpty && reopened.resetRevision == 0, "Restored post-reset baseline deduplicates the same delivered snapshot")
        try observe(reopened, 3, seconds: 180, reset: base.addingTimeInterval(20_000))
        require(reopened.resetRevision == 0, "Schedule-only changes do not create independent reset rows")
        try observe(reopened, 0, seconds: 240, reset: base.addingTimeInterval(20_000))
        require(try reopened.readResetHistory().count == 2, "A later distinct replenishment has its own independent entry")
        let archive = try ResetHistoryArchive(directory: url)
        let duplicate = HistoryResetRecord(id: UUID(), provider: rows[0].provider, windowID: rows[0].windowID,
            windowName: rows[0].windowName, observedAt: rows[0].observedAt, previousObservedAt: rows[0].previousObservedAt,
            previousUsedPercent: rows[0].previousUsedPercent, usedPercent: rows[0].usedPercent,
            previousResetsAt: rows[0].previousResetsAt, resetsAt: rows[0].resetsAt, durationSeconds: rows[0].durationSeconds)
        require(try archive.append([duplicate]) == 0, "Retrying the same observed reset with a new UUID cannot duplicate it")
    }

    static func legacyResetRecord() -> UsageHistoryRecord {
        let first = HistoryResetEvent(id: UUID(), kind: .usageDrop, observedAt: base.addingTimeInterval(110),
            previousObservedAt: base.addingTimeInterval(10), previousUsedPercent: 95, usedPercent: 0,
            previousResetsAt: base.addingTimeInterval(100), resetsAt: base.addingTimeInterval(1000))
        let schedule = HistoryResetEvent(id: UUID(), kind: .deadlineChanged, observedAt: first.observedAt,
            previousObservedAt: first.previousObservedAt, previousUsedPercent: 95, usedPercent: 0,
            previousResetsAt: first.previousResetsAt, resetsAt: first.resetsAt)
        let second = HistoryResetEvent(id: UUID(), kind: .usageDrop, observedAt: base.addingTimeInterval(200),
            previousObservedAt: base.addingTimeInterval(180), previousUsedPercent: 80, usedPercent: 1,
            previousResetsAt: base.addingTimeInterval(1000), resetsAt: base.addingTimeInterval(1000))
        return UsageHistoryRecord(id: UUID(), schemaVersion: 1, provider: .claude, windowID: "five_hour", windowName: "5小时额度",
            intervalStart: base, intervalEnd: base.addingTimeInterval(900), firstObservedAt: base.addingTimeInterval(10),
            lastObservedAt: base.addingTimeInterval(200), peakUsedPercent: 95, lastUsedPercent: 1,
            resetsAt: second.resetsAt, durationSeconds: 18_000, resetEvents: [first, schedule, second],
            sampleCount: 4, intervalMinutes: 15, peakObservedAt: base.addingTimeInterval(10))
    }

    static func legacyResetMigrationIsCompleteAndIdempotent() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let legacy = legacyResetRecord()
        try writeFixtures([legacy], directory: url)
        let recorder = try UsageHistoryRecorder(directory: url)
        let bytesBefore = try recorder.storageBytes()
        let rows = try UsageHistoryRecorder.readResetHistory(directory: url)
        require(rows.count == 2 && Set(rows.map(\.id)) == Set(legacy.resetEvents.filter { $0.kind == .usageDrop }.map(\.id)), "Legacy migration saves every observed replenishment once and excludes schedule-only events")
        let bytesAfter = try recorder.storageBytes()
        require(bytesAfter > bytesBefore, "Storage size includes the independent reset archive and index")
        let repeated = try UsageHistoryRecorder.readResetHistory(directory: url)
        require(repeated == rows, "Opening reset history again does not duplicate legacy entries")
        require(try recorder.storageBytes() == bytesAfter, "Completed migration performs no repeated archive writes")
    }

    static func resetDateCleanupCannotReviveCrossingBucketEvents() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        try writeFixtures([legacyResetRecord()], directory: url)
        try Data("keep".utf8).write(to: url.appendingPathComponent("claude-quota.json"))
        let recorder = try UsageHistoryRecorder(directory: url)
        // Delete before ever opening/migrating the legacy reset journal.
        try recorder.remove(before: base.addingTimeInterval(150), at: base.addingTimeInterval(250))
        require(try recorder.read(range: range).count == 1, "A crossing regular interval is retained whole")
        let first = try recorder.readResetHistory()
        require(first.count == 1 && first[0].observedAt == base.addingTimeInterval(200), "Legacy migration respects date cleanup even though an old event remains inside a retained crossing bucket")
        try recorder.remove(before: base.addingTimeInterval(201), at: base.addingTimeInterval(250))
        let reopened = try UsageHistoryRecorder(directory: url)
        require(try reopened.readResetHistory().isEmpty, "Restart and repeated migration cannot resurrect removed independent reset events")
        try reopened.clear(at: base.addingTimeInterval(300))
        require(try reopened.storageBytes() == 0, "Clear includes reset monthly files and the reset index")
        require(FileManager.default.fileExists(atPath: url.appendingPathComponent("claude-quota.json").path), "Reset cleanup never deletes neighboring quota/auth sources")
        require(try UsageHistoryRecorder.readResetHistory(directory: url).isEmpty, "Cleared legacy events cannot be imported again")
    }

    static func monthlyArchiveAndRangeReads() throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try UsageHistoryRecorder(directory: url)
        let first = Date(timeIntervalSince1970: 1_798_761_600) // Fixture independent of host timezone.
        for index in 0..<3 {
            let now = first.addingTimeInterval(TimeInterval(index * 40 * 86400))
            try recorder.observe(provider: .codex, observations: [observation(Double(index * 10), reset: now.addingTimeInterval(18_000))], capturedAt: now, now: now)
            try recorder.flush(at: now.addingTimeInterval(900), force: true)
        }
        let all = try UsageHistoryRecorder.read(directory: url, range: DateInterval(start: first.addingTimeInterval(-3600), end: first.addingTimeInterval(100 * 86400)))
        require(all.count == 3, "Multi-month archive reads stream each relevant monthly file")
        let middle = first.addingTimeInterval(40 * 86400)
        let selected = try UsageHistoryRecorder.read(directory: url, range: DateInterval(start: middle, end: middle.addingTimeInterval(3600)))
        require(selected.count == 1 && selected[0].peakUsedPercent == 10, "Narrow range omits unrelated months")
    }

    static func main() throws {
        try peakAndResetWithinOneInterval()
        try freshSnapshotsAndProviders()
        try restartRetainsRecoveryBaseline()
        try deadlineMetadataIsNotConfirmedReset()
        try gapsAndIntervalChanges()
        try corruptionAndTailRecovery()
        try clearOnlyOwnedHistoryAndResetBaselines()
        try legacyRecordsWithoutPeakTimeRemainReadable()
        try streamingChartReductionKeepsIndependentSeriesAndTruePeaks()
        try chartReductionPreservesEveryEventAndDiscontinuity()
        try localDayAggregationRespectsDaylightSaving()
        try smallScheduledResetAndMultipleRecoveryDetails()
        try deleteBeforeDateKeepsCrossingIntervalAndNewPending()
        try deleteAcrossMonthsRebuildsRestartCheckpoint()
        try dateDeletionSkipsCorruptLinesAndRefusesSymlinks()
        try immediateResetJournalSurvivesRestartWithoutQuotaFlush()
        try legacyResetMigrationIsCompleteAndIdempotent()
        try resetDateCleanupCannotReviveCrossingBucketEvents()
        try monthlyArchiveAndRangeReads()
        print("19 quota-history persistence, peak, recovery, restart, gaps, settings, corruption and clear checks passed")
    }
}
