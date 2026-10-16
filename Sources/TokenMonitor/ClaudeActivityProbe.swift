import Foundation

// Only confirmed local lifecycle events are accepted. File/PID existence alone
// cannot mark a task active, and 120 seconds without new evidence goes idle.
final class ClaudeActivityProbe {
    private let homeDirectory: URL
    private let ownerIsAlive: (ClaudeActivityOwner) -> Bool
    private var totals: [String: Int] = [:]
    private var weightedTotals: [String: Double] = [:]
    private var baselineAt: Date? = nil

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         ownerIsAlive: @escaping (ClaudeActivityOwner) -> Bool = ClaudeActivityFiles.ownerIsAlive) {
        self.homeDirectory = homeDirectory; self.ownerIsAlive = ownerIsAlive
    }
    func reset() { totals = [:]; weightedTotals = [:]; baselineAt = nil }
    func read(at now: Date = Date()) -> ProviderActivityReading {
        let directory = ClaudeActivityFiles.directory(home: homeDirectory)
        var reading = ProviderActivityReading()
        // Hooks replace snapshots by atomic rename, which the directory watch
        // reports. Watching every session file would hold one descriptor each
        // and, as sessions accumulate, could exhaust the app's descriptor table.
        reading.watchedDirectories = [directory, directory.deletingLastPathComponent(),
            homeDirectory.appendingPathComponent(".claude", isDirectory: true)]
        let firstRead = baselineAt == nil
        if firstRead { baselineAt = now }
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "json" && ClaudeActivityFiles.validHash($0.deletingPathExtension().lastPathComponent) }
            .sorted { left, right in
                let a = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a == b ? left.lastPathComponent < right.lastPathComponent : a > b
            }.prefix(256)
        var seen = Set<String>()
        var pending = false, paused = false
        let time = now.timeIntervalSince1970
        for url in files {
            guard let snapshot = ClaudeActivityFiles.read(url),
                  snapshot.sessionHash == url.deletingPathExtension().lastPathComponent,
                  snapshot.owner.startedAt <= time + 2,
                  snapshot.createdAt <= time + 2, snapshot.capturedAt <= time + 2,
                  snapshot.heartbeatAt <= time + 2,
                  snapshot.tokenAt.map({ $0 <= time + 2 }) ?? true else { continue }
            let id = snapshot.sessionHash
            seen.insert(id)
            let old = totals[id], oldWeighted = weightedTotals[id]
            totals[id] = snapshot.totalTokens
            weightedTotals[id] = snapshot.weightedTokens
            let alive = ownerIsAlive(snapshot.owner)
            // A terminal hook is still evidence after its process has exited.
            // Never turn a dead process's active snapshot into a running task.
            if alive || snapshot.phase != .active {
                let eventAt = Date(timeIntervalSince1970: snapshot.capturedAt)
                if eventAt > (reading.lastTaskEventAt ?? .distantPast) { reading.lastTaskEventAt = eventAt }
            }
            guard alive else { continue }
            if snapshot.phase == .paused { paused = true }
            if (snapshot.phase == .active && snapshot.heartbeatAt < time - ClaudeActivityFiles.ttl)
                || snapshot.agents.values.contains(where: { $0.phase == .active && $0.at < time - ClaudeActivityFiles.ttl }) {
                pending = true
            }
            guard snapshot.capturedAt >= time - ClaudeActivityFiles.ttl else { continue }
            let createdSinceBaseline = snapshot.createdAt >= (baselineAt?.timeIntervalSince1970 ?? time)
            if !firstRead, let at = snapshot.tokenAt,
               at > (baselineAt?.timeIntervalSince1970 ?? time), at >= time - 30,
               let previous = old ?? (createdSinceBaseline ? 0 : nil), snapshot.totalTokens >= previous {
                let delta = snapshot.totalTokens - previous
                // A weighted comparison needs a weighted baseline from the same snapshot lineage.
                let previousWeighted = oldWeighted ?? (old == nil && createdSinceBaseline ? 0 : nil)
                let weightedDelta = previousWeighted.flatMap { base in snapshot.weightedTokens.map { $0 - base } }
                if delta <= 1_000_000_000, weightedDelta.map({ $0 >= 0 }) ?? true,
                   delta > 0 || (weightedDelta ?? 0) > 0 {
                    reading.tokenDeltas.append(ActivityTokenDelta(sessionID: id, at: Date(timeIntervalSince1970: at),
                        tokens: delta, weightedTokens: weightedDelta))
                }
            }
            if snapshot.phase == .active, snapshot.heartbeatAt >= time - ClaudeActivityFiles.ttl {
                reading.runningSessionIDs.insert(id)
            }
            for (agent, state) in snapshot.agents where state.phase == .active
                && state.at <= time + 2 && state.at >= time - ClaudeActivityFiles.ttl {
                reading.runningSessionIDs.insert(id + ":" + agent)
            }
        }
        totals = totals.filter { seen.contains($0.key) }
        weightedTotals = weightedTotals.filter { seen.contains($0.key) }
        if reading.runningSessionIDs.isEmpty {
            reading.isPaused = paused
            reading.statusNote = pending ? "任务状态待更新" : (paused ? "等待授权或输入" : nil)
        }
        return reading
    }
}
