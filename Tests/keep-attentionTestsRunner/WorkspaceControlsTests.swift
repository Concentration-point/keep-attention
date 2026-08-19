import Foundation
import Testing
@testable import KeepAttentionCore

// issue #34：Workspace 控制（mute / AI summary opt-in）+ AI 摘要白名单最小 payload、
// 长度上限、不落原始 payload、fail-open 回退本地确定性文案；以及本地历史清理的纯逻辑。
@Suite struct WorkspaceControlsTests {
    private let now = Date(timeIntervalSince1970: 1_787_200_000)

    // MARK: - mute / AI opt-in 状态

    @Test func muteTogglesPersistPerWorkspaceAndDefaultToUnmuted() {
        var state = WorkspaceControlsState()
        #expect(state.isMuted("keep-attention") == false)

        state.setMuted("keep-attention", muted: true)
        state.setMuted("other-repo", muted: true)
        state.setMuted("other-repo", muted: false)

        #expect(state.isMuted("keep-attention") == true)
        #expect(state.isMuted("other-repo") == false)
    }

    @Test func aiSummaryRequiresBothGlobalOptInAndPerWorkspaceOptIn() {
        var state = WorkspaceControlsState()
        state.setAISummaryOptIn("keep-attention", enabled: true)

        #expect(state.isAISummaryEnabled("keep-attention", globalAISummaryEnabled: true) == true)
        #expect(state.isAISummaryEnabled("keep-attention", globalAISummaryEnabled: false) == false)
        #expect(state.isAISummaryEnabled("not-opted-in", globalAISummaryEnabled: true) == false)
    }

    @Test func workspaceControlsStateRoundTripsThroughCodablePersistence() throws {
        var state = WorkspaceControlsState()
        state.setMuted("muted-repo", muted: true)
        state.setAISummaryOptIn("ai-repo", enabled: true)

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(WorkspaceControlsState.self, from: data)

        #expect(restored == state)
        #expect(restored.isMuted("muted-repo"))
        #expect(restored.isAISummaryEnabled("ai-repo", globalAISummaryEnabled: true))
    }

    // MARK: - AI 白名单最小 payload

    @Test func whitelistedContextCarriesOnlyMinimalSafeFragments() throws {
        let context = AISummaryPolicy.makeWhitelistedContext(
            repo: "/Users/private/keep-attention",
            branch: "feature/private-branch",
            kindLabel: "Permission required",
            needFromYou: "Approve or deny in TraeX.",
            evidenceEventLabels: ["Permission requested", "State needs confirmation"]
        )

        #expect(context.tail.isEmpty)
        #expect(context.title == nil)
        #expect(context.repo == "workspace")
        #expect(context.branch == nil)
        let payload = context.agentMessage ?? ""
        for forbidden in ["/Users/", "private-branch", "worktree", "sessionID", "correlationLabel", "terminal title"] {
            #expect(!payload.contains(forbidden))
        }
        #expect(payload.contains("Permission required"))
    }

    @Test func whitelistedContextRedactsSecretsAndCapsLength() {
        let longNeed = String(repeating: "需要确认这一步操作，", count: 200)
        let context = AISummaryPolicy.makeWhitelistedContext(
            repo: "keep-attention",
            branch: "main",
            kindLabel: "Permission required",
            needFromYou: "api_key=super-secret-value \(longNeed)",
            evidenceEventLabels: ["Permission requested"]
        )

        let payload = context.agentMessage ?? ""
        #expect(!payload.contains("super-secret-value"))
        #expect(payload.contains("[REDACTED_SECRET]"))
        #expect(payload.count <= AISummaryPolicy.maxPayloadCharacters + 64)
    }

    @Test func whitelistedContextCapsEvidenceEventLabelCount() {
        let labels = (0..<20).map { "event-\($0)" }
        let context = AISummaryPolicy.makeWhitelistedContext(
            repo: "keep-attention",
            branch: nil,
            kindLabel: "Permission required",
            needFromYou: "Approve or deny in TraeX.",
            evidenceEventLabels: labels
        )

        let payload = context.agentMessage ?? ""
        #expect(payload.contains("event-0"))
        #expect(!payload.contains("event-\(AISummaryPolicy.maxEvidenceEventLabels)"))
    }

    // MARK: - fail-open

    @Test func enhanceFallsBackToDeterministicCopyWhenProviderFails() async {
        struct FailingProvider: SummaryProviding {
            func summarize(context: SummaryContext) async throws -> TerminalSummary {
                throw DeepSeekError.missingAPIKey
            }
        }
        let fallback = RequestDisplayCopy.deterministicFallback()

        let result = await AISummaryPolicy.enhance(
            context: AISummaryPolicy.makeWhitelistedContext(
                repo: "keep-attention",
                branch: nil,
                kindLabel: "Permission required",
                needFromYou: "Approve or deny in TraeX.",
                evidenceEventLabels: []
            ),
            provider: FailingProvider(),
            fallback: fallback
        )

        #expect(result == fallback)
    }

    @Test func enhanceUsesProviderSummaryButCapsDisplayLength() async {
        struct OverlongProvider: SummaryProviding {
            func summarize(context: SummaryContext) async throws -> TerminalSummary {
                TerminalSummary(
                    currentTask: String(repeating: "长", count: 500),
                    progress: "ok",
                    nextStep: "ok",
                    needsInput: "无"
                )
            }
        }
        let fallback = RequestDisplayCopy.deterministicFallback()

        let result = await AISummaryPolicy.enhance(
            context: AISummaryPolicy.makeWhitelistedContext(
                repo: "keep-attention",
                branch: nil,
                kindLabel: "Permission required",
                needFromYou: "Approve or deny in TraeX.",
                evidenceEventLabels: []
            ),
            provider: OverlongProvider(),
            fallback: fallback
        )

        #expect(result.sourceLabel == RequestDisplayCopy.aiSourceLabel)
        #expect(result.whyAttention.count <= AISummaryPolicy.maxDisplayCharacters)
        #expect(result.needFromYou.count <= AISummaryPolicy.maxDisplayCharacters)
    }

    @Test func enhanceReturnsDisplayCopyOnlyWithoutRawPayload() async {
        struct RecordingProvider: SummaryProviding {
            func summarize(context: SummaryContext) async throws -> TerminalSummary {
                TerminalSummary(currentTask: "整理上下文", progress: "已到验证", nextStep: "等待确认", needsInput: "批准权限")
            }
        }
        let fallback = RequestDisplayCopy.deterministicFallback()

        let result = await AISummaryPolicy.enhance(
            context: AISummaryPolicy.makeWhitelistedContext(
                repo: "keep-attention",
                branch: "main",
                kindLabel: "Permission required",
                needFromYou: "Approve or deny in TraeX.",
                evidenceEventLabels: ["Permission requested"]
            ),
            provider: RecordingProvider(),
            fallback: fallback
        )

        let encoded = String(decoding: try! JSONEncoder().encode(result), as: UTF8.self)
        #expect(encoded.contains("整理上下文"))
        #expect(!encoded.contains("agentMessage"))
        #expect(!encoded.contains("tail"))
        #expect(!encoded.contains("repo"))
    }

    // MARK: - 本地历史清理（Dismiss stale / clear local history 纯逻辑）

    @Test func staleDismissalRemovesOnlyStaleHistoryAndKeepsActiveRequests() {
        let staleStrong = makeClosed(id: "stale-strong", status: .stale)
        let staleWeak = makeClosed(id: "stale-weak", status: .stale)
        let resolved = makeClosed(id: "resolved", status: .resolved)
        let active = makeActive(id: "active")
        let snapshot = AttentionRequestPersistenceSnapshot(
            activeRequests: [active],
            closedHistory: [staleStrong, staleWeak, resolved]
        )

        let dismissed = StaleDismissal.dismissStale(in: snapshot)

        #expect(dismissed.activeRequests == [active])
        #expect(dismissed.closedHistory.map(\.key) == [resolved.key])
        #expect(dismissed.closedHistory.first?.status == .resolved)
    }

    @Test func staleDismissalCanTargetSpecificKeysOnly() {
        let first = makeClosed(id: "stale-1", status: .stale)
        let second = makeClosed(id: "stale-2", status: .stale)
        let snapshot = AttentionRequestPersistenceSnapshot(activeRequests: [], closedHistory: [first, second])

        let dismissed = StaleDismissal.dismissStale(
            in: snapshot,
            matching: [first.key]
        )

        #expect(dismissed.closedHistory.map(\.key) == [second.key])
    }

    @Test func clearingLocalHistoryEmptiesClosedHistoryButKeepsActiveObligations() {
        let active = makeActive(id: "active-keep")
        let snapshot = AttentionRequestPersistenceSnapshot(
            activeRequests: [active],
            closedHistory: [makeClosed(id: "stale", status: .stale), makeClosed(id: "resolved", status: .resolved)]
        )

        let cleared = LocalHistoryClearance.clearClosedHistory(in: snapshot)

        #expect(cleared.closedHistory.isEmpty)
        #expect(cleared.activeRequests == [active])
    }

    // MARK: - fixtures

    private func makeActive(id: String) -> AttentionRequest {
        AttentionRequest(
            key: .supervisedWorkflow(workflowID: id, requestID: id),
            sessionKey: .supervisedWorkflow(workflowID: id),
            kind: .permissionRequired,
            status: .unseen,
            createdAt: now,
            updatedAt: now,
            evidence: []
        )
    }

    private func makeClosed(id: String, status: AttentionRequestStatus) -> AttentionRequest {
        AttentionRequest(
            key: .supervisedWorkflow(workflowID: id, requestID: id),
            sessionKey: .supervisedWorkflow(workflowID: id),
            kind: .permissionRequired,
            status: status,
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-60),
            evidence: []
        )
    }
}
