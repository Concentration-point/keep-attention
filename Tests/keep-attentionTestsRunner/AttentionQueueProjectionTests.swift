import Foundation
import Testing
@testable import KeepAttentionCore

@Suite struct AttentionQueueProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_787_100_000)

    @Test func queueHeadAndAtMostThreePreviewRowsFollowDomainSort() throws {
        var store = AttentionRequestStore()
        for index in 0..<5 {
            store.apply(.supervisedUserActionOpened(
                workflowID: "private-workflow-\(index)",
                requestID: "private-request-\(index)",
                requiresReview: index == 4,
                observedAt: now.addingTimeInterval(TimeInterval(index))
            ))
        }

        let projection = AttentionQueueProjection.make(
            store: store,
            ambient: AmbientOverview(entries: []),
            now: now.addingTimeInterval(10),
            aiSummariesEnabled: false
        )

        #expect(projection.requestCount == 5)
        #expect(projection.queueHead?.kindLabel == "Action required")
        #expect(projection.queuePreviews.count == 3)
        #expect(projection.queuePreviews.allSatisfy { $0.kindLabel == "Action required" })
    }

    @Test func snoozedRequestsStayInFoldUntilWakeThenReturnToQueue() throws {
        let sleepingKey = AttentionRequestKey.traeXTool(
            sessionID: "private-session-id",
            turnID: "private-turn-id",
            toolUseID: "private-tool-id"
        )
        let wakeAt = now.addingTimeInterval(60)
        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "private-session-id",
            turnID: "private-turn-id",
            toolUseID: "private-tool-id",
            toolName: "Bash",
            observedAt: now
        ))
        store.apply(.snooze(key: sleepingKey, until: wakeAt, observedAt: now.addingTimeInterval(1)))
        store.apply(.supervisedUserActionOpened(
            workflowID: "private-workflow-id",
            requestID: "private-request-id",
            requiresReview: false,
            observedAt: now.addingTimeInterval(2)
        ))

        let sleeping = AttentionQueueProjection.make(
            store: store,
            ambient: AmbientOverview(entries: []),
            now: now.addingTimeInterval(3),
            aiSummariesEnabled: false
        )
        #expect(sleeping.requestCount == 1)
        #expect(sleeping.snoozed.count == 1)
        #expect(sleeping.snoozed.first?.statusLabel == "Snoozed")

        let awake = AttentionQueueProjection.make(
            store: store,
            ambient: AmbientOverview(entries: []),
            now: wakeAt,
            aiSummariesEnabled: false
        )
        #expect(awake.requestCount == 2)
        #expect(awake.snoozed.isEmpty)
    }

    @Test func staleHistoryUsesConfirmationCopyWithoutJoiningActiveQueue() throws {
        var stale = makeRequest(
            id: "private-stale-id",
            kind: .stateNeedsConfirmation,
            status: .stale,
            createdAt: now.addingTimeInterval(-60)
        )
        stale.updatedAt = now
        let store = AttentionRequestStore(snapshot: AttentionRequestPersistenceSnapshot(
            activeRequests: [],
            closedHistory: [stale]
        ), now: now)

        let projection = AttentionQueueProjection.make(
            store: store,
            ambient: AmbientOverview(entries: []),
            now: now,
            aiSummariesEnabled: false
        )

        #expect(projection.requestCount == 0)
        #expect(projection.staleHistory.count == 1)
        #expect(projection.staleHistory.first?.statusLabel == "Stale = state needs confirmation")
        #expect(projection.staleHistory.first?.needFromYou == "Confirm whether this request is still active.")
    }

    @Test func evidenceDrawerExposesOnlySafeStructuredSummaryAndJumpReference() throws {
        var request = makeRequest(
            id: "private-request-id",
            kind: .reviewRequired,
            status: .unseen,
            createdAt: now
        )
        request.evidence = [AttentionRequestEvidence(
            eventName: "needs-review",
            observedAt: now,
            reference: EvidenceRef(
                source: "Orca",
                correlationLabel: "/Users/private/repo/private-session-id"
            )
        )]
        let store = AttentionRequestStore(snapshot: AttentionRequestPersistenceSnapshot(
            activeRequests: [request],
            closedHistory: []
        ), now: now)

        let projection = AttentionQueueProjection.make(
            store: store,
            ambient: AmbientOverview(entries: []),
            now: now,
            aiSummariesEnabled: false
        )
        let evidence = try #require(projection.queueHead?.evidence.first)

        #expect(evidence.eventLabel == "Review requested")
        #expect(evidence.sourceLabel == "Orca")
        #expect(evidence.observedAt == now)
        #expect(evidence.jumpReference == "Open the matching request in Orca")
        let encoded = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
        #expect(!encoded.contains("private-request-id"))
        #expect(!encoded.contains("private-session-id"))
        #expect(!encoded.contains("/Users/"))
        #expect(!encoded.contains("correlationLabel"))
    }

    @Test func deterministicCopyRemainsUsefulWhenAISummariesAreDisabled() throws {
        let kinds: [(AttentionRequestKind, String, String, String)] = [
            (.permissionRequired, "Permission", "A structured permission request is waiting.", "Approve or deny in TraeX."),
            (.userAnswerRequired, "Question", "A structured question is waiting for an answer.", "Answer the question in TraeX."),
            (.userActionRequired, "Action", "A supervised workflow is blocked on you.", "Complete the requested action in Orca."),
            (.reviewRequired, "Review", "A supervised workflow is ready for review.", "Review the pending work in Orca."),
            (.stateNeedsConfirmation, "Confirmation", "The last known state may be out of date.", "Confirm whether this request is still active."),
        ]

        for (index, expected) in kinds.enumerated() {
            let request = makeRequest(
                id: "private-\(index)",
                kind: expected.0,
                status: .unseen,
                createdAt: now.addingTimeInterval(TimeInterval(index))
            )
            let store = AttentionRequestStore(snapshot: AttentionRequestPersistenceSnapshot(
                activeRequests: [request],
                closedHistory: []
            ), now: now.addingTimeInterval(10))
            let projection = AttentionQueueProjection.make(
                store: store,
                ambient: AmbientOverview(entries: []),
                now: now.addingTimeInterval(10),
                aiSummariesEnabled: false
            )
            let card = try #require(projection.queueHead)

            #expect(card.objectLabel == expected.1)
            #expect(card.whyAttention == expected.2)
            #expect(card.needFromYou == expected.3)
            #expect(card.summarySourceLabel == "Deterministic local fallback · AI disabled")
        }
    }

    @Test func ambientRowsCarrySafeLabelsWithoutIdentifiersPathsOrTerminalTitles() throws {
        let ambient = AmbientOverview(entries: [
            AmbientOverviewEntry(
                terminalHandle: "raw-terminal-id",
                worktreeID: "raw-worktree-/Users/private/repo",
                repository: "/Users/private/repo",
                branch: "feature/private",
                title: "private prompt and terminal title",
                connected: true,
                lastOutputAt: now,
                isFocused: true,
                activity: .busy,
                coverage: .coverageGap
            ),
            AmbientOverviewEntry(
                terminalHandle: "raw-terminal-id-2",
                worktreeID: nil,
                repository: "keep-attention",
                branch: "main",
                title: nil,
                connected: false,
                lastOutputAt: nil,
                isFocused: false,
                activity: .idle,
                coverage: .structuredAgent
            ),
        ])

        let projection = AttentionQueueProjection.make(
            store: AttentionRequestStore(),
            ambient: ambient,
            now: now,
            aiSummariesEnabled: false
        )

        #expect(projection.ambient.count == 2)
        #expect(projection.ambient[0].classificationLabel == "not request")
        #expect(projection.ambient[0].coverageLabel == "coverage gap")
        #expect(projection.ambient[0].displayName == "Workspace")
        #expect(projection.ambient[1].displayName == "keep-attention · main")
        #expect(projection.ambient[1].connectionLabel == "Disconnected")
        let encoded = String(decoding: try JSONEncoder().encode(projection.ambient), as: UTF8.self)
        for forbidden in ["raw-terminal", "raw-worktree", "/Users/", "private prompt", "private terminal"] {
            #expect(!encoded.contains(forbidden))
        }
    }

    @Test func onlyUnseenStrongBlockersOptIntoQueueHeadEmphasis() throws {
        let cases: [(AttentionRequestKind, AttentionRequestStatus, Bool)] = [
            (.permissionRequired, .unseen, true),
            (.userAnswerRequired, .unseen, true),
            (.permissionRequired, .seen, false),
            (.userActionRequired, .unseen, false),
            (.reviewRequired, .unseen, false),
            (.stateNeedsConfirmation, .unseen, false),
        ]

        for (index, input) in cases.enumerated() {
            let request = makeRequest(
                id: "private-emphasis-\(index)",
                kind: input.0,
                status: input.1,
                createdAt: now
            )
            let store = AttentionRequestStore(snapshot: AttentionRequestPersistenceSnapshot(
                activeRequests: [request],
                closedHistory: []
            ), now: now)
            let card = try #require(AttentionQueueProjection.make(
                store: store,
                ambient: AmbientOverview(entries: []),
                now: now,
                aiSummariesEnabled: false
            ).queueHead)

            #expect(card.usesStrongSignal == input.2)
        }
    }

    @Test func seenStatusExplicitlyStatesItIsNotResolved() throws {
        let request = makeRequest(
            id: "private-seen-id",
            kind: .permissionRequired,
            status: .seen,
            createdAt: now
        )
        let store = AttentionRequestStore(snapshot: AttentionRequestPersistenceSnapshot(
            activeRequests: [request],
            closedHistory: []
        ), now: now)

        let card = try #require(AttentionQueueProjection.make(
            store: store,
            ambient: AmbientOverview(entries: []),
            now: now,
            aiSummariesEnabled: false
        ).queueHead)

        #expect(card.statusLabel == "Seen != Resolved")
    }

    @Test func ambientProjectionSupportsOrcaUnavailableState() {
        let projection = AttentionQueueProjection.make(
            store: AttentionRequestStore(),
            ambient: AmbientOverview(entries: []),
            now: now,
            aiSummariesEnabled: false,
            ambientAvailability: .unavailable
        )

        #expect(projection.ambientAvailabilityLabel == "Orca unavailable")
        #expect(projection.collapsed == .ambient(
            title: "Orca unavailable",
            detail: "Session Overview is temporarily unavailable",
            count: 0
        ))
    }

    @Test func collapsedSurfaceShowsQueueHeadOrAmbientSummary() throws {
        let ambient = AmbientOverview(entries: [
            AmbientOverviewEntry(
                terminalHandle: "private-terminal-id",
                worktreeID: "private-worktree-id",
                repository: "keep-attention",
                branch: "main",
                title: "private terminal title",
                connected: true,
                lastOutputAt: now,
                isFocused: true,
                activity: .busy,
                coverage: .structuredAgent
            ),
        ])
        let noRequests = AttentionQueueProjection.make(
            store: AttentionRequestStore(),
            ambient: ambient,
            now: now,
            aiSummariesEnabled: false
        )

        #expect(noRequests.collapsed == .ambient(
            title: "Session Overview · 1 session",
            detail: "1 active · 0 coverage gaps",
            count: 1
        ))
        #expect(noRequests.queueHead == nil)

        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "private-session-id",
            turnID: "private-turn-id",
            toolUseID: "private-tool-id",
            toolName: "Bash",
            observedAt: now
        ))
        let withRequest = AttentionQueueProjection.make(
            store: store,
            ambient: ambient,
            now: now,
            aiSummariesEnabled: false
        )

        #expect(withRequest.collapsed == .request(
            title: "Permission required",
            detail: "Approve or deny in TraeX.",
            count: 1
        ))
        #expect(try #require(withRequest.queueHead).kindLabel == "Permission required")
        #expect(withRequest.requestCount == 1)
    }

    private func makeRequest(
        id: String,
        kind: AttentionRequestKind,
        status: AttentionRequestStatus,
        createdAt: Date
    ) -> AttentionRequest {
        AttentionRequest(
            key: .supervisedWorkflow(workflowID: id, requestID: id),
            sessionKey: .supervisedWorkflow(workflowID: id),
            kind: kind,
            status: status,
            createdAt: createdAt,
            updatedAt: createdAt,
            evidence: [AttentionRequestEvidence(eventName: "fixture", observedAt: createdAt)],
            sourceConfidence: .structuredHook
        )
    }
}
