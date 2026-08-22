import Foundation

public enum AmbientAvailability: Equatable, Sendable {
    case available
    case unavailable
}

public enum AttentionQueueCollapsedContent: Equatable, Sendable {
    case request(title: String, detail: String, count: Int)
    case ambient(title: String, detail: String, count: Int)
}

public struct AttentionQueueProjection: Equatable, Sendable {
    public var collapsed: AttentionQueueCollapsedContent
    public var requestCount: Int
    public var queueHead: AttentionRequestCardProjection?
    public var queuePreviews: [AttentionRequestCardProjection]
    public var snoozed: [AttentionRequestCardProjection]
    public var staleHistory: [AttentionRequestCardProjection]
    public var ambient: [AmbientEntryProjection]
    public var ambientAvailabilityLabel: String?

    public init(
        collapsed: AttentionQueueCollapsedContent,
        requestCount: Int,
        queueHead: AttentionRequestCardProjection?,
        queuePreviews: [AttentionRequestCardProjection],
        snoozed: [AttentionRequestCardProjection],
        staleHistory: [AttentionRequestCardProjection],
        ambient: [AmbientEntryProjection],
        ambientAvailabilityLabel: String?
    ) {
        self.collapsed = collapsed
        self.requestCount = requestCount
        self.queueHead = queueHead
        self.queuePreviews = queuePreviews
        self.snoozed = snoozed
        self.staleHistory = staleHistory
        self.ambient = ambient
        self.ambientAvailabilityLabel = ambientAvailabilityLabel
    }

    public static func make(
        store: AttentionRequestStore,
        ambient: AmbientOverview,
        now: Date,
        aiSummariesEnabled: Bool,
        ambientAvailability: AmbientAvailability = .available,
        workspaceControls: WorkspaceControlsState = WorkspaceControlsState(),
        aiSummaryProviderAvailable: Bool = false
    ) -> AttentionQueueProjection {
        let queue = GlobalAttentionQueueSorter.sorted(store.activeRequests, now: now)
        let snoozed = store.activeRequests.filter { request in
            guard case let .snoozed(until) = request.status else { return false }
            return until > now
        }.sorted { $0.obligationStartedAt < $1.obligationStartedAt }
        let makeCard = { AttentionRequestCardProjection(request: $0, aiSummariesEnabled: aiSummariesEnabled) }
        let staleHistory = store.closedHistory.filter { $0.status == .stale }.map(makeCard)
        let ambientEntries = ambient.entries
            .sorted(by: Self.sessionOverviewPrecedes)
            .map {
                AmbientEntryProjection(
                    entry: $0,
                    workspaceControls: workspaceControls,
                    aiSummaryProviderAvailable: aiSummaryProviderAvailable,
                    now: now
                )
            }
        let ambientAvailabilityLabel = ambientAvailability == .unavailable ? "Orca unavailable" : nil
        if let head = queue.first {
            let card = makeCard(head)
            return AttentionQueueProjection(
                collapsed: .request(title: card.kindLabel, detail: card.needFromYou, count: queue.count),
                requestCount: queue.count,
                queueHead: card,
                queuePreviews: queue.dropFirst().prefix(3).map(makeCard),
                snoozed: snoozed.map(makeCard),
                staleHistory: staleHistory,
                ambient: ambientEntries,
                ambientAvailabilityLabel: ambientAvailabilityLabel
            )
        }

        let activeCount = ambient.entries.filter { $0.activity != .idle }.count
        let gapCount = ambient.entries.filter { $0.coverage == .coverageGap }.count
        let sessionLabel = ambient.entries.count == 1 ? "session" : "sessions"
        let collapsed: AttentionQueueCollapsedContent
        if ambientAvailability == .unavailable {
            collapsed = .ambient(
                title: "Orca unavailable",
                detail: "Session Overview is temporarily unavailable",
                count: 0
            )
        } else {
            collapsed = .ambient(
                title: "Session Overview · \(ambient.entries.count) \(sessionLabel)",
                detail: "\(activeCount) active · \(gapCount) coverage gaps",
                count: ambient.entries.count
            )
        }
        return AttentionQueueProjection(
            collapsed: collapsed,
            requestCount: 0,
            queueHead: nil,
            queuePreviews: [],
            snoozed: snoozed.map(makeCard),
            staleHistory: staleHistory,
            ambient: ambientEntries,
            ambientAvailabilityLabel: ambientAvailabilityLabel
        )
    }

    private static func sessionOverviewPrecedes(
        _ lhs: AmbientOverviewEntry,
        _ rhs: AmbientOverviewEntry
    ) -> Bool {
        let leftTier = sessionOverviewTier(lhs)
        let rightTier = sessionOverviewTier(rhs)
        if leftTier != rightTier { return leftTier < rightTier }
        let leftUpdated = lhs.session.updatedAt ?? lhs.lastOutputAt ?? .distantPast
        let rightUpdated = rhs.session.updatedAt ?? rhs.lastOutputAt ?? .distantPast
        if leftUpdated != rightUpdated { return leftUpdated > rightUpdated }
        let leftStable = stableSessionIdentity(lhs)
        let rightStable = stableSessionIdentity(rhs)
        if leftStable != rightStable { return leftStable < rightStable }
        return lhs.terminalHandle < rhs.terminalHandle
    }

    private static func sessionOverviewTier(_ entry: AmbientOverviewEntry) -> Int {
        if entry.connected == false { return 5 }
        if entry.coverage == .structuredAgent && entry.activity != .idle { return 0 }
        if entry.coverage == .structuredAgent && entry.session.summaryFingerprint != nil { return 1 }
        if entry.isFocused { return 2 }
        if entry.coverage == .coverageGap && entry.activity != .idle { return 3 }
        return 4
    }

    private static func stableSessionIdentity(_ entry: AmbientOverviewEntry) -> String {
        [
            AmbientEntryProjection.safeComponent(entry.repository) ?? "",
            AmbientEntryProjection.safeComponent(entry.branch) ?? "",
            entry.terminalHandle,
        ].joined(separator: "|")
    }
}

public struct AmbientEntryProjection: Codable, Equatable, Sendable {
    public var displayName: String
    public var activityLabel: String
    public var connectionLabel: String
    public var coverageLabel: String
    public var classificationLabel: String
    public var currentTask: String
    public var progress: String
    public var nextStep: String
    public var needsInput: String
    public var sourceConfidenceLabel: String
    public var updatedAt: Date?
    public var updatedTimeLabel: String
    public var summaryStatusLabel: String?
    public var workspaceID: String?
    public var showsAIOptInControl: Bool
    public var isAISummaryOptedIn: Bool

    public init(
        entry: AmbientOverviewEntry,
        workspaceControls: WorkspaceControlsState = WorkspaceControlsState(),
        aiSummaryProviderAvailable: Bool = false,
        now: Date = Date()
    ) {
        displayName = Self.safeDisplayName(repository: entry.repository, branch: entry.branch)
        switch entry.activity {
        case .busy: activityLabel = "Active"
        case .waitingForInput: activityLabel = "Waiting · not request"
        case .idle: activityLabel = "Idle"
        }
        connectionLabel = entry.connected == false ? "Disconnected" : "Connected"
        coverageLabel = entry.coverage.rawValue
        classificationLabel = entry.classification.rawValue
        currentTask = entry.session.currentTask
        progress = entry.session.progress
        nextStep = entry.session.nextStep
        needsInput = entry.session.needsInput
        sourceConfidenceLabel = entry.session.sourceConfidence
        updatedAt = entry.session.updatedAt
        updatedTimeLabel = Self.updatedTimeLabel(entry.session.updatedAt, now: now)
        summaryStatusLabel = entry.isSummaryLoading ? "AI summary loading" : nil
        workspaceID = Self.safeComponent(entry.repository)
        showsAIOptInControl = aiSummaryProviderAvailable
            && entry.coverage == .structuredAgent
            && workspaceID != nil
        isAISummaryOptedIn = workspaceID.map { workspaceControls.aiSummaryOptInWorkspaces.contains($0) } ?? false
    }

    private static func safeDisplayName(repository: String?, branch: String?) -> String {
        let safeRepository = safeComponent(repository)
        let safeBranch = safeComponent(branch)
        return switch (safeRepository, safeBranch) {
        case let (repository?, branch?): "\(repository) · \(branch)"
        case let (repository?, nil): repository
        default: "Workspace"
        }
    }

    static func safeComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\")
        else { return nil }
        return value
    }

    private static func updatedTimeLabel(_ date: Date?, now: Date) -> String {
        guard let date else { return "Updated time unknown" }
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 { return "Updated now" }
        if interval < 3_600 { return "Updated \(Int(interval / 60))m ago" }
        if interval < 86_400 { return "Updated \(Int(interval / 3_600))h ago" }
        return "Updated \(Int(interval / 86_400))d ago"
    }
}

public struct AttentionRequestEvidenceProjection: Codable, Equatable, Sendable {
    public var eventLabel: String
    public var observedAt: Date
    public var sourceLabel: String
    public var jumpReference: String

    fileprivate init(evidence: AttentionRequestEvidence) {
        eventLabel = Self.safeEventLabel(evidence.eventName)
        observedAt = evidence.observedAt
        sourceLabel = Self.safeSourceLabel(evidence.reference?.source)
        jumpReference = sourceLabel == "TraeX"
            ? "Open the matching request in TraeX"
            : "Open the matching request in Orca"
    }

    private static func safeEventLabel(_ eventName: String) -> String {
        switch eventName {
        case "PermissionRequest": "Permission requested"
        case "request_user_input": "Answer requested"
        case "needs-review": "Review requested"
        case "blocked-by-user": "User action requested"
        case "PostToolUseFailure": "Request is still waiting"
        case "StaleCleanup", "ObligationSuperseded": "State needs confirmation"
        default: "Structured lifecycle signal"
        }
    }

    private static func safeSourceLabel(_ source: String?) -> String {
        switch source?.lowercased() {
        case "traex": "TraeX"
        default: "Orca"
        }
    }
}

public struct AttentionRequestCardProjection: Equatable, Sendable {
    public var kindLabel: String
    public var objectLabel: String
    public var whyAttention: String
    public var needFromYou: String
    public var statusLabel: String
    public var summarySourceLabel: String
    public var usesStrongSignal: Bool
    public var evidence: [AttentionRequestEvidenceProjection]

    fileprivate init(request: AttentionRequest, aiSummariesEnabled: Bool) {
        evidence = request.evidence.map(AttentionRequestEvidenceProjection.init)
        usesStrongSignal = request.status == .unseen
            && (request.kind == .permissionRequired || request.kind == .userAnswerRequired)
        summarySourceLabel = aiSummariesEnabled
            ? "Structured lifecycle summary"
            : "Deterministic local fallback · AI disabled"
        switch request.status {
        case .unseen:
            statusLabel = "Unseen"
        case .seen:
            statusLabel = "Seen != Resolved"
        case .snoozed:
            statusLabel = "Snoozed"
        case .resolved:
            statusLabel = "Resolved"
        case .stale:
            statusLabel = "Stale = state needs confirmation"
        }
        switch request.kind {
        case .permissionRequired:
            kindLabel = "Permission required"
            objectLabel = "Permission"
            whyAttention = "A structured permission request is waiting."
            needFromYou = "Approve or deny in TraeX."
        case .userAnswerRequired:
            kindLabel = "Answer required"
            objectLabel = "Question"
            whyAttention = "A structured question is waiting for an answer."
            needFromYou = "Answer the question in TraeX."
        case .userActionRequired:
            kindLabel = "Action required"
            objectLabel = "Action"
            whyAttention = "A supervised workflow is blocked on you."
            needFromYou = "Complete the requested action in Orca."
        case .reviewRequired:
            kindLabel = "Review required"
            objectLabel = "Review"
            whyAttention = "A supervised workflow is ready for review."
            needFromYou = "Review the pending work in Orca."
        case .stateNeedsConfirmation:
            kindLabel = "State needs confirmation"
            objectLabel = "Confirmation"
            whyAttention = "The last known state may be out of date."
            needFromYou = "Confirm whether this request is still active."
        }
    }
}
