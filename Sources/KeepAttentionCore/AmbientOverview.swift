import Foundation

public enum AmbientClassification: String, Codable, Equatable, Sendable {
    case notRequest = "not request"
}

public enum AmbientCoverage: String, Codable, Equatable, Sendable {
    case structuredAgent = "structured agent"
    case coverageGap = "coverage gap"
}

public struct AmbientOverview: Equatable, Sendable {
    public var entries: [AmbientOverviewEntry]

    public init(entries: [AmbientOverviewEntry]) {
        self.entries = entries
    }
}

public struct SessionOverviewDisplay: Codable, Equatable, Sendable {
    public var currentTask: String
    public var progress: String
    public var nextStep: String
    public var needsInput: String
    public var sourceConfidence: String
    public var updatedAt: Date?
    public var summaryFingerprint: String?

    public init(
        currentTask: String,
        progress: String,
        nextStep: String,
        needsInput: String,
        sourceConfidence: String,
        updatedAt: Date?,
        summaryFingerprint: String?
    ) {
        self.currentTask = currentTask
        self.progress = progress
        self.nextStep = nextStep
        self.needsInput = needsInput
        self.sourceConfidence = sourceConfidence
        self.updatedAt = updatedAt
        self.summaryFingerprint = summaryFingerprint
    }

    static func coverageGap(updatedAt: Date?) -> SessionOverviewDisplay {
        SessionOverviewDisplay(
            currentTask: "Coverage gap",
            progress: "No structured agent matched this terminal.",
            nextStep: "Open the source terminal if you need details.",
            needsInput: "Unknown · not request",
            sourceConfidence: "coverage gap · not request",
            updatedAt: updatedAt,
            summaryFingerprint: nil
        )
    }
}

public struct SessionSummaryCacheEntry: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var display: SessionOverviewDisplay

    public init(fingerprint: String, display: SessionOverviewDisplay) {
        self.fingerprint = fingerprint
        self.display = display
    }
}

public struct AmbientOverviewEntry: Equatable, Sendable {
    public var terminalHandle: String
    public var worktreeID: String?
    public var repository: String?
    public var branch: String?
    public var title: String?
    public var connected: Bool?
    public var lastOutputAt: Date?
    public var isFocused: Bool
    public var activity: TerminalActivityStatus
    public var coverage: AmbientCoverage
    public var classification: AmbientClassification
    public var session: SessionOverviewDisplay
    public var summaryCacheKey: String?
    public var summaryContext: SummaryContext?
    public var isSummaryLoading: Bool

    public init(
        terminalHandle: String,
        worktreeID: String?,
        repository: String?,
        branch: String?,
        title: String?,
        connected: Bool?,
        lastOutputAt: Date?,
        isFocused: Bool,
        activity: TerminalActivityStatus,
        coverage: AmbientCoverage,
        classification: AmbientClassification = .notRequest,
        session: SessionOverviewDisplay? = nil,
        summaryCacheKey: String? = nil,
        summaryContext: SummaryContext? = nil,
        isSummaryLoading: Bool = false
    ) {
        self.terminalHandle = terminalHandle
        self.worktreeID = worktreeID
        self.repository = repository
        self.branch = branch
        self.title = title
        self.connected = connected
        self.lastOutputAt = lastOutputAt
        self.isFocused = isFocused
        self.activity = activity
        self.coverage = coverage
        self.classification = classification
        self.session = session ?? SessionOverviewDisplay.coverageGap(updatedAt: lastOutputAt)
        self.summaryCacheKey = summaryCacheKey
        self.summaryContext = summaryContext
        self.isSummaryLoading = isSummaryLoading
    }
}
