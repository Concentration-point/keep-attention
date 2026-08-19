import Testing
import Foundation
@testable import KeepAttentionCore

@Suite struct AttentionRequestCoreTests {
    @Test func permissionRequestOpensAndMatchingToolResultResolves() throws {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_000)
        let resolvedAt = openedAt.addingTimeInterval(3)
        var store = AttentionRequestStore()

        store.apply(.traeXPermissionRequested(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            toolName: "Bash",
            observedAt: openedAt
        ))

        let request = try #require(store.activeRequests.first)
        #expect(store.activeRequests.count == 1)
        #expect(request.key == .traeXTool(sessionID: "session-1", turnID: "turn-1", toolUseID: "tool-1"))
        #expect(request.sessionKey == .traeX(sessionID: "session-1"))
        #expect(request.kind == .permissionRequired)
        #expect(request.status == .unseen)
        #expect(request.createdAt == openedAt)
        #expect(request.updatedAt == openedAt)
        #expect(request.evidence.last?.eventName == "PermissionRequest")

        store.apply(.traeXToolCompleted(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            observedAt: resolvedAt
        ))

        #expect(store.activeRequests.isEmpty)
        let closed = try #require(store.closedHistory.first)
        #expect(store.closedHistory.count == 1)
        #expect(closed.key == request.key)
        #expect(closed.status == .resolved)
        #expect(closed.updatedAt == resolvedAt)
        #expect(closed.evidence.last?.eventName == "PostToolUse")
    }

    @Test func onlyStructuredUserObligationsOpenRequests() {
        let now = Date(timeIntervalSince1970: 1_787_000_100)
        var store = AttentionRequestStore()

        store.apply(.traeXQuestionOpened(
            sessionID: "question-session",
            turnID: "turn-1",
            toolUseID: "question-1",
            observedAt: now
        ))
        #expect(store.activeRequests.map(\.kind) == [.userAnswerRequired])

        store.apply(.supervisedUserActionOpened(
            workflowID: "workflow-session",
            requestID: "action-1",
            requiresReview: false,
            observedAt: now.addingTimeInterval(1)
        ))
        #expect(store.activeRequests.map(\.kind).contains(.userActionRequired))

        store.apply(.supervisedUserActionOpened(
            workflowID: "review-session",
            requestID: "review-1",
            requiresReview: true,
            observedAt: now.addingTimeInterval(2)
        ))
        #expect(store.activeRequests.map(\.kind).contains(.reviewRequired))

        let activeBeforeIgnoredEvents = store.activeRequests
        let closedBeforeIgnoredEvents = store.closedHistory
        store.apply(.traeXToolCompleted(
            sessionID: "unknown-session",
            turnID: "turn-1",
            toolUseID: "unknown-tool",
            observedAt: now.addingTimeInterval(3)
        ))
        store.apply(.traeXPermissionRequested(
            sessionID: "",
            turnID: "turn-1",
            toolUseID: "tool-1",
            toolName: "Bash",
            observedAt: now.addingTimeInterval(3)
        ))
        store.apply(.unclassifiedObserved(
            sessionID: "unknown-session",
            correlationID: "",
            eventName: "Stop",
            observedAt: now.addingTimeInterval(4)
        ))

        #expect(store.activeRequests == activeBeforeIgnoredEvents)
        #expect(store.closedHistory == closedBeforeIgnoredEvents)
    }

    @Test func newObligationReplacesTheOnlyActiveRequestInItsSession() throws {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_200)
        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "permission-1",
            toolName: "Bash",
            observedAt: openedAt
        ))

        store.apply(.traeXQuestionOpened(
            sessionID: "session-1",
            turnID: "turn-2",
            toolUseID: "question-1",
            observedAt: openedAt.addingTimeInterval(1)
        ))

        #expect(store.activeRequests.count == 1)
        #expect(store.activeRequests.first?.kind == .userAnswerRequired)
        let superseded = try #require(store.closedHistory.first)
        #expect(superseded.kind == .permissionRequired)
        #expect(superseded.status == .stale)
        #expect(superseded.evidence.last?.eventName == "ObligationSuperseded")
    }

    @Test func seenStaysActiveAndMismatchedCompletionCannotResolve() {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_300)
        let key = AttentionRequestKey.traeXTool(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1"
        )
        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            toolName: "Bash",
            observedAt: openedAt
        ))

        store.apply(.markSeen(key: key, observedAt: openedAt.addingTimeInterval(1)))
        #expect(store.activeRequests.first?.status == .seen)
        #expect(store.closedHistory.isEmpty)

        store.apply(.traeXQuestionFailed(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            observedAt: openedAt.addingTimeInterval(1.5)
        ))
        #expect(store.activeRequests.first?.status == .seen)
        #expect(store.closedHistory.isEmpty)

        store.apply(.traeXToolCompleted(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "other-tool",
            observedAt: openedAt.addingTimeInterval(2)
        ))
        #expect(store.activeRequests.first?.key == key)
        #expect(store.activeRequests.first?.status == .seen)
        #expect(store.closedHistory.isEmpty)
    }

    @Test func evidenceContainsOnlySafeStructuredFields() throws {
        let evidence = AttentionRequestEvidence(
            eventName: "PermissionRequest",
            observedAt: Date(timeIntervalSince1970: 1_787_000_325),
            reference: EvidenceRef(source: "TraeX", correlationLabel: "tool")
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["eventName", "observedAt", "reference"])
        let reference = try #require(object["reference"] as? [String: Any])
        #expect(Set(reference.keys) == ["source", "correlationLabel"])
    }

    @Test func matchingAnswerResolvesQuestionButQuestionFailureDoesNot() {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_350)
        var store = AttentionRequestStore()
        store.apply(.traeXQuestionOpened(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "question-1",
            observedAt: openedAt
        ))
        store.apply(.traeXQuestionFailed(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "question-1",
            observedAt: openedAt.addingTimeInterval(1)
        ))
        #expect(store.activeRequests.count == 1)

        store.apply(.traeXQuestionAnswered(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "question-1",
            observedAt: openedAt.addingTimeInterval(2)
        ))
        #expect(store.activeRequests.isEmpty)
        #expect(store.closedHistory.first?.status == .resolved)
        #expect(store.closedHistory.first?.evidence.last?.eventName == "PostToolUse")
    }

    @Test func supervisedContinueClosesOnlyMatchingAction() {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_375)
        var store = AttentionRequestStore()
        store.apply(.supervisedUserActionOpened(
            workflowID: "workflow",
            requestID: "action",
            requiresReview: false,
            observedAt: openedAt
        ))
        store.apply(.supervisedWorkflowContinued(
            workflowID: "workflow",
            requestID: "other",
            observedAt: openedAt.addingTimeInterval(1)
        ))
        #expect(store.activeRequests.count == 1)

        store.apply(.supervisedWorkflowContinued(
            workflowID: "workflow",
            requestID: "action",
            observedAt: openedAt.addingTimeInterval(2)
        ))
        #expect(store.activeRequests.isEmpty)
        #expect(store.closedHistory.first?.status == .resolved)
    }

    @Test func snoozeFiltersUntilExpiryAndNewObligationReappearsUnseen() {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_400)
        let key = AttentionRequestKey.traeXTool(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1"
        )
        let wakeAt = openedAt.addingTimeInterval(60)
        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            toolName: "Bash",
            observedAt: openedAt
        ))
        store.apply(.snooze(key: key, until: wakeAt, observedAt: openedAt.addingTimeInterval(1)))

        #expect(store.activeRequests.first?.status == .snoozed(until: wakeAt))
        #expect(GlobalAttentionQueueSorter.sorted(
            store.activeRequests,
            now: wakeAt.addingTimeInterval(-1)
        ).isEmpty)
        #expect(GlobalAttentionQueueSorter.sorted(store.activeRequests, now: wakeAt).map(\.key) == [key])

        store.apply(.traeXQuestionOpened(
            sessionID: "session-1",
            turnID: "turn-2",
            toolUseID: "question-1",
            observedAt: openedAt.addingTimeInterval(2)
        ))
        #expect(store.activeRequests.first?.kind == .userAnswerRequired)
        #expect(store.activeRequests.first?.status == .unseen)
    }

    @Test func repeatedEvidenceForSameObligationUpdatesInPlaceWithoutResettingSeen() {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_450)
        let key = AttentionRequestKey.traeXTool(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1"
        )
        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            toolName: "Bash",
            observedAt: openedAt
        ))
        store.apply(.markSeen(key: key, observedAt: openedAt.addingTimeInterval(1)))

        store.apply(.traeXPermissionRequested(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            toolName: "Bash",
            observedAt: openedAt.addingTimeInterval(2)
        ))

        #expect(store.activeRequests.count == 1)
        #expect(store.activeRequests.first?.status == .seen)
        #expect(store.activeRequests.first?.createdAt == openedAt)
        #expect(store.activeRequests.first?.obligationStartedAt == openedAt)
        #expect(store.activeRequests.first?.evidence.count == 2)
        #expect(store.closedHistory.isEmpty)
    }

    @Test func snapshotRestoresActiveAndCleanupMovesItToStaleHistory() throws {
        let openedAt = Date(timeIntervalSince1970: 1_787_000_500)
        let restoredAt = openedAt.addingTimeInterval(60)
        let cleanedAt = openedAt.addingTimeInterval(120)
        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "session-1",
            turnID: "turn-1",
            toolUseID: "tool-1",
            toolName: "Bash",
            observedAt: openedAt
        ))

        let encoded = try JSONEncoder().encode(store.snapshot())
        let snapshot = try JSONDecoder().decode(AttentionRequestPersistenceSnapshot.self, from: encoded)
        var restored = AttentionRequestStore(snapshot: snapshot, now: restoredAt)
        #expect(restored.activeRequests == store.activeRequests)

        restored.apply(.markStaleAfterRestart(observedAt: cleanedAt))
        #expect(restored.activeRequests.isEmpty)
        #expect(restored.closedHistory.first?.status == .stale)
        #expect(restored.closedHistory.first?.updatedAt == cleanedAt)
        #expect(restored.closedHistory.first?.evidence.last?.eventName == "StaleCleanup")
    }

    @Test func escalationStateSurvivesSnapshotWithoutChangingQueueOrder() throws {
        let now = Date(timeIntervalSince1970: 1_787_000_550)
        let escalatedAt = now.addingTimeInterval(-10)
        var request = makeRequest(
            id: "request",
            kind: .permissionRequired,
            status: .unseen,
            createdAt: now.addingTimeInterval(-60)
        )
        request.escalationCount = 1
        request.lastEscalatedAt = escalatedAt
        let snapshot = AttentionRequestPersistenceSnapshot(activeRequests: [request], closedHistory: [])

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AttentionRequestPersistenceSnapshot.self, from: encoded)

        #expect(decoded.activeRequests.first?.escalationCount == 1)
        #expect(decoded.activeRequests.first?.lastEscalatedAt == escalatedAt)
        #expect(GlobalAttentionQueueSorter.sorted(decoded.activeRequests, now: now).map(\.key) == [request.key])
    }

    @Test func closedHistoryKeepsOnlyNewestFiftyFromLastTwentyFourHours() {
        let now = Date(timeIntervalSince1970: 1_787_000_575)
        let recent = (0..<60).map { offset in
            makeRequest(
                id: String(format: "recent-%02d", offset),
                kind: .permissionRequired,
                status: .resolved,
                createdAt: now.addingTimeInterval(TimeInterval(-offset))
            )
        }
        let expired = makeRequest(
            id: "expired",
            kind: .permissionRequired,
            status: .resolved,
            createdAt: now.addingTimeInterval(-(24 * 60 * 60 + 1))
        )
        let snapshot = AttentionRequestPersistenceSnapshot(
            activeRequests: [],
            closedHistory: Array((recent + [expired]).reversed())
        )

        let restored = AttentionRequestStore(snapshot: snapshot, now: now)

        #expect(restored.closedHistory.count == 50)
        #expect(restored.closedHistory.map(\.key) == Array(recent.prefix(50)).map(\.key))
        #expect(!restored.closedHistory.contains(where: { $0.key == expired.key }))
    }

    @Test func storePrunesClosedHistoryAsEventsAreReduced() {
        let now = Date(timeIntervalSince1970: 1_787_000_590)
        let historical = (0..<50).map { offset in
            makeRequest(
                id: "history-\(offset)",
                kind: .permissionRequired,
                status: .resolved,
                createdAt: now.addingTimeInterval(TimeInterval(-offset - 10))
            )
        }
        var store = AttentionRequestStore(snapshot: AttentionRequestPersistenceSnapshot(
            activeRequests: [],
            closedHistory: historical
        ), now: now)
        store.apply(.traeXPermissionRequested(
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool",
            toolName: "Bash",
            observedAt: now
        ))
        store.apply(.traeXToolCompleted(
            sessionID: "session",
            turnID: "turn",
            toolUseID: "tool",
            observedAt: now.addingTimeInterval(1)
        ))

        #expect(store.closedHistory.count == 50)
        #expect(store.closedHistory.first?.updatedAt == now.addingTimeInterval(1))
    }

    @Test func sorterUsesBlockingTierWaitTimeStatusConfidenceWorkspaceAndStableKey() {
        let now = Date(timeIntervalSince1970: 1_787_000_600)
        let requests = [
            makeRequest(
                id: "stale-old",
                kind: .stateNeedsConfirmation,
                status: .unseen,
                createdAt: now.addingTimeInterval(-1_000)
            ),
            makeRequest(
                id: "answer-seen",
                kind: .userAnswerRequired,
                status: .seen,
                createdAt: now.addingTimeInterval(-200)
            ),
            makeRequest(
                id: "permission-new",
                kind: .permissionRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-10)
            ),
            makeRequest(
                id: "answer-unseen-new",
                kind: .userAnswerRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-100),
                sourceConfidence: .genericObservation
            ),
            makeRequest(
                id: "answer-unseen-old",
                kind: .userAnswerRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-300),
                sourceConfidence: .genericObservation
            ),
            makeRequest(
                id: "review",
                kind: .reviewRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-500)
            ),
            makeRequest(
                id: "answer-confident",
                kind: .userAnswerRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-100),
                sourceConfidence: .supervisedWorkflow
            ),
            makeRequest(
                id: "answer-recent-workspace",
                kind: .userAnswerRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-100),
                sourceConfidence: .structuredHook,
                workspaceLastVisitedAt: now.addingTimeInterval(-1)
            ),
            makeRequest(
                id: "answer-a",
                kind: .userAnswerRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-100),
                sourceConfidence: .structuredHook
            ),
            makeRequest(
                id: "answer-b",
                kind: .userAnswerRequired,
                status: .unseen,
                createdAt: now.addingTimeInterval(-100),
                sourceConfidence: .structuredHook
            ),
        ]

        #expect(GlobalAttentionQueueSorter.sorted(requests, now: now).map(\.key) == [
            .supervisedWorkflow(workflowID: "permission-new", requestID: "permission-new"),
            .supervisedWorkflow(workflowID: "answer-unseen-old", requestID: "answer-unseen-old"),
            .supervisedWorkflow(workflowID: "answer-seen", requestID: "answer-seen"),
            .supervisedWorkflow(workflowID: "answer-confident", requestID: "answer-confident"),
            .supervisedWorkflow(workflowID: "answer-recent-workspace", requestID: "answer-recent-workspace"),
            .supervisedWorkflow(workflowID: "answer-a", requestID: "answer-a"),
            .supervisedWorkflow(workflowID: "answer-b", requestID: "answer-b"),
            .supervisedWorkflow(workflowID: "answer-unseen-new", requestID: "answer-unseen-new"),
            .supervisedWorkflow(workflowID: "review", requestID: "review"),
            .supervisedWorkflow(workflowID: "stale-old", requestID: "stale-old"),
        ])
    }

    private func makeRequest(
        id: String,
        kind: AttentionRequestKind,
        status: AttentionRequestStatus,
        createdAt: Date,
        sourceConfidence: AttentionSourceConfidence = .structuredHook,
        workspaceLastVisitedAt: Date? = nil
    ) -> AttentionRequest {
        AttentionRequest(
            key: .supervisedWorkflow(workflowID: id, requestID: id),
            sessionKey: .supervisedWorkflow(workflowID: id),
            kind: kind,
            status: status,
            createdAt: createdAt,
            updatedAt: createdAt,
            evidence: [AttentionRequestEvidence(eventName: "fixture", observedAt: createdAt)],
            sourceConfidence: sourceConfidence,
            workspaceLastVisitedAt: workspaceLastVisitedAt,
            obligationStartedAt: createdAt
        )
    }
}
