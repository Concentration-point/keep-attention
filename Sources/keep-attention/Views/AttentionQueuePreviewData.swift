import Foundation
import KeepAttentionCore

/// Internal-only demo state for the M1 request-centric surface.
enum AttentionQueuePreviewData {
    static func projection(now: Date = Date()) -> AttentionQueueProjection {
        var requests = AttentionRequestStore()
        requests.apply(.traeXPermissionRequested(
            sessionID: "preview-session-permission",
            turnID: "preview-turn-permission",
            toolUseID: "preview-tool-permission",
            toolName: "Bash",
            observedAt: now.addingTimeInterval(-14 * 60)
        ))
        requests.apply(.supervisedUserActionOpened(
            workflowID: "preview-workflow-review",
            requestID: "preview-request-review",
            requiresReview: true,
            observedAt: now.addingTimeInterval(-9 * 60)
        ))
        requests.apply(.supervisedUserActionOpened(
            workflowID: "preview-workflow-action",
            requestID: "preview-request-action",
            requiresReview: false,
            observedAt: now.addingTimeInterval(-4 * 60)
        ))
        requests.apply(.traeXQuestionOpened(
            sessionID: "preview-session-question",
            turnID: "preview-turn-question",
            toolUseID: "preview-tool-question",
            observedAt: now.addingTimeInterval(-20 * 60)
        ))
        requests.apply(.snooze(
            key: .traeXTool(
                sessionID: "preview-session-question",
                turnID: "preview-turn-question",
                toolUseID: "preview-tool-question"
            ),
            until: now.addingTimeInterval(30 * 60),
            observedAt: now.addingTimeInterval(-2 * 60)
        ))

        let stale = AttentionRequest(
            key: .supervisedWorkflow(
                workflowID: "preview-workflow-stale",
                requestID: "preview-request-stale"
            ),
            sessionKey: .supervisedWorkflow(workflowID: "preview-workflow-stale"),
            kind: .stateNeedsConfirmation,
            status: .stale,
            createdAt: now.addingTimeInterval(-60 * 60),
            updatedAt: now.addingTimeInterval(-8 * 60),
            evidence: [AttentionRequestEvidence(
                eventName: "StaleCleanup",
                observedAt: now.addingTimeInterval(-8 * 60)
            )],
            sourceConfidence: .supervisedWorkflow
        )
        let snapshot = AttentionRequestPersistenceSnapshot(
            activeRequests: requests.activeRequests,
            closedHistory: [stale]
        )
        let ambient = AmbientOverview(entries: [
            AmbientOverviewEntry(
                terminalHandle: "preview-terminal-one",
                worktreeID: "preview-worktree-one",
                repository: "keep-attention",
                branch: "main",
                title: nil,
                connected: true,
                lastOutputAt: now.addingTimeInterval(-20),
                isFocused: true,
                activity: .busy,
                coverage: .structuredAgent
            ),
            AmbientOverviewEntry(
                terminalHandle: "preview-terminal-two",
                worktreeID: "preview-worktree-two",
                repository: "adapter-lab",
                branch: "signal-contract",
                title: nil,
                connected: true,
                lastOutputAt: now.addingTimeInterval(-120),
                isFocused: false,
                activity: .busy,
                coverage: .coverageGap
            ),
            AmbientOverviewEntry(
                terminalHandle: "preview-terminal-three",
                worktreeID: "preview-worktree-three",
                repository: "design-notes",
                branch: "queue-ui",
                title: nil,
                connected: false,
                lastOutputAt: now.addingTimeInterval(-600),
                isFocused: false,
                activity: .idle,
                coverage: .structuredAgent
            ),
        ])

        return AttentionQueueProjection.make(
            store: AttentionRequestStore(snapshot: snapshot, now: now),
            ambient: ambient,
            now: now,
            aiSummariesEnabled: false
        )
    }
}
