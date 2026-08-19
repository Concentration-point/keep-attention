import Foundation
import Testing
@testable import KeepAttentionCore

@Suite struct OrcaAttentionAdapterTests {
    private let observedAt = Date(timeIntervalSince1970: 1_786_100_000)

    @Test func supervisedBlockedAndNeedsReviewOpenTypedRequests() {
        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .blocked(workflowID: "dispatch-1", requestID: "message-1"),
                .needsReview(workflowID: "dispatch-2", requestID: "review-1"),
            ],
            observedAt: observedAt
        )

        #expect(result.events == [
            .supervisedUserActionOpened(
                workflowID: "dispatch-1",
                requestID: "message-1",
                requiresReview: false,
                observedAt: observedAt
            ),
            .supervisedUserActionOpened(
                workflowID: "dispatch-2",
                requestID: "review-1",
                requiresReview: true,
                observedAt: observedAt
            ),
        ])
    }

    @Test func mappedEventsAreConsumableByDomainStore() {
        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .blocked(workflowID: "dispatch-1", requestID: "message-1"),
                .needsReview(workflowID: "dispatch-2", requestID: "review-1"),
            ],
            observedAt: observedAt
        )
        var store = AttentionRequestStore()

        for event in result.events {
            store.apply(event)
        }

        #expect(store.activeRequests.map(\.kind) == [.userActionRequired, .reviewRequired])
    }

    @Test func structuredQuestionAndDecisionGateOpenRequests() {
        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .question(workflowID: "dispatch-1", requestID: "question-1"),
                .decisionGate(workflowID: "dispatch-2", requestID: "gate-1"),
            ],
            observedAt: observedAt
        )

        #expect(result.events == [
            .supervisedUserActionOpened(
                workflowID: "dispatch-1",
                requestID: "question-1",
                requiresReview: false,
                observedAt: observedAt
            ),
            .supervisedUserActionOpened(
                workflowID: "dispatch-2",
                requestID: "gate-1",
                requiresReview: true,
                observedAt: observedAt
            ),
        ])
    }

    @Test func structuredReplyAndGateResolutionResolveRequests() {
        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .reply(workflowID: "dispatch-1", requestID: "question-1"),
                .gateResolved(workflowID: "dispatch-2", requestID: "gate-1"),
            ],
            observedAt: observedAt
        )

        #expect(result.events == [
            .supervisedWorkflowContinued(
                workflowID: "dispatch-1",
                requestID: "question-1",
                observedAt: observedAt
            ),
            .supervisedWorkflowContinued(
                workflowID: "dispatch-2",
                requestID: "gate-1",
                observedAt: observedAt
            ),
        ])
    }

    @Test func incompleteCorrelationAndGenericObservationsProduceNoEvents() {
        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .blocked(workflowID: " ", requestID: "message"),
                .needsReview(workflowID: "dispatch", requestID: ""),
                .continued(workflowID: "dispatch", requestID: "   "),
                .workerDone(workflowID: "", requestID: "review"),
            ],
            observedAt: observedAt
        )

        #expect(result.events.isEmpty)
    }

    @Test func matchingLifecycleClosesStoreRequestButGenericDoneCannot() {
        var store = AttentionRequestStore()
        let opened = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .blocked(workflowID: "dispatch-1", requestID: "message-1"),
            ],
            observedAt: observedAt
        )
        opened.events.forEach { store.apply($0) }

        let genericDone = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [],
            observedAt: observedAt.addingTimeInterval(1),
            terminalReads: [TerminalRead(handle: "term", status: "done", tail: ["done"])]
        )
        genericDone.events.forEach { store.apply($0) }
        #expect(store.activeRequests.count == 1)

        let continued = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .continued(workflowID: "dispatch-1", requestID: "message-1"),
            ],
            observedAt: observedAt.addingTimeInterval(2)
        )
        continued.events.forEach { store.apply($0) }

        #expect(store.activeRequests.isEmpty)
        #expect(store.closedHistory.first?.status == .resolved)
    }

    @Test func matchingContinueAndWorkerDoneResolveRequests() {
        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: [], terminals: [], layouts: []),
            supervisedSignals: [
                .continued(workflowID: "dispatch-1", requestID: "message-1"),
                .workerDone(workflowID: "dispatch-2", requestID: "review-1"),
            ],
            observedAt: observedAt
        )

        #expect(result.events == [
            .supervisedWorkflowContinued(
                workflowID: "dispatch-1",
                requestID: "message-1",
                observedAt: observedAt
            ),
            .supervisedWorkflowContinued(
                workflowID: "dispatch-2",
                requestID: "review-1",
                observedAt: observedAt
            ),
        ])
    }
}
