import Foundation

public enum AgentSessionKey: Codable, Equatable, Hashable, Sendable {
    case traeX(sessionID: String)
    case supervisedWorkflow(workflowID: String)
}

public enum AttentionRequestKey: Codable, Equatable, Hashable, Sendable {
    case traeXTool(sessionID: String, turnID: String, toolUseID: String)
    case supervisedWorkflow(workflowID: String, requestID: String)
}

public enum AttentionRequestKind: Codable, Equatable, Sendable {
    case permissionRequired
    case userAnswerRequired
    case userActionRequired
    case reviewRequired
    case stateNeedsConfirmation
}

public enum AttentionSourceConfidence: Int, Codable, Equatable, Sendable {
    case genericObservation
    case structuredHook
    case supervisedWorkflow
}

public enum AttentionRequestStatus: Codable, Equatable, Sendable {
    case unseen
    case seen
    case snoozed(until: Date)
    case resolved
    case stale
}

public struct EvidenceRef: Codable, Equatable, Sendable {
    public var source: String
    public var correlationLabel: String

    public init(source: String, correlationLabel: String) {
        self.source = source
        self.correlationLabel = correlationLabel
    }
}

public struct AttentionRequestEvidence: Codable, Equatable, Sendable {
    public var eventName: String
    public var observedAt: Date
    public var reference: EvidenceRef?

    public init(eventName: String, observedAt: Date, reference: EvidenceRef? = nil) {
        self.eventName = eventName
        self.observedAt = observedAt
        self.reference = reference
    }
}

public struct AttentionRequest: Codable, Equatable, Sendable {
    public var key: AttentionRequestKey
    public var sessionKey: AgentSessionKey
    public var kind: AttentionRequestKind
    public var status: AttentionRequestStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var obligationStartedAt: Date
    public var evidence: [AttentionRequestEvidence]
    public var sourceConfidence: AttentionSourceConfidence
    public var workspaceLastVisitedAt: Date?
    public var escalationCount: Int
    public var lastEscalatedAt: Date?

    public init(
        key: AttentionRequestKey,
        sessionKey: AgentSessionKey,
        kind: AttentionRequestKind,
        status: AttentionRequestStatus,
        createdAt: Date,
        updatedAt: Date,
        evidence: [AttentionRequestEvidence],
        sourceConfidence: AttentionSourceConfidence = .structuredHook,
        workspaceLastVisitedAt: Date? = nil,
        escalationCount: Int = 0,
        lastEscalatedAt: Date? = nil,
        obligationStartedAt: Date? = nil
    ) {
        self.key = key
        self.sessionKey = sessionKey
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.obligationStartedAt = obligationStartedAt ?? createdAt
        self.evidence = evidence
        self.sourceConfidence = sourceConfidence
        self.workspaceLastVisitedAt = workspaceLastVisitedAt
        self.escalationCount = escalationCount
        self.lastEscalatedAt = lastEscalatedAt
    }
}

public enum AttentionRequestEvent: Equatable, Sendable {
    case traeXPermissionRequested(
        sessionID: String,
        turnID: String,
        toolUseID: String,
        toolName: String,
        observedAt: Date
    )
    case traeXQuestionOpened(
        sessionID: String,
        turnID: String,
        toolUseID: String,
        observedAt: Date
    )
    case supervisedUserActionOpened(
        workflowID: String,
        requestID: String,
        requiresReview: Bool,
        observedAt: Date
    )
    case supervisedWorkflowContinued(
        workflowID: String,
        requestID: String,
        observedAt: Date
    )
    case traeXToolCompleted(
        sessionID: String,
        turnID: String,
        toolUseID: String,
        observedAt: Date
    )
    case traeXQuestionFailed(
        sessionID: String,
        turnID: String,
        toolUseID: String,
        observedAt: Date
    )
    case traeXQuestionAnswered(
        sessionID: String,
        turnID: String,
        toolUseID: String,
        observedAt: Date
    )
    case markSeen(key: AttentionRequestKey, observedAt: Date)
    case snooze(key: AttentionRequestKey, until: Date, observedAt: Date)
    case markStale(sessionKey: AgentSessionKey, observedAt: Date)
    case markStaleAfterRestart(observedAt: Date)
    case unclassifiedObserved(
        sessionID: String?,
        correlationID: String?,
        eventName: String,
        observedAt: Date
    )
}

public struct AttentionRequestStore: Sendable {
    public private(set) var activeRequests: [AttentionRequest]
    public private(set) var closedHistory: [AttentionRequest]

    public init() {
        activeRequests = []
        closedHistory = []
    }

    public init(snapshot: AttentionRequestPersistenceSnapshot, now: Date = Date()) {
        activeRequests = snapshot.activeRequests
        closedHistory = Self.retainedHistory(snapshot.closedHistory, now: now)
    }

    public func snapshot(now: Date = Date()) -> AttentionRequestPersistenceSnapshot {
        AttentionRequestPersistenceSnapshot(
            activeRequests: activeRequests,
            closedHistory: Self.retainedHistory(closedHistory, now: now)
        )
    }

    public mutating func apply(_ event: AttentionRequestEvent) {
        switch event {
        case let .traeXPermissionRequested(sessionID, turnID, toolUseID, _, observedAt):
            guard Self.hasCorrelation(sessionID, turnID, toolUseID) else { return }
            open(AttentionRequest(
                key: .traeXTool(sessionID: sessionID, turnID: turnID, toolUseID: toolUseID),
                sessionKey: .traeX(sessionID: sessionID),
                kind: .permissionRequired,
                status: .unseen,
                createdAt: observedAt,
                updatedAt: observedAt,
                evidence: [AttentionRequestEvidence(eventName: "PermissionRequest", observedAt: observedAt)]
            ))
        case let .traeXQuestionOpened(sessionID, turnID, toolUseID, observedAt):
            guard Self.hasCorrelation(sessionID, turnID, toolUseID) else { return }
            open(AttentionRequest(
                key: .traeXTool(sessionID: sessionID, turnID: turnID, toolUseID: toolUseID),
                sessionKey: .traeX(sessionID: sessionID),
                kind: .userAnswerRequired,
                status: .unseen,
                createdAt: observedAt,
                updatedAt: observedAt,
                evidence: [AttentionRequestEvidence(eventName: "request_user_input", observedAt: observedAt)]
            ))
        case let .supervisedUserActionOpened(workflowID, requestID, requiresReview, observedAt):
            guard Self.hasCorrelation(workflowID, requestID) else { return }
            open(AttentionRequest(
                key: .supervisedWorkflow(workflowID: workflowID, requestID: requestID),
                sessionKey: .supervisedWorkflow(workflowID: workflowID),
                kind: requiresReview ? .reviewRequired : .userActionRequired,
                status: .unseen,
                createdAt: observedAt,
                updatedAt: observedAt,
                evidence: [AttentionRequestEvidence(
                    eventName: requiresReview ? "needs-review" : "blocked-by-user",
                    observedAt: observedAt
                )]
            ))
        case let .supervisedWorkflowContinued(workflowID, requestID, observedAt):
            let key = AttentionRequestKey.supervisedWorkflow(
                workflowID: workflowID,
                requestID: requestID
            )
            guard let index = activeRequests.firstIndex(where: { $0.key == key }) else { return }
            var request = activeRequests.remove(at: index)
            request.status = .resolved
            request.updatedAt = observedAt
            request.evidence.append(AttentionRequestEvidence(eventName: "WorkflowContinued", observedAt: observedAt))
            insertClosed(request, now: observedAt)
        case let .traeXToolCompleted(sessionID, turnID, toolUseID, observedAt):
            resolveTraeXTool(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                observedAt: observedAt,
                requiredKind: .permissionRequired
            )
        case let .traeXQuestionFailed(sessionID, turnID, toolUseID, observedAt):
            let key = AttentionRequestKey.traeXTool(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID
            )
            guard let index = activeRequests.firstIndex(where: {
                $0.key == key && $0.kind == .userAnswerRequired
            }) else { return }
            activeRequests[index].updatedAt = observedAt
            activeRequests[index].evidence.append(AttentionRequestEvidence(
                eventName: "PostToolUseFailure",
                observedAt: observedAt
            ))
        case let .traeXQuestionAnswered(sessionID, turnID, toolUseID, observedAt):
            resolveTraeXTool(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                observedAt: observedAt,
                requiredKind: .userAnswerRequired
            )
        case let .markSeen(key, observedAt):
            guard let index = activeRequests.firstIndex(where: { $0.key == key }) else { return }
            activeRequests[index].status = .seen
            activeRequests[index].updatedAt = observedAt
        case let .snooze(key, until, observedAt):
            guard let index = activeRequests.firstIndex(where: { $0.key == key }) else { return }
            activeRequests[index].status = .snoozed(until: until)
            activeRequests[index].updatedAt = observedAt
        case let .markStale(sessionKey, observedAt):
            guard let index = activeRequests.firstIndex(where: { $0.sessionKey == sessionKey }) else { return }
            closeAsStale(at: index, observedAt: observedAt)
        case let .markStaleAfterRestart(observedAt):
            while !activeRequests.isEmpty {
                closeAsStale(at: 0, observedAt: observedAt)
            }
        case .unclassifiedObserved:
            return
        }
    }

    private mutating func closeAsStale(at index: Int, observedAt: Date) {
        var request = activeRequests.remove(at: index)
        request.status = .stale
        request.updatedAt = observedAt
        request.evidence.append(AttentionRequestEvidence(eventName: "StaleCleanup", observedAt: observedAt))
        insertClosed(request, now: observedAt)
    }

    private mutating func resolveTraeXTool(
        sessionID: String,
        turnID: String,
        toolUseID: String,
        observedAt: Date,
        requiredKind: AttentionRequestKind
    ) {
        let key = AttentionRequestKey.traeXTool(
            sessionID: sessionID,
            turnID: turnID,
            toolUseID: toolUseID
        )
        guard let index = activeRequests.firstIndex(where: {
            $0.key == key && $0.kind == requiredKind
        }) else { return }
        var request = activeRequests.remove(at: index)
        request.status = .resolved
        request.updatedAt = observedAt
        request.evidence.append(AttentionRequestEvidence(eventName: "PostToolUse", observedAt: observedAt))
        insertClosed(request, now: observedAt)
    }

    private mutating func insertClosed(_ request: AttentionRequest, now: Date) {
        closedHistory.insert(request, at: 0)
        closedHistory = Self.retainedHistory(closedHistory, now: now)
    }

    private mutating func open(_ request: AttentionRequest) {
        if let sameIndex = activeRequests.firstIndex(where: { $0.key == request.key }) {
            activeRequests[sameIndex].updatedAt = request.updatedAt
            activeRequests[sameIndex].evidence.append(contentsOf: request.evidence)
            return
        }
        if let index = activeRequests.firstIndex(where: { $0.sessionKey == request.sessionKey }) {
            var superseded = activeRequests.remove(at: index)
            superseded.status = .stale
            superseded.updatedAt = request.updatedAt
            superseded.evidence.append(AttentionRequestEvidence(
                eventName: "ObligationSuperseded",
                observedAt: request.updatedAt
            ))
            insertClosed(superseded, now: request.updatedAt)
        }
        activeRequests.append(request)
    }

    private static func retainedHistory(_ requests: [AttentionRequest], now: Date) -> [AttentionRequest] {
        requests
            .filter { now.timeIntervalSince($0.updatedAt) <= 24 * 60 * 60 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(50)
            .map { $0 }
    }

    private static func hasCorrelation(_ parts: String...) -> Bool {
        parts.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct AttentionRequestPersistenceSnapshot: Codable, Equatable, Sendable {
    public var activeRequests: [AttentionRequest]
    public var closedHistory: [AttentionRequest]

    public init(activeRequests: [AttentionRequest], closedHistory: [AttentionRequest]) {
        self.activeRequests = activeRequests
        self.closedHistory = closedHistory
    }
}

public enum GlobalAttentionQueueSorter {
    public static func sorted(_ requests: [AttentionRequest], now: Date) -> [AttentionRequest] {
        requests.filter { request in
            guard case let .snoozed(until) = request.status else { return true }
            return until <= now
        }.sorted { lhs, rhs in
            let left = blockingTier(lhs.kind)
            let right = blockingTier(rhs.kind)
            if left != right { return left < right }
            if lhs.obligationStartedAt != rhs.obligationStartedAt {
                return lhs.obligationStartedAt < rhs.obligationStartedAt
            }
            if statusTier(lhs.status) != statusTier(rhs.status) {
                return statusTier(lhs.status) < statusTier(rhs.status)
            }
            if lhs.sourceConfidence != rhs.sourceConfidence {
                return lhs.sourceConfidence.rawValue > rhs.sourceConfidence.rawValue
            }
            if lhs.workspaceLastVisitedAt != rhs.workspaceLastVisitedAt {
                return (lhs.workspaceLastVisitedAt ?? .distantPast) > (rhs.workspaceLastVisitedAt ?? .distantPast)
            }
            return stableKey(lhs.key) < stableKey(rhs.key)
        }
    }

    private static func blockingTier(_ kind: AttentionRequestKind) -> Int {
        switch kind {
        case .permissionRequired: 0
        case .userAnswerRequired: 1
        case .userActionRequired, .reviewRequired: 2
        case .stateNeedsConfirmation: 3
        }
    }

    private static func statusTier(_ status: AttentionRequestStatus) -> Int {
        switch status {
        case .unseen, .snoozed: 0
        case .seen: 1
        case .resolved, .stale: 2
        }
    }

    private static func stableKey(_ key: AttentionRequestKey) -> String {
        switch key {
        case let .traeXTool(sessionID, turnID, toolUseID):
            "traex:\(sessionID):\(turnID):\(toolUseID)"
        case let .supervisedWorkflow(workflowID, requestID):
            "supervised:\(workflowID):\(requestID)"
        }
    }
}
