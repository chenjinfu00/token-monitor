import Foundation

enum HistoryProvider: String, Codable, CaseIterable, Identifiable {
    case codex, claude
    var id: String { rawValue }
    var name: String { self == .codex ? "Codex" : "Claude" }
}

enum HistorySamplingInterval: Int, Codable, CaseIterable, Identifiable {
    case oneMinute = 1, fiveMinutes = 5, fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60
    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    var label: String { self == .oneHour ? "1 小时" : "\(rawValue) 分钟" }
}

/// Service-reported subscription quota only. No exact tokens, credentials, or prompts.
struct HistoryObservation: Equatable {
    let windowID: String
    let name: String
    let usedPercent: Double?
    let resetsAt: Date?
    let durationSeconds: TimeInterval?

    init(windowID: String, name: String, usedPercent: Double?, resetsAt: Date?, durationSeconds: TimeInterval? = nil) {
        self.windowID = windowID
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.durationSeconds = durationSeconds
    }
}

struct HistoryResetEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        /// A measured decrease suggesting replenishment: large, near-full, or associated with a schedule transition.
        case usageDrop
        /// A service-reported schedule changed. This alone does not prove quota was replenished.
        case deadlineChanged
        /// The prior deadline passed between observations. This alone does not prove a reset.
        case priorDeadlinePassed
    }
    let id: UUID
    let kind: Kind
    let observedAt: Date
    let previousObservedAt: Date
    let previousUsedPercent: Double
    let usedPercent: Double
    let previousResetsAt: Date?
    let resetsAt: Date?

    var isEarlyRecovery: Bool { kind == .usageDrop && previousResetsAt.map { observedAt < $0 } == true }
}

struct UsageHistoryRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let schemaVersion: Int
    let provider: HistoryProvider
    let windowID: String
    let windowName: String
    let intervalStart: Date
    let intervalEnd: Date
    let firstObservedAt: Date
    let lastObservedAt: Date
    let peakUsedPercent: Double
    let lastUsedPercent: Double
    let resetsAt: Date?
    let durationSeconds: TimeInterval?
    let resetEvents: [HistoryResetEvent]
    let sampleCount: Int
    let intervalMinutes: Int
    var peakObservedAt: Date? = nil

    /// Real observations define coverage; the interval boundaries must not imply continuous sampling.
    var observedSpan: DateInterval { DateInterval(start: firstObservedAt, end: lastObservedAt) }
}

/// One independently persisted observed replenishment, including the last usage before it.
struct HistoryResetRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let schemaVersion: Int
    let provider: HistoryProvider
    let windowID: String
    let windowName: String
    let observedAt: Date
    let previousObservedAt: Date
    let previousUsedPercent: Double
    let usedPercent: Double
    let previousResetsAt: Date?
    let resetsAt: Date?
    let durationSeconds: TimeInterval?

    init(id: UUID, schemaVersion: Int = 1, provider: HistoryProvider, windowID: String, windowName: String,
         observedAt: Date, previousObservedAt: Date, previousUsedPercent: Double, usedPercent: Double,
         previousResetsAt: Date?, resetsAt: Date?, durationSeconds: TimeInterval? = nil) {
        self.id = id; self.schemaVersion = schemaVersion; self.provider = provider
        self.windowID = windowID; self.windowName = windowName
        self.observedAt = observedAt; self.previousObservedAt = previousObservedAt
        self.previousUsedPercent = previousUsedPercent; self.usedPercent = usedPercent
        self.previousResetsAt = previousResetsAt; self.resetsAt = resetsAt; self.durationSeconds = durationSeconds
    }

    init(provider: HistoryProvider, windowID: String, windowName: String, event: HistoryResetEvent,
         durationSeconds: TimeInterval? = nil) {
        self.init(id: event.id, provider: provider, windowID: windowID, windowName: windowName,
            observedAt: event.observedAt, previousObservedAt: event.previousObservedAt,
            previousUsedPercent: event.previousUsedPercent, usedPercent: event.usedPercent,
            previousResetsAt: event.previousResetsAt, resetsAt: event.resetsAt, durationSeconds: durationSeconds)
    }

    var isEarlyRecovery: Bool { previousResetsAt.map { observedAt < $0 } == true }
}
