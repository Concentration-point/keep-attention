import Foundation
import Testing
@testable import KeepAttentionCore

@Suite struct SessionOverviewTests {
    private let now = Date(timeIntervalSince1970: 1_787_300_000)

    @Test func adapterBuildsSessionOverviewFromStructuredAgentsWithoutTailOrPreviewInference() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        let terminalRead: TerminalReadResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalRead))
        var terminals = list.terminals
        terminals[3].preview = "Preview says: 用户必须选择 A/B, but preview is not a semantic source"

        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(worktrees: ps.worktrees, terminals: terminals, layouts: list.visualLayouts),
            supervisedSignals: [],
            observedAt: now,
            terminalReads: [terminalRead.terminal]
        )

        #expect(result.events.isEmpty)
        let structuredDone = try #require(result.ambient.entries.first { $0.terminalHandle == "term_B1" })
        #expect(structuredDone.coverage == .structuredAgent)
        #expect(structuredDone.classification == .notRequest)
        #expect(structuredDone.session.currentTask == "claude")
        #expect(structuredDone.session.progress == "State: done")
        #expect(structuredDone.session.nextStep == "Review the latest structured reply in Orca.")
        #expect(structuredDone.session.needsInput == "Unknown · not request")
        #expect(structuredDone.session.sourceConfidence == "structured agent · deterministic local fallback · AI disabled")
        #expect(structuredDone.session.summaryFingerprint != nil)
        #expect(structuredDone.session.updatedAt == Date(timeIntervalSince1970: 1_786_990_000))

        let gap = try #require(result.ambient.entries.first { $0.terminalHandle == "term_A3" })
        #expect(gap.coverage == .coverageGap)
        #expect(gap.session.currentTask == "Coverage gap")
        #expect(gap.session.progress == "No structured agent matched this terminal.")
        #expect(gap.session.nextStep == "Open the source terminal if you need details.")
        #expect(gap.session.needsInput == "Unknown · not request")
        #expect(gap.session.summaryFingerprint == nil)
        let projection = AttentionQueueProjection.make(
            store: AttentionRequestStore(),
            ambient: AmbientOverview(entries: [gap]),
            now: now,
            aiSummariesEnabled: false
        )
        let encodedGap = String(decoding: try JSONEncoder().encode(projection.ambient), as: UTF8.self)
        #expect(!encodedGap.contains("用户必须选择 A/B"))
        #expect(!encodedGap.contains("下一个问题"))
    }

    @Test func sessionOverviewOrderingIsDeterministicAndIgnoresAIText() throws {
        let entries = [
            entry(handle: "z-disconnected", repo: "zeta", branch: "main", connected: false, focused: false, activity: .busy, coverage: .structuredAgent, updatedAt: now.addingTimeInterval(70), currentTask: "AI says urgent"),
            entry(handle: "e-idle", repo: "echo", branch: "main", connected: true, focused: false, activity: .idle, coverage: .structuredAgent, updatedAt: now.addingTimeInterval(10), currentTask: "idle"),
            entry(handle: "d-gap", repo: "delta", branch: "main", connected: true, focused: false, activity: .busy, coverage: .coverageGap, updatedAt: now.addingTimeInterval(20), currentTask: "gap"),
            entry(handle: "c-focused", repo: "charlie", branch: "main", connected: true, focused: true, activity: .idle, coverage: .coverageGap, updatedAt: now.addingTimeInterval(30), currentTask: "focused"),
            entry(handle: "b-recent", repo: "bravo", branch: "main", connected: true, focused: false, activity: .idle, coverage: .structuredAgent, updatedAt: now.addingTimeInterval(40), currentTask: "recent complete"),
            entry(handle: "a-working", repo: "alpha", branch: "main", connected: true, focused: false, activity: .busy, coverage: .structuredAgent, updatedAt: now.addingTimeInterval(0), currentTask: "working"),
        ]

        let projection = AttentionQueueProjection.make(
            store: AttentionRequestStore(),
            ambient: AmbientOverview(entries: entries),
            now: now.addingTimeInterval(100),
            aiSummariesEnabled: false
        )

        #expect(projection.ambient.map(\.displayName) == [
            "alpha · main",
            "bravo · main",
            "charlie · main",
            "delta · main",
            "echo · main",
            "zeta · main",
        ])
        #expect(projection.ambient.first?.currentTask == "working")
        #expect(projection.ambient.last?.currentTask == "AI says urgent")
    }

    @MainActor
    @Test func summaryRuntimeRequiresWorkspaceOptInDedupesByFingerprintAndCachesPerSession() async throws {
        let clock = MutableClock(now)
        let defaults = TestDefaults()
        let psBox = LockedBox(twoStructuredRepliesPS(messageA: "first full assistant reply", messageB: "second full assistant reply"))
        let provider = RecordingSummaryProvider(summary: TerminalSummary(
            currentTask: "AI current task",
            progress: "AI progress",
            nextStep: "AI next step",
            needsInput: "无"
        ))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: psBox),
            jumper: nil,
            defaults: defaults,
            summaryProvider: provider,
            now: { clock.current }
        )

        await model.pollOrcaOnce()
        #expect(provider.contexts().isEmpty)
        #expect(model.projection.ambient.first?.sourceConfidenceLabel == "structured agent · deterministic local fallback · AI disabled")

        model.setAISummaryOptIn("repoA", enabled: true)
        await model.pollOrcaOnce()
        #expect(provider.contexts().count == 2)
        #expect(model.projection.ambient.filter { $0.sourceConfidenceLabel == "AI summary · whitelisted structured agent payload" }.count == 2)

        await model.pollOrcaOnce()
        #expect(provider.contexts().count == 2)

        psBox.with { $0 = twoStructuredRepliesPS(messageA: "first full assistant reply changed", messageB: "second full assistant reply") }
        await model.pollOrcaOnce()
        #expect(provider.contexts().count == 3)
    }

    @MainActor
    @Test func summaryProviderReceivesOnlyWhitelistedStructuredContextAndNoRawTerminalData() async throws {
        let defaults = TestDefaults()
        let rawReply = "Structured reply with api_key=secret-value user@example.com /Users/bytedance/private"
        let psBox = LockedBox(sensitiveStructuredReplyPS(rawReply: rawReply))
        let provider = RecordingSummaryProvider(summary: TerminalSummary(
            currentTask: "安全任务",
            progress: "安全进度",
            nextStep: "安全下一步",
            needsInput: "无"
        ))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: psBox),
            jumper: nil,
            defaults: defaults,
            summaryProvider: provider,
            now: { self.now }
        )
        model.setAISummaryOptIn("repoA", enabled: true)

        await model.pollOrcaOnce()

        let context = try #require(provider.contexts().first)
        #expect(context.repo == "repoA")
        #expect(context.branch == "main")
        #expect(context.title == nil)
        #expect(context.tail.isEmpty)
        let payload = try #require(context.agentMessage)
        #expect(payload.contains("local_state_label: done"))
        #expect(payload.contains("local_task_label: Review sensitive change"))
        #expect(payload.contains("sanitized_tool_name: Bash"))
        #expect(payload.contains("Structured reply with"))
        #expect(payload.contains("[REDACTED_SECRET]"))
        #expect(payload.contains("[REDACTED_EMAIL]"))
        #expect(payload.contains("/Users/[USER]/private"))
        for forbidden in ["secret-value", "user@example.com", "/Users/bytedance/", "tool-body-secret", "terminal preview secret", "term_A2", "tab2", "leaf2"] {
            #expect(!payload.contains(forbidden))
        }
        #expect(payload.count <= AISummaryPolicy.maxPayloadCharacters + 64)

        let longMarker = "MIDDLE_PRIVATE_BODY_MUST_NOT_LEAVE_PROCESS"
        let longContext = AISummaryPolicy.makeSessionOverviewContext(
            repo: "repoA",
            branch: "main",
            state: "done",
            taskLabel: "Review",
            toolName: "Bash",
            assistantReply: String(repeating: "A", count: 400)
                + longMarker
                + String(repeating: "Z", count: 400)
        )
        #expect(longContext.agentMessage?.contains(longMarker) == false)
        #expect(longContext.agentMessage?.contains("[中间内容仅本地保留]") == true)
    }

    @MainActor
    @Test func providerFailureFallsBackAndPersistenceStoresOnlyDisplaySafeSummaryAndFingerprint() async throws {
        let defaults = TestDefaults()
        let psBox = LockedBox(sensitiveStructuredReplyPS(rawReply: "RAW_ASSISTANT_SECRET should never persist"))
        let provider = RecordingSummaryProvider(summary: TerminalSummary(
            currentTask: "持久化安全摘要",
            progress: "安全进度",
            nextStep: "安全下一步",
            needsInput: "无"
        ))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: psBox),
            jumper: nil,
            defaults: defaults,
            summaryProvider: provider,
            now: { self.now }
        )
        model.setAISummaryOptIn("repoA", enabled: true)

        await model.pollOrcaOnce()

        #expect(model.projection.ambient.first?.currentTask == "持久化安全摘要")
        let data = try #require(defaults.data(forKey: AttentionQueueModel.runtimeStorageKey))
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(encoded.contains("持久化安全摘要"))
        #expect(encoded.contains("summaryFingerprint"))
        #expect(!encoded.contains("RAW_ASSISTANT_SECRET"))
        #expect(!encoded.contains("Review sensitive change"))
        #expect(!encoded.contains("tool-body-secret"))
        #expect(!encoded.contains("term_A2"))
        #expect(!encoded.contains("tab2"))
        #expect(!encoded.contains("leaf2"))

        let failing = AttentionQueueModel(
            orca: makeOrca(ps: psBox),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: RecordingSummaryProvider(error: DeepSeekError.badResponse("malformed")),
            now: { self.now }
        )
        failing.setAISummaryOptIn("repoA", enabled: true)
        await failing.pollOrcaOnce()
        #expect(failing.projection.ambient.first?.currentTask == "Review sensitive change")
        #expect(failing.projection.ambient.first?.sourceConfidenceLabel == "structured agent · deterministic local fallback · AI unavailable")
    }


    @MainActor
    @Test func traeXStopUpdatesSessionOverviewDedupesAndDoesNotAffectQueueTruth() async throws {
        let defaults = TestDefaults()
        let provider = RecordingSummaryProvider(summary: TerminalSummary(
            currentTask: "AI TraeX task",
            progress: "AI TraeX progress",
            nextStep: "AI TraeX next",
            needsInput: "无"
        ))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(Fixtures.worktreePS)),
            jumper: nil,
            defaults: defaults,
            summaryProvider: provider,
            now: { self.now }
        )
        model.applyOrcaSnapshot(try makeSnapshot())
        model.setAISummaryOptIn("repoA", enabled: true)
        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.sessionStart,
            sessionId: "traex-session-a",
            cwd: "/Users/dev/orca/repoA"
        ))
        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.userPromptSubmit,
            sessionId: "traex-session-a",
            turnId: "turn-a",
            cwd: "/Users/dev/orca/repoA",
            prompt: "full prompt secret api_key=prompt-secret user@example.com /Users/bytedance/private"
        ))
        #expect(model.projection.ambient.contains { entry in
            entry.displayName == "repoA · TraeX" && entry.currentTask == "TraeX task submitted"
        })
        let afterPrompt = String(decoding: try #require(defaults.data(forKey: AttentionQueueModel.runtimeStorageKey)), as: UTF8.self)
        #expect(!afterPrompt.contains("prompt-secret"))
        #expect(!afterPrompt.contains("full prompt secret"))

        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.permissionRequest,
            sessionId: "request-session",
            turnId: "request-turn",
            cwd: "/Users/dev/orca/repoA",
            toolUseId: "request-tool",
            toolName: "Bash"
        ))
        let headBeforeStop = model.headRequest?.key

        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.stop,
            sessionId: "traex-session-a",
            turnId: "turn-a",
            cwd: "/Users/dev/orca/repoA",
            lastAssistantMessage: "complete reply raw secret should not persist"
        ))
        try await waitUntil { provider.contexts().count == 1 }
        #expect(model.projection.requestCount == 1)
        #expect(model.headRequest?.key == headBeforeStop)
        #expect(model.projection.ambient.contains { entry in
            entry.displayName == "repoA · TraeX" && entry.currentTask == "AI TraeX task"
        })

        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.stop,
            sessionId: "traex-session-a",
            turnId: "turn-a",
            cwd: "/Users/dev/orca/repoA",
            lastAssistantMessage: "complete reply raw secret should not persist"
        ))
        try await shortDelay()
        #expect(provider.contexts().count == 1)

        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.stop,
            sessionId: "traex-session-b",
            turnId: "turn-b",
            cwd: "/Users/dev/orca/repoA",
            lastAssistantMessage: "complete reply raw secret should not persist"
        ))
        try await waitUntil { provider.contexts().count == 2 }
        let persisted = String(decoding: try #require(defaults.data(forKey: AttentionQueueModel.runtimeStorageKey)), as: UTF8.self)
        #expect(!persisted.contains("complete reply raw secret"))
        #expect(!persisted.contains("traex-session-a"))
        #expect(!persisted.contains("traex-session-b"))
    }

    @MainActor
    @Test func legacyRuntimePayloadWithoutSessionSummariesStillRestoresRequestsAndSessionKnowledge() async throws {
        struct LegacyPayload: Codable {
            var snapshot: AttentionRequestPersistenceSnapshot
            var seenTraeXSessionIDs: [String]
            var traeXSessionCWDMappings: [String: String]
        }
        let defaults = TestDefaults()
        var store = AttentionRequestStore()
        store.apply(.traeXPermissionRequested(
            sessionID: "legacy-session",
            turnID: "legacy-turn",
            toolUseID: "legacy-tool",
            toolName: "Bash",
            observedAt: now
        ))
        let legacy = LegacyPayload(
            snapshot: store.snapshot(now: now),
            seenTraeXSessionIDs: ["legacy-session"],
            traeXSessionCWDMappings: ["legacy-session": "/Users/dev/orca/repoA"]
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: AttentionQueueModel.runtimeStorageKey)

        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(Fixtures.worktreePS)),
            jumper: nil,
            defaults: defaults,
            summaryProvider: nil,
            now: { self.now.addingTimeInterval(60) }
        )

        #expect(model.projection.staleHistory.count == 1)
        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.permissionRequest,
            sessionId: "legacy-session",
            turnId: "legacy-turn-2",
            cwd: "/Users/dev/orca/repoA",
            toolUseId: "legacy-tool-2",
            toolName: "Bash"
        ))
        #expect(model.lastTraeXDiscovery == nil)
        await model.pollOrcaOnce()
        #expect(model.jumpReference(for: try #require(model.headRequest))?.terminalHandle == "term_A2")
    }

    @MainActor
    @Test func sessionSummaryCacheIsBoundedPerSessionAndOverwritesOldFingerprints() async throws {
        let defaults = TestDefaults()
        let provider = RecordingSummaryProvider(summary: TerminalSummary(
            currentTask: "cached task",
            progress: "cached progress",
            nextStep: "cached next",
            needsInput: "无"
        ))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(Fixtures.worktreePS)),
            jumper: nil,
            defaults: defaults,
            summaryProvider: provider,
            now: { self.now }
        )
        model.applyOrcaSnapshot(try makeSnapshot())
        model.setAISummaryOptIn("repoA", enabled: true)
        for index in 0..<3 {
            model.applyTraeXEvent(TraeXEvent(
                hookEventName: TraeXEvent.stop,
                sessionId: "bounded-session",
                turnId: "turn-\(index)",
                cwd: "/Users/dev/orca/repoA",
                lastAssistantMessage: "reply version \(index)"
            ))
            try await waitUntil { provider.contexts().count == index + 1 }
        }
        var payload = try JSONDecoder().decode(
            AttentionQueueRuntimePayload.self,
            from: try #require(defaults.data(forKey: AttentionQueueModel.runtimeStorageKey))
        )
        #expect(payload.sessionSummaries.count == 1)

        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.stop,
            sessionId: "bounded-session-2",
            turnId: "turn-other",
            cwd: "/Users/dev/orca/repoA",
            lastAssistantMessage: "reply other"
        ))
        try await waitUntil { provider.contexts().count == 4 }
        payload = try JSONDecoder().decode(
            AttentionQueueRuntimePayload.self,
            from: try #require(defaults.data(forKey: AttentionQueueModel.runtimeStorageKey))
        )
        #expect(payload.sessionSummaries.count == 2)
    }

    @MainActor
    @Test func providerFailureForSameFingerprintCanRetryLater() async throws {
        let provider = RecordingSummaryProvider(error: DeepSeekError.badResponse("malformed"))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(sensitiveStructuredReplyPS(rawReply: "retry same reply"))),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: provider,
            now: { self.now }
        )
        model.setAISummaryOptIn("repoA", enabled: true)

        await model.pollOrcaOnce()
        await model.pollOrcaOnce()

        #expect(provider.contexts().count == 2)
        #expect(model.projection.ambient.first?.sourceConfidenceLabel == "structured agent · deterministic local fallback · AI unavailable")
    }

    @MainActor
    @Test func concurrentPollsCoalesceTheSameSessionFingerprint() async throws {
        let provider = ControllableSummaryProvider()
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(sensitiveStructuredReplyPS(rawReply: "coalesced reply"))),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: provider,
            now: { self.now }
        )
        model.setAISummaryOptIn("repoA", enabled: true)

        async let first: Void = model.pollOrcaOnce()
        try await waitUntil { provider.contexts().count == 1 }
        async let second: Void = model.pollOrcaOnce()
        try await shortDelay()

        #expect(provider.contexts().count == 1)
        provider.resumeAll(with: TerminalSummary(
            currentTask: "coalesced task",
            progress: "coalesced progress",
            nextStep: "coalesced next",
            needsInput: "未知"
        ))
        _ = await (first, second)
        #expect(model.projection.ambient.first?.currentTask == "coalesced task")
    }

    @MainActor
    @Test func summaryProviderConcurrencyIsBounded() async throws {
        let provider = ControllableSummaryProvider()
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(Fixtures.worktreePS)),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: provider,
            now: { self.now }
        )
        model.applyOrcaSnapshot(try makeSnapshot())
        model.setAISummaryOptIn("repoA", enabled: true)

        for index in 0..<6 {
            model.applyTraeXEvent(TraeXEvent(
                hookEventName: TraeXEvent.stop,
                sessionId: "bounded-concurrency-\(index)",
                turnId: "turn-\(index)",
                cwd: "/Users/dev/orca/repoA",
                lastAssistantMessage: "Reply \(index)"
            ))
        }
        try await waitUntil { provider.contexts().count == 3 }
        try await shortDelay()
        #expect(provider.contexts().count == 3)
        #expect(provider.peakActiveCount() == 3)

        provider.resumePending(with: TerminalSummary(
            currentTask: "bounded task",
            progress: "bounded progress",
            nextStep: "bounded next",
            needsInput: "未知"
        ))
        try await waitUntil { provider.contexts().count == 6 }
        provider.resumePending(with: TerminalSummary(
            currentTask: "bounded task",
            progress: "bounded progress",
            nextStep: "bounded next",
            needsInput: "未知"
        ))
        try await waitUntil {
            model.projection.ambient.filter { $0.currentTask == "bounded task" }.count == 6
        }
    }

    @MainActor
    @Test func staleSummaryCannotOverwriteNewFingerprintAndOptOutInvalidatesInFlightResult() async throws {
        let provider = ControllableSummaryProvider()
        let psBox = LockedBox(sensitiveStructuredReplyPS(rawReply: "reply A"))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: psBox),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: provider,
            now: { self.now }
        )
        model.setAISummaryOptIn("repoA", enabled: true)

        async let first: Void = model.pollOrcaOnce()
        try await waitUntil { provider.contexts().count == 1 }
        psBox.with { $0 = sensitiveStructuredReplyPS(rawReply: "reply B") }
        async let second: Void = model.pollOrcaOnce()
        try await waitUntil { provider.contexts().count == 2 }

        provider.resume(index: 1, with: TerminalSummary(
            currentTask: "new task",
            progress: "new progress",
            nextStep: "new next",
            needsInput: "未知"
        ))
        try await waitUntil { model.projection.ambient.first?.currentTask == "new task" }
        provider.resume(index: 0, with: TerminalSummary(
            currentTask: "stale task",
            progress: "stale progress",
            nextStep: "stale next",
            needsInput: "未知"
        ))
        _ = await (first, second)
        #expect(model.projection.ambient.first?.currentTask == "new task")

        psBox.with { $0 = sensitiveStructuredReplyPS(rawReply: "reply C") }
        async let third: Void = model.pollOrcaOnce()
        try await waitUntil { provider.contexts().count == 3 }
        model.setAISummaryOptIn("repoA", enabled: false)
        provider.resume(index: 2, with: TerminalSummary(
            currentTask: "must not appear",
            progress: "must not appear",
            nextStep: "must not appear",
            needsInput: "无"
        ))
        await third
        #expect(model.projection.ambient.first?.currentTask == "Review sensitive change")
        #expect(model.projection.ambient.first?.sourceConfidenceLabel.contains("AI disabled") == true)
    }

    @MainActor
    @Test func summaryLoadingIsSessionLocalAndUpdatedTimeIsUserVisible() async throws {
        let provider = ControllableSummaryProvider()
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(sensitiveStructuredReplyPS(rawReply: "loading reply"))),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: provider,
            now: { self.now }
        )
        model.setAISummaryOptIn("repoA", enabled: true)

        async let poll: Void = model.pollOrcaOnce()
        try await waitUntil { provider.contexts().count == 1 }
        let loading = try #require(model.projection.ambient.first { $0.workspaceID == "repoA" })
        #expect(loading.summaryStatusLabel == "AI summary loading")
        #expect(loading.updatedTimeLabel.hasPrefix("Updated "))

        provider.resumeAll(with: TerminalSummary(
            currentTask: "loaded task",
            progress: "loaded progress",
            nextStep: "loaded next",
            needsInput: "未知"
        ))
        await poll
        #expect(model.projection.ambient.first?.summaryStatusLabel == nil)
    }

    @MainActor
    @Test func sessionEndRemovesTraeXOverviewAndCompletedReplyDoesNotClaimNoInput() async throws {
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(Fixtures.worktreePS)),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: nil,
            now: { self.now }
        )
        model.applyOrcaSnapshot(try makeSnapshot())
        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.stop,
            sessionId: "ended-session",
            cwd: "/Users/dev/orca/repoA",
            lastAssistantMessage: "请选择 A 或 B"
        ))
        let row = try #require(model.projection.ambient.first { $0.displayName == "repoA · TraeX" })
        #expect(row.needsInput == "Unknown · not request")

        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.sessionEnd,
            sessionId: "ended-session",
            cwd: "/Users/dev/orca/repoA"
        ))
        #expect(!model.projection.ambient.contains { $0.displayName == "repoA · TraeX" })
    }

    @MainActor
    @Test func traeXOverviewIsBoundedWhenSessionEndIsMissing() throws {
        let clock = MutableClock(now)
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(Fixtures.worktreePS)),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: nil,
            now: { clock.current }
        )
        model.applyOrcaSnapshot(try makeSnapshot())

        for index in 0..<30 {
            clock.current = now.addingTimeInterval(TimeInterval(index))
            model.applyTraeXEvent(TraeXEvent(
                hookEventName: TraeXEvent.userPromptSubmit,
                sessionId: "missing-end-\(index)",
                cwd: "/Users/dev/orca/repoA"
            ))
        }

        let traeXRows = model.projection.ambient.filter { $0.displayName == "repoA · TraeX" }
        #expect(traeXRows.count == 25)
        #expect(traeXRows.allSatisfy { $0.updatedAt ?? .distantPast >= now.addingTimeInterval(5) })
    }

    @MainActor
    @Test func sessionOverviewUIOptInCommandReachesModelAndNextPollUsesProvider() async throws {
        let provider = RecordingSummaryProvider(summary: TerminalSummary(
            currentTask: "UI opted task",
            progress: "UI opted progress",
            nextStep: "UI opted next",
            needsInput: "无"
        ))
        let model = AttentionQueueModel(
            orca: makeOrca(ps: LockedBox(sensitiveStructuredReplyPS(rawReply: "ui opt in reply"))),
            jumper: nil,
            defaults: TestDefaults(),
            summaryProvider: provider,
            now: { self.now }
        )
        await model.pollOrcaOnce()
        #expect(provider.contexts().isEmpty)
        let row = try #require(model.projection.ambient.filter { $0.workspaceID == "repoA" }.first)
        #expect(row.showsAIOptInControl)
        #expect(row.isAISummaryOptedIn == false)

        let actions = AttentionQueueActions.live(model: model)
        actions.onSetAISummaryOptIn?("repoA", true)
        #expect(model.projection.ambient.filter { $0.workspaceID == "repoA" }.first?.isAISummaryOptedIn == true)
        await model.pollOrcaOnce()

        #expect(provider.contexts().count == 1)
        #expect(model.projection.ambient.filter { $0.workspaceID == "repoA" }.first?.currentTask == "UI opted task")
    }

    @Test func defaultSummaryProviderFactoryRequiresAPIKey() {
        #expect(SummaryProviderFactory.deepSeekFromEnvironment([:]) == nil)
        #expect(SummaryProviderFactory.deepSeekFromEnvironment(["DEEPSEEK_API_KEY": "sk-test"]) != nil)
    }

    @MainActor
    @Test func promptFallbackNeverLeaksRawPromptToDisplayOrPersistence() async throws {
        let rawPrompt = String(repeating: "very long prompt ", count: 40)
            + "api_key=secret123 user@example.com /Users/bytedance/private"
        let psBox = LockedBox(promptOnlyAgentPS(prompt: rawPrompt))
        let defaults = TestDefaults()
        let model = AttentionQueueModel(
            orca: makeOrca(ps: psBox),
            jumper: nil,
            defaults: defaults,
            summaryProvider: nil,
            now: { self.now }
        )
        await model.pollOrcaOnce()

        let encodedProjection = String(decoding: try JSONEncoder().encode(model.projection.ambient), as: UTF8.self)
        #expect(!encodedProjection.contains("secret123"))
        #expect(!encodedProjection.contains("user@example.com"))
        #expect(!encodedProjection.contains("/Users/bytedance/"))
        #expect(!encodedProjection.contains("very long prompt"))
        #expect(model.projection.ambient.first?.currentTask == "grok")
        let persisted = String(decoding: try #require(defaults.data(forKey: AttentionQueueModel.runtimeStorageKey)), as: UTF8.self)
        #expect(!persisted.contains("secret123"))
        #expect(!persisted.contains("very long prompt"))
    }

    @Test func projectionKeepsAttentionQueuePrimaryForThreeSixAndTenSessions() throws {
        for count in [3, 6, 10] {
            var store = AttentionRequestStore()
            store.apply(.traeXPermissionRequested(
                sessionID: "request-session",
                turnID: "request-turn",
                toolUseID: "request-tool",
                toolName: "Bash",
                observedAt: now
            ))
            var sessionEntries: [AmbientOverviewEntry] = []
            for index in 0..<count {
                sessionEntries.append(entry(
                    handle: "term-\(index)",
                    repo: "repo\(index)",
                    branch: "main",
                    connected: true,
                    focused: index == 0,
                    activity: index % 2 == 0 ? .busy : .idle,
                    coverage: index % 3 == 0 ? .coverageGap : .structuredAgent,
                    updatedAt: now.addingTimeInterval(TimeInterval(index)),
                    currentTask: "session \(index)"
                ))
            }
            let ambient = AmbientOverview(entries: sessionEntries)

            let projection = AttentionQueueProjection.make(
                store: store,
                ambient: ambient,
                now: now.addingTimeInterval(60),
                aiSummariesEnabled: false
            )

            #expect(projection.requestCount == 1)
            #expect(projection.queueHead?.kindLabel == "Permission required")
            #expect(projection.ambient.count == count)
            guard case .request = projection.collapsed else {
                Issue.record("Attention Queue should keep primary collapsed content for \(count) sessions")
                return
            }
        }
    }

    private func entry(
        handle: String,
        repo: String,
        branch: String,
        connected: Bool,
        focused: Bool,
        activity: TerminalActivityStatus,
        coverage: AmbientCoverage,
        updatedAt: Date,
        currentTask: String
    ) -> AmbientOverviewEntry {
        AmbientOverviewEntry(
            terminalHandle: handle,
            worktreeID: "worktree-\(repo)",
            repository: repo,
            branch: branch,
            title: nil,
            connected: connected,
            lastOutputAt: updatedAt,
            isFocused: focused,
            activity: activity,
            coverage: coverage,
            session: SessionOverviewDisplay(
                currentTask: currentTask,
                progress: "progress",
                nextStep: "next",
                needsInput: "无",
                sourceConfidence: coverage == .structuredAgent
                    ? "structured agent · deterministic local fallback · AI disabled"
                    : "coverage gap · not request",
                updatedAt: updatedAt,
                summaryFingerprint: coverage == .structuredAgent && currentTask != "idle" ? "fingerprint-\(handle)" : nil
            )
        )
    }

    private func makeOrca(ps: LockedBox<String>) -> OrcaClient {
        OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return Fixtures.data(ps.with { $0 }) }
            return Fixtures.data(Fixtures.terminalList)
        }
    }

    private func twoStructuredRepliesPS(messageA: String, messageB: String) -> String {
        """
        {
          "id": "cmd-two-agents",
          "ok": true,
          "result": {
            "worktrees": [
              {
                "worktreeId": "111::/Users/dev/orca/repoA",
                "repo": "repoA",
                "path": "/Users/dev/orca/repoA",
                "branch": "refs/heads/main",
                "isActive": true,
                "status": "working",
                "lastOutputAt": 1786993627799,
                "agents": [
                  {
                    "paneKey": "tab2:leaf2",
                    "state": "done",
                    "taskTitle": "Implement Session Overview",
                    "prompt": "raw prompt should not leave process",
                    "lastAssistantMessage": "\(messageA)",
                    "toolName": "Bash",
                    "toolInput": "raw tool body should not leave process",
                    "updatedAt": 1786993627219
                  }
                ]
              },
              {
                "worktreeId": "222::/Users/dev/orca/repoB",
                "repo": "repoA",
                "path": "/Users/dev/orca/repoA",
                "branch": "refs/heads/main",
                "isActive": false,
                "status": "active",
                "lastOutputAt": 1786993627798,
                "agents": [
                  {
                    "paneKey": "tab3:leaf3",
                    "state": "done",
                    "taskTitle": "Review tests",
                    "lastAssistantMessage": "\(messageB)",
                    "updatedAt": 1786993627798
                  }
                ]
              }
            ]
          }
        }
        """
    }

    private func sensitiveStructuredReplyPS(rawReply: String) -> String {
        """
        {
          "id": "cmd-sensitive-agent",
          "ok": true,
          "result": {
            "worktrees": [
              {
                "worktreeId": "111::/Users/dev/orca/repoA",
                "repo": "repoA",
                "path": "/Users/dev/orca/repoA",
                "branch": "refs/heads/main",
                "isActive": true,
                "status": "active",
                "lastOutputAt": 1786993627799,
                "preview": "terminal preview secret",
                "agents": [
                  {
                    "paneKey": "tab2:leaf2",
                    "state": "done",
                    "taskTitle": "Review sensitive change",
                    "prompt": "raw prompt should not leave process",
                    "lastAssistantMessage": "\(rawReply)",
                    "toolName": "Bash",
                    "toolInput": "tool-body-secret",
                    "updatedAt": 1786993627219
                  }
                ]
              }
            ]
          }
        }
        """
    }

    private func makeSnapshot() throws -> FocusResolver.Snapshot {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        return FocusResolver.Snapshot(
            worktrees: ps.worktrees,
            terminals: list.terminals,
            layouts: list.visualLayouts
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await MainActor.run(body: predicate) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for predicate")
    }

    private func shortDelay() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private func promptOnlyAgentPS(prompt: String) -> String {
        """
        {
          "id": "cmd-prompt-only-agent",
          "ok": true,
          "result": {
            "worktrees": [
              {
                "worktreeId": "111::/Users/dev/orca/repoA",
                "repo": "repoA",
                "path": "/Users/dev/orca/repoA",
                "branch": "refs/heads/main",
                "isActive": true,
                "status": "working",
                "lastOutputAt": 1786993627799,
                "agents": [
                  {
                    "paneKey": "tab2:leaf2",
                    "state": "working",
                    "agentType": "grok",
                    "prompt": "\(prompt)",
                    "updatedAt": 1786993627219
                  }
                ]
              }
            ]
          }
        }
        """
    }
}

private final class MutableClock: @unchecked Sendable {
    var current: Date
    init(_ current: Date) { self.current = current }
}

private final class TestDefaults: AttentionQueueDefaultsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var doubles: [String: Double] = [:]
    private var datas: [String: Data] = [:]

    func double(forKey key: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        return doubles[key] ?? 0
    }

    func set(_ value: Double, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        doubles[key] = value
    }

    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return datas[key]
    }

    func set(_ value: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        datas[key] = value
    }
}

private final class RecordingSummaryProvider: SummaryProviding, @unchecked Sendable {
    nonisolated(unsafe) private var recorded: [SummaryContext] = []
    private let summary: TerminalSummary?
    private let error: Error?

    init(summary: TerminalSummary) {
        self.summary = summary
        self.error = nil
    }

    init(error: Error) {
        self.summary = nil
        self.error = error
    }

    func summarize(context: SummaryContext) async throws -> TerminalSummary {
        recorded.append(context)
        if let error { throw error }
        return summary ?? TerminalSummary(currentTask: "未知", progress: "未知", nextStep: "未知", needsInput: "无")
    }

    func contexts() -> [SummaryContext] {
        recorded
    }
}

private final class ControllableSummaryProvider: SummaryProviding, @unchecked Sendable {
    private struct Pending {
        let context: SummaryContext
        let continuation: CheckedContinuation<TerminalSummary, Never>
    }

    private let lock = NSLock()
    private var pending: [Pending] = []
    private var active = 0
    private var peakActive = 0

    func summarize(context: SummaryContext) async throws -> TerminalSummary {
        await withCheckedContinuation { continuation in
            lock.lock()
            pending.append(Pending(context: context, continuation: continuation))
            active += 1
            peakActive = max(peakActive, active)
            lock.unlock()
        }
    }

    func contexts() -> [SummaryContext] {
        lock.lock(); defer { lock.unlock() }
        return pending.map(\.context)
    }

    func resume(index: Int, with summary: TerminalSummary) {
        lock.lock()
        let continuation = pending[index].continuation
        active -= 1
        lock.unlock()
        continuation.resume(returning: summary)
    }

    func resumeAll(with summary: TerminalSummary) {
        lock.lock()
        let continuations = pending.map(\.continuation)
        active = 0
        lock.unlock()
        for continuation in continuations {
            continuation.resume(returning: summary)
        }
    }

    func resumePending(with summary: TerminalSummary) {
        lock.lock()
        let continuations = pending.suffix(active).map(\.continuation)
        active = 0
        lock.unlock()
        for continuation in continuations { continuation.resume(returning: summary) }
    }

    func peakActiveCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return peakActive
    }
}
