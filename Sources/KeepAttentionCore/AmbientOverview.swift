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
        classification: AmbientClassification = .notRequest
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
    }
}
