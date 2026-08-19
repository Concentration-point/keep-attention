import Foundation
import Testing
@testable import KeepAttentionCore

// issue #34（承接 #20）：中断升级纯逻辑判定器。
// 覆盖：升级资格（强阻塞 + 高置信 + Unseen）、Seen/Snoozed/muted 抑制、
// 同一义务至多升级一次（escalationCount/lastEscalatedAt 语义）、全局短窗节流、
// stale 低频 uncertain 通知规则（仅原本强阻塞、且只发一次）。
@Suite struct EscalationPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_787_200_000)

    // MARK: - 升级资格

    @Test func strongBlockerUnseenHighConfidenceIsEligibleForEscalation() {
        let request = makeRequest(kind: .permissionRequired, status: .unseen, confidence: .structuredHook)

        let verdict = EscalationPolicy.evaluate(
            request: request,
            now: now,
            throttle: InterruptionThrottleState()
        )

        #expect(verdict == .escalate)
    }

    @Test func weakKindsAndLowConfidenceNeverEscalate() {
        let cases: [(AttentionRequestKind, AttentionSourceConfidence)] = [
            (.userActionRequired, .structuredHook),
            (.reviewRequired, .structuredHook),
            (.stateNeedsConfirmation, .structuredHook),
            (.permissionRequired, .genericObservation),
            (.userAnswerRequired, .genericObservation),
        ]

        for (index, input) in cases.enumerated() {
            let request = makeRequest(
                id: "weak-\(index)",
                kind: input.0,
                status: .unseen,
                confidence: input.1
            )
            let verdict = EscalationPolicy.evaluate(request: request, now: now)
            if case .suppressed = verdict {
                #expect(Bool(true))
            } else {
                Issue.record("expected suppression for \(input.0)/\(input.1), got \(verdict)")
            }
        }
    }

    @Test func seenRequestsNeverEscalate() {
        let request = makeRequest(kind: .userAnswerRequired, status: .seen, confidence: .structuredHook)

        let verdict = EscalationPolicy.evaluate(request: request, now: now)

        #expect(verdict == .suppressed(.notUnseen))
    }

    @Test func activeSnoozeSuppressesEscalationWhileExpiredSnoozeStaysEligible() {
        let snoozedActive = makeRequest(
            id: "snooze-active",
            kind: .permissionRequired,
            status: .snoozed(until: now.addingTimeInterval(120)),
            confidence: .structuredHook
        )
        let snoozedExpired = makeRequest(
            id: "snooze-expired",
            kind: .permissionRequired,
            status: .snoozed(until: now.addingTimeInterval(-1)),
            confidence: .structuredHook
        )

        let activeVerdict = EscalationPolicy.evaluate(request: snoozedActive, now: now)
        let expiredVerdict = EscalationPolicy.evaluate(request: snoozedExpired, now: now)

        if case let .suppressed(reason) = activeVerdict {
            guard case .snoozed = reason else {
                Issue.record("expected snoozed suppression, got \(reason)")
                return
            }
        } else {
            Issue.record("expected suppression for active snooze, got \(activeVerdict)")
        }
        #expect(expiredVerdict == .escalate)
    }

    @Test func mutedWorkspaceSessionsNeverEscalate() {
        let request = makeRequest(
            id: "muted",
            kind: .permissionRequired,
            status: .unseen,
            confidence: .structuredHook
        )
        let sessionKey = AgentSessionKey.traeX(sessionID: "muted")

        let verdict = EscalationPolicy.evaluate(
            request: request,
            now: now,
            mutedSessionKeys: [sessionKey]
        )

        #expect(verdict == .suppressed(.mutedWorkspace))
    }

    @Test func globallyDisabledNotificationsSuppressEverything() {
        let request = makeRequest(kind: .permissionRequired, status: .unseen, confidence: .structuredHook)

        let verdict = EscalationPolicy.evaluate(
            request: request,
            now: now,
            notificationsEnabled: false
        )

        #expect(verdict == .suppressed(.notificationsDisabled))
    }

    // MARK: - 同一义务至多升级一次

    @Test func obligationThatAlreadyEscalatedIsNeverEscalatedAgain() {
        var request = makeRequest(kind: .permissionRequired, status: .unseen, confidence: .structuredHook)
        request.escalationCount = 1
        request.lastEscalatedAt = now.addingTimeInterval(-120)

        let verdict = EscalationPolicy.evaluate(request: request, now: now)

        #expect(verdict == .suppressed(.obligationAlreadyEscalated(escalationCount: 1)))
    }

    @Test func markingEscalationRecordsCountAndTimestampWithoutTouchingStatus() {
        let escalatedAt = now.addingTimeInterval(5)
        let request = makeRequest(kind: .permissionRequired, status: .unseen, confidence: .structuredHook)

        let marked = EscalationPolicy.markEscalated(request: request, at: escalatedAt)

        #expect(marked.escalationCount == request.escalationCount + 1)
        #expect(marked.lastEscalatedAt == escalatedAt)
        #expect(marked.status == request.status)
        #expect(marked.updatedAt == request.updatedAt)

        let reVerdict = EscalationPolicy.evaluate(request: marked, now: escalatedAt.addingTimeInterval(600))
        #expect(reVerdict == .suppressed(.obligationAlreadyEscalated(escalationCount: 1)))
    }

    // MARK: - 全局短窗节流

    @Test func globalThrottleSuppressesSecondEscalationWithinWindowAndReallowsAfter() {
        let first = makeRequest(id: "first", kind: .permissionRequired, status: .unseen, confidence: .structuredHook)
        let second = makeRequest(id: "second", kind: .userAnswerRequired, status: .unseen, confidence: .structuredHook)
        var throttle = InterruptionThrottleState()
        #expect(throttle.escalationWindow == 60)

        throttle.recordEscalation(at: now.addingTimeInterval(-30))
        let throttledVerdict = EscalationPolicy.evaluate(
            request: second,
            now: now,
            throttle: throttle
        )
        if case let .suppressed(reason) = throttledVerdict {
            guard case .globalThrottleWindow = reason else {
                Issue.record("expected throttle suppression, got \(reason)")
                return
            }
        } else {
            Issue.record("expected throttle suppression, got \(throttledVerdict)")
        }

        throttle.recordEscalation(at: now.addingTimeInterval(-60))
        let outsideWindowVerdict = EscalationPolicy.evaluate(
            request: second,
            now: now,
            throttle: throttle
        )
        #expect(outsideWindowVerdict == .escalate)

        // 第一个请求自身不受节流影响（窗口由最近一次全局升级时间决定，首次无记录时直接放行）。
        #expect(EscalationPolicy.evaluate(request: first, now: now) == .escalate)
    }

    // MARK: - stale 低频 uncertain 通知

    @Test func staleRequestsStaySilentUnlessOriginallyStrongBlocking() {
        let strongStale = makeStaleOriginallyStrong(id: "strong-stale")
        let weakStale = makeRequest(
            id: "weak-stale",
            kind: .reviewRequired,
            status: .stale,
            confidence: .structuredHook
        )
        let lowConfidenceStale = makeRequest(
            id: "low-confidence-stale",
            kind: .permissionRequired,
            status: .stale,
            confidence: .genericObservation
        )

        #expect(StaleNotificationPolicy.evaluate(request: strongStale, now: now) == .notifyOnceUncertain)
        #expect(StaleNotificationPolicy.evaluate(request: weakStale, now: now) == .silent(.notOriginallyStrongBlocking))
        #expect(StaleNotificationPolicy.evaluate(request: lowConfidenceStale, now: now) == .silent(.notOriginallyStrongBlocking))
    }

    @Test func staleUncertainNotificationFiresAtMostOncePerObligation() {
        var alreadyNotified = makeStaleOriginallyStrong(id: "notified-stale")
        alreadyNotified.escalationCount = 1
        alreadyNotified.lastEscalatedAt = now.addingTimeInterval(-300)

        let verdict = StaleNotificationPolicy.evaluate(request: alreadyNotified, now: now)

        #expect(verdict == .silent(.obligationAlreadyInterrupted(escalationCount: 1)))
    }

    @Test func staleUncertainNotificationRespectsLowFrequencyThrottleAndMuteAndToggle() {
        let stale = makeStaleOriginallyStrong(id: "stale-throttle")
        var throttle = InterruptionThrottleState()
        #expect(throttle.staleWindow >= 300)

        throttle.recordStaleNotification(at: now.addingTimeInterval(-throttle.staleWindow + 10))
        let throttled = StaleNotificationPolicy.evaluate(request: stale, now: now, throttle: throttle)
        if case let .silent(reason) = throttled {
            guard case .staleThrottleWindow = reason else {
                Issue.record("expected stale throttle, got \(reason)")
                return
            }
        } else {
            Issue.record("expected stale throttle silence, got \(throttled)")
        }

        throttle.recordStaleNotification(at: now.addingTimeInterval(-throttle.staleWindow))
        #expect(StaleNotificationPolicy.evaluate(request: stale, now: now, throttle: throttle) == .notifyOnceUncertain)

        let muted = StaleNotificationPolicy.evaluate(
            request: stale,
            now: now,
            mutedSessionKeys: [stale.sessionKey]
        )
        #expect(muted == .silent(.mutedWorkspace))

        let disabled = StaleNotificationPolicy.evaluate(
            request: stale,
            now: now,
            notificationsEnabled: false
        )
        #expect(disabled == .silent(.notificationsDisabled))
    }

    @Test func nonStaleRequestsNeverProduceUncertainNotifications() {
        let active = makeRequest(kind: .permissionRequired, status: .unseen, confidence: .structuredHook)

        #expect(StaleNotificationPolicy.evaluate(request: active, now: now) == .silent(.notStale))
    }

    // MARK: - fixtures

    private func makeRequest(
        id: String = "fixture",
        kind: AttentionRequestKind,
        status: AttentionRequestStatus,
        confidence: AttentionSourceConfidence
    ) -> AttentionRequest {
        AttentionRequest(
            key: .supervisedWorkflow(workflowID: id, requestID: id),
            sessionKey: .traeX(sessionID: id),
            kind: kind,
            status: status,
            createdAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-300),
            evidence: [AttentionRequestEvidence(eventName: "fixture", observedAt: now)],
            sourceConfidence: confidence
        )
    }

    private func makeStaleOriginallyStrong(id: String) -> AttentionRequest {
        makeRequest(id: id, kind: .permissionRequired, status: .stale, confidence: .structuredHook)
    }
}
