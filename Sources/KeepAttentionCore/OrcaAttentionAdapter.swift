import Foundation

public enum OrcaSupervisedSignal: Equatable, Sendable {
    case blocked(workflowID: String, requestID: String)
    case needsReview(workflowID: String, requestID: String)
    case question(workflowID: String, requestID: String)
    case decisionGate(workflowID: String, requestID: String)
    case reply(workflowID: String, requestID: String)
    case gateResolved(workflowID: String, requestID: String)
    case continued(workflowID: String, requestID: String)
    case workerDone(workflowID: String, requestID: String)
}

public struct OrcaAttentionAdapterResult: Equatable, Sendable {
    public var events: [AttentionRequestEvent]
    public var ambient: AmbientOverview

    public init(events: [AttentionRequestEvent], ambient: AmbientOverview = AmbientOverview(entries: [])) {
        self.events = events
        self.ambient = ambient
    }
}

public enum OrcaAttentionAdapter {
    public static func adapt(
        snapshot: FocusResolver.Snapshot,
        supervisedSignals: [OrcaSupervisedSignal],
        observedAt: Date,
        terminalReads: [TerminalRead] = []
    ) -> OrcaAttentionAdapterResult {
        let focusedHandle = FocusResolver(snapshot: snapshot).focusedHandle()
        let worktreeByID = Dictionary(
            snapshot.worktrees.map { ($0.worktreeId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let agentsByPane = Dictionary(
            snapshot.worktrees.flatMap { worktree in
                (worktree.agents ?? []).compactMap { agent -> (String, AgentInfo)? in
                    guard let paneKey = nonEmpty(agent.paneKey) else { return nil }
                    return (agentKey(worktreeID: worktree.worktreeId, paneKey: paneKey), agent)
                }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let ambient = AmbientOverview(entries: snapshot.terminals.map { terminal in
            let worktree = terminal.worktreeId.flatMap { worktreeByID[$0] }
            let agent = matchedAgent(for: terminal, in: agentsByPane)
            let activity = StatusResolver.resolve(StatusInput(
                agentStates: agent.flatMap { [$0.state].compactMap { $0 } } ?? [],
                worktreeStatus: worktree?.status,
                lastOutputAt: terminal.lastOutputDate,
                tail: nil,
                now: observedAt
            ))
            return AmbientOverviewEntry(
                terminalHandle: terminal.handle,
                worktreeID: terminal.worktreeId,
                repository: worktree?.repo,
                branch: terminal.shortBranch ?? worktree?.shortBranch,
                title: terminal.title,
                connected: terminal.connected,
                lastOutputAt: terminal.lastOutputDate,
                isFocused: terminal.handle == focusedHandle,
                activity: activity,
                coverage: agent == nil ? .coverageGap : .structuredAgent
            )
        })
        let events: [AttentionRequestEvent] = supervisedSignals.compactMap { signal in
            let workflowID: String
            let requestID: String
            let event: AttentionRequestEvent
            switch signal {
            case let .blocked(rawWorkflowID, rawRequestID),
                 let .question(rawWorkflowID, rawRequestID):
                workflowID = rawWorkflowID
                requestID = rawRequestID
                event = .supervisedUserActionOpened(
                    workflowID: workflowID,
                    requestID: requestID,
                    requiresReview: false,
                    observedAt: observedAt
                )
            case let .needsReview(rawWorkflowID, rawRequestID),
                 let .decisionGate(rawWorkflowID, rawRequestID):
                workflowID = rawWorkflowID
                requestID = rawRequestID
                event = .supervisedUserActionOpened(
                    workflowID: workflowID,
                    requestID: requestID,
                    requiresReview: true,
                    observedAt: observedAt
                )
            case let .reply(rawWorkflowID, rawRequestID),
                 let .gateResolved(rawWorkflowID, rawRequestID),
                 let .continued(rawWorkflowID, rawRequestID),
                 let .workerDone(rawWorkflowID, rawRequestID):
                workflowID = rawWorkflowID
                requestID = rawRequestID
                event = .supervisedWorkflowContinued(
                    workflowID: workflowID,
                    requestID: requestID,
                    observedAt: observedAt
                )
            }
            guard hasCorrelation(workflowID, requestID) else { return nil }
            return event
        }
        return OrcaAttentionAdapterResult(events: events, ambient: ambient)
    }

    private static func matchedAgent(
        for terminal: TerminalInfo,
        in agentsByPane: [String: AgentInfo]
    ) -> AgentInfo? {
        guard let worktreeID = terminal.worktreeId,
              let tabID = terminal.tabId,
              let leafID = terminal.leafId
        else { return nil }
        return agentsByPane[agentKey(worktreeID: worktreeID, paneKey: "\(tabID):\(leafID)")]
    }

    private static func agentKey(worktreeID: String, paneKey: String) -> String {
        "\(worktreeID)|\(paneKey)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func hasCorrelation(_ values: String...) -> Bool {
        values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
