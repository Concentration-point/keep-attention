import Testing
import Foundation
@testable import KeepAttentionCore

/// Poller 编排：只基于 Orca agent hook 的 lastAssistantMessage 触发总结。
@MainActor
@Suite struct PollerTests {
    /// 按 handle 分发 fixture；可让指定 handle 在第 N 次 read 后内容变化。
    private func makeOrca(ps: String = Fixtures.worktreePS, tailOverride: [String]? = nil) -> OrcaClient {
        OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return Fixtures.data(ps) }
            if joined.contains("list") { return Fixtures.data(Fixtures.terminalList) }
            if let tailOverride {
                return Fixtures.data("""
                {"ok":true,"result":{"terminal":{"handle":"x","status":"running","tail":\(Self.jsonDataLines(tailOverride)),"truncated":false,"limited":false,"returnedLineCount":\(tailOverride.count)}}}
                """)
            }
            return Fixtures.data(Fixtures.terminalRead)
        }
    }

    nonisolated private static func jsonDataLines(_ lines: [String]) -> String {
        let joined = lines
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            .joined(separator: ",")
        return "[\(joined)]"
    }

    private func makeModel(orca: OrcaClient, summarizer: SummaryProviding) -> AppModel {
        AppModel(orca: orca, summarizer: summarizer)
    }

    @Test func finalAgentMessageSummarizesMappedTerminalOnceAndDedupes() async throws {
        let calls = LockedBox<[SummaryContext]>([])
        let summarizer = MockSummarizer { context in
            calls.with { $0.append(context) }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(orca: makeOrca(), summarizer: summarizer)

        await model.tick()
        #expect(model.focusedHandle == "term_A2")
        #expect(calls.with { $0.count } == 1)
        let expectedMessage = """
        用户请求：审查 PR

        Agent 回复：
        已找到三处风险，需要你确认选 A 还是 B？
        """
        #expect(calls.with { $0.first?.agentMessage } == expectedMessage)
        let display = try #require(model.displays.first { $0.handle == "term_B1" })
        guard case .ready(let s) = display.summary else {
            Issue.record("应为 ready，实际 \(display.summary)")
            return
        }
        #expect(s.currentTask == "t")

        // 第二次 tick：同一条 lastAssistantMessage → 不再调用 DeepSeek。
        await model.tick()
        #expect(calls.with { $0.count } == 1)
    }

    @Test func terminalTailChangeDoesNotTriggerSummaryWithoutNewAgentMessage() async throws {
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(orca: makeOrca(), summarizer: summarizer)
        await model.tick()
        #expect(calls.with { $0 } == 1)

        // terminal tail 变化但 structured lastAssistantMessage 未变 → 不重新总结。
        let changed = makeOrca(tailOverride: ["新的一行输出", "继续干活"])
        model.setOrcaForTesting(changed)
        await model.tick()
        #expect(calls.with { $0 } == 1)
    }

    @Test func workingAgentMessageIsNotSummarized() async throws {
        let calls = LockedBox<[SummaryContext]>([])
        let summarizer = MockSummarizer { context in
            calls.with { $0.append(context) }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let psWorkingWithMessage = Fixtures.worktreePS
            .replacingOccurrences(
                of: #""lastAssistantMessage": null"#,
                with: #""lastAssistantMessage": "中间输出，不应总结""#
            )
        let model = makeModel(orca: makeOrca(ps: psWorkingWithMessage), summarizer: summarizer)

        await model.tick()
        #expect(calls.with { $0.count } == 1) // 只总结 repoB 的 done message，不总结 repoA 的 working message。
        let expectedMessage = """
        用户请求：审查 PR

        Agent 回复：
        已找到三处风险，需要你确认选 A 还是 B？
        """
        #expect(calls.with { $0.first?.agentMessage } == expectedMessage)
    }

    @Test func allHookCoveredTerminalsSummarizeIndependentlyAndDedupPerHandle() async throws {
        let calls = LockedBox<[SummaryContext]>([])
        let summarizer = MockSummarizer { context in
            calls.with { $0.append(context) }
            return TerminalSummary(
                currentTask: context.title ?? "unknown",
                progress: "p",
                nextStep: "n",
                needsInput: "无"
            )
        }
        let model = makeModel(orca: makeOrca(ps: Self.psWithTwoDoneAgents()), summarizer: summarizer)

        await model.tick()

        #expect(calls.with { $0.map(\.title) } == ["repoA · grok", "repoB · claude"])
        #expect(model.displays.first { $0.handle == "term_A2" }?.summary.hasStructuredResult == true)
        #expect(model.displays.first { $0.handle == "term_B1" }?.summary.hasStructuredResult == true)

        await model.tick()
        #expect(calls.with { $0.count } == 2)

        model.setOrcaForTesting(makeOrca(ps: Self.psWithTwoDoneAgents(repoAMessage: "repoA 新结果")))
        await model.tick()

        #expect(calls.with { $0.map(\.title) } == ["repoA · grok", "repoB · claude", "repoA · grok"])
    }


    @Test func pillPrefersReadyStructuredResultOverFocusedUnavailableTerminal() async throws {
        let summarizer = MockSummarizer { _ in
            TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(orca: makeOrca(), summarizer: summarizer)

        await model.tick()

        #expect(model.focusedHandle == "term_A2")
        #expect(model.displays.first { $0.handle == "term_A2" }?.summary == .unavailable("Agent 正在执行，等待下一条完整回复"))
        #expect(model.pillDisplay?.handle == "term_B1")
    }

    @Test func displaysCoverAllLiveTerminalsIncludingUnmatchedForPanelList() async throws {
        // issue #11：展开面板列表数据源 = model.displays，必须覆盖全部 live terminals，
        // 包括无 agents[] 匹配的终端；无匹配的显示“未检测到结构化 agent 输出”。
        let model = makeModel(orca: makeOrca(), summarizer: MockSummarizer { _ in
            TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        })

        await model.tick()

        #expect(model.displays.map(\.handle) == ["term_A1", "term_A2", "term_A3", "term_B1", "term_B2"])
        // 无 agent 匹配的 terminal 也在列表中，且标记为无结构化输出。
        for handle in ["term_A1", "term_A3", "term_B2"] {
            let row = try #require(model.displays.first { $0.handle == handle })
            #expect(row.repo != "未知")
            #expect(row.branch != nil || row.title != nil)
            #expect(row.summary == .unavailable("未检测到结构化 agent 输出"))
        }
        // 有结构化结果的终端与焦点终端可区分。
        #expect(model.displays.first { $0.handle == "term_B1" }?.summary.hasStructuredResult == true)
        #expect(model.focusedHandle == "term_A2")
    }

    // MARK: - issue #12：列表按 attention 排序 + 聚合计数

    @Test func attentionDisplaysSortWaitingFirstThenStructuredThenBusyStable() async throws {
        // 默认 fixture：term_B1 有结构化结果(ready)，term_A2 busy(working)，
        // term_A1/A3/B2 idle 且无结构化输出（同组保持 displays 原序）。
        let model = makeModel(orca: makeOrca(), summarizer: MockSummarizer { _ in
            TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        })

        await model.tick()

        #expect(model.attentionDisplays.map(\.handle) == ["term_B1", "term_A2", "term_A1", "term_A3", "term_B2"])
        #expect(model.totalTerminalCount == 5)
        #expect(model.attentionCount == 1)
        #expect(model.waitingCount == 0)
    }

    @Test func attentionDisplaysSortBlockedAgentTerminalFirst() async throws {
        // repoA agent state 改为 blocked → term_A2 判定 waitingForInput，排序最前。
        let psBlocked = Fixtures.worktreePS.replacingOccurrences(
            of: #""state": "working""#,
            with: #""state": "blocked""#
        )
        let model = makeModel(orca: makeOrca(ps: psBlocked), summarizer: MockSummarizer { _ in
            TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        })

        await model.tick()

        #expect(model.displays.first { $0.handle == "term_A2" }?.status == .waitingForInput)
        #expect(model.attentionDisplays.map(\.handle) == ["term_A2", "term_B1", "term_A1", "term_A3", "term_B2"])
        #expect(model.waitingCount == 1)
        #expect(model.attentionCount == 2)
    }

    @Test func attentionRankPrefersStructuredResultOverPlainBusyAndIdle() {
        func makeDisplay(_ status: TerminalActivityStatus, _ summary: SummaryState) -> AppModel.TerminalDisplay {
            AppModel.TerminalDisplay(id: "x", handle: "x", repo: "r", branch: nil, title: nil,
                                     status: status, summary: summary, lastOutputAt: nil, updatedAt: nil)
        }
        let ready = SummaryState.ready(TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无"))
        let unavailable = SummaryState.unavailable("无")
        let waiting = makeDisplay(.waitingForInput, unavailable)
        let structuredIdle = makeDisplay(.idle, ready)
        let plainBusy = makeDisplay(.busy, unavailable)
        let plainIdle = makeDisplay(.idle, unavailable)

        #expect(AppModel.attentionRank(waiting) < AppModel.attentionRank(structuredIdle))
        #expect(AppModel.attentionRank(structuredIdle) < AppModel.attentionRank(plainBusy))
        #expect(AppModel.attentionRank(plainBusy) < AppModel.attentionRank(plainIdle))
    }

    @Test func terminalListVisualStateCoversStableRowBuckets() {
        let ready = SummaryState.ready(TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无"))

        #expect(TerminalListVisualState.resolve(status: .waitingForInput, summary: .unavailable("无")) == .waiting)
        #expect(TerminalListVisualState.resolve(status: .idle, summary: ready) == .newResult)
        #expect(TerminalListVisualState.resolve(status: .busy, summary: .unavailable("运行中")) == .running)
        #expect(TerminalListVisualState.resolve(status: .idle, summary: .unavailable("未检测到结构化 agent 输出")) == .unavailable)
        #expect(TerminalListVisualState.resolve(status: .idle, summary: .unavailable("暂无结构化 agent 输出")) == .unavailable)
    }

    @Test func attentionSortKeepsOriginalOrderWithinSameRank() {
        func makeDisplay(handle: String, _ status: TerminalActivityStatus, _ summary: SummaryState) -> AppModel.TerminalDisplay {
            AppModel.TerminalDisplay(id: handle, handle: handle, repo: "r", branch: nil, title: nil,
                                     status: status, summary: summary, lastOutputAt: nil, updatedAt: nil)
        }
        let ready = SummaryState.ready(TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无"))
        let unavailable = SummaryState.unavailable("无")
        let input = [
            makeDisplay(handle: "busy-1", .busy, unavailable),
            makeDisplay(handle: "idle-1", .idle, unavailable),
            makeDisplay(handle: "ready-1", .idle, ready),
            makeDisplay(handle: "busy-2", .busy, unavailable),
            makeDisplay(handle: "idle-2", .idle, unavailable),
        ]

        let sorted = AppModel.sortByAttentionPreservingOriginalOrder(input)

        #expect(sorted.map(\.handle) == ["ready-1", "busy-1", "busy-2", "idle-1", "idle-2"])
    }

    @Test func noAgentsDoesNotSummarize() async throws {
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "需要选择方案")
        }
        let model = makeModel(orca: makeOrca(ps: Self.psWithNoAgents), summarizer: summarizer)

        await model.tick()
        #expect(calls.with { $0 } == 0)
        #expect(model.displays.first { $0.handle == "term_A2" }?.summary == .unavailable("未检测到结构化 agent 输出"))
        #expect(model.displays.first { $0.handle == "term_B1" }?.summary == .unavailable("未检测到结构化 agent 输出"))
    }

    // MARK: - issue #13：详情选择与回退

    @Test func detailSelectionKeepsHandleAcrossPollsAndFallsBackWhenTerminalDisappears() async throws {
        let model = makeModel(orca: makeOrca(), summarizer: MockSummarizer { _ in
            TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        })
        await model.tick()
        let fallback = try #require(model.attentionDisplays.first)

        // 点击命中：详情指向被点击终端。
        #expect(AppModel.resolveDetailDisplay(selectedHandle: "term_A3", displays: model.attentionDisplays, fallback: fallback)?.handle == "term_A3")
        // 下一轮 poll 重建 displays，handle 稳定 → 选择保持。
        await model.tick()
        #expect(AppModel.resolveDetailDisplay(selectedHandle: "term_A3", displays: model.attentionDisplays, fallback: fallback)?.handle == "term_A3")
        // terminal 消失 → 回退 attention 第一项。
        #expect(fallback.handle == "term_B1")
        #expect(AppModel.resolveDetailDisplay(selectedHandle: "gone", displays: model.attentionDisplays, fallback: fallback)?.handle == fallback.handle)
        // 从未选择 → 直接回退。
        #expect(AppModel.resolveDetailDisplay(selectedHandle: nil, displays: model.attentionDisplays, fallback: fallback)?.handle == fallback.handle)
        // displays 为空（orca 失败）→ 一律回退 fallback。
        #expect(AppModel.resolveDetailDisplay(selectedHandle: "term_A3", displays: [], fallback: nil) == nil)
    }

    @Test func selectingNoHookTerminalShowsUnavailableWithoutExtraSummarizeCall() async throws {
        let calls = LockedBox(0)
        let model = makeModel(orca: makeOrca(), summarizer: MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        })
        await model.tick()
        let baseline = calls.with { $0 }

        // 点击无 hook terminal：详情为 unavailable 文案，不新增 DeepSeek 调用。
        let selected = AppModel.resolveDetailDisplay(
            selectedHandle: "term_A3",
            displays: model.attentionDisplays,
            fallback: model.attentionDisplays.first
        )
        #expect(selected?.handle == "term_A3")
        #expect(selected?.summary == .unavailable("未检测到结构化 agent 输出"))
        #expect(calls.with { $0 } == baseline)
    }

    // MARK: - issue #15：跳转到终端

    /// 带 switch 分支的 orca mock：switchJSON 为 nil 时 switch 抛错（模拟 CLI 崩溃/非零退出）。
    private func makeSwitchOrca(switchJSON: String?, recorder: LockedBox<[[String]]>? = nil) -> OrcaClient {
        OrcaClient { args in
            recorder?.with { $0.append(args) }
            let joined = args.joined(separator: " ")
            if joined.contains("switch") {
                guard let switchJSON else { throw OrcaError.exit(1) }
                return Fixtures.data(switchJSON)
            }
            if joined.contains("worktree") { return Fixtures.data(Fixtures.worktreePS) }
            if joined.contains("list") { return Fixtures.data(Fixtures.terminalList) }
            return Fixtures.data(Fixtures.terminalRead)
        }
    }

    nonisolated private static let switchOkJSON = #"{"id":"cmd-j1","ok":true,"result":{}}"#
    nonisolated private static let switchStaleJSON = #"{"id":"cmd-j2","ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}"#

    private func noThrowSummarizer() -> MockSummarizer {
        MockSummarizer { _ in TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无") }
    }

    @Test func jumpToTerminalInvokesSwitchCommandWithHandle() async throws {
        let recorder = LockedBox([[String]]())
        let model = makeModel(orca: makeSwitchOrca(switchJSON: Self.switchOkJSON, recorder: recorder),
                              summarizer: noThrowSummarizer())
        await model.tick()

        await model.jumpToTerminal(handle: "term_A2")

        #expect(recorder.with { $0 }.contains(["terminal", "switch", "--terminal", "term_A2", "--json"]))
    }

    @Test func jumpToTerminalFailureSetsLightweightErrorAndKeepsCollecting() async throws {
        let model = makeModel(orca: makeSwitchOrca(switchJSON: Self.switchStaleJSON),
                              summarizer: noThrowSummarizer())
        await model.tick()
        #expect(model.orcaError == nil)
        #expect(model.jumpError == nil)

        await model.jumpToTerminal(handle: "term_B1")

        #expect(model.jumpError == "跳转失败，稍后重试")
        // 跳转失败只影响 jumpError：采集状态与 displays 不受波及，后续 tick 正常。
        #expect(model.orcaError == nil)
        #expect(!model.displays.isEmpty)
        await model.tick()
        #expect(model.orcaError == nil)
        #expect(!model.displays.isEmpty)
    }

    @Test func jumpToTerminalCLIThrowDoesNotCrash() async throws {
        let model = makeModel(orca: makeSwitchOrca(switchJSON: nil),
                              summarizer: noThrowSummarizer())
        await model.tick()

        await model.jumpToTerminal(handle: "term_B1")

        #expect(model.jumpError == "跳转失败，稍后重试")
    }

    @Test func jumpToTerminalSucceedsAndClearsJumpError() async throws {
        let model = makeModel(orca: makeSwitchOrca(switchJSON: Self.switchStaleJSON),
                              summarizer: noThrowSummarizer())
        await model.tick()
        await model.jumpToTerminal(handle: "term_B1")
        #expect(model.jumpError != nil)

        model.setOrcaForTesting(makeSwitchOrca(switchJSON: Self.switchOkJSON))
        await model.jumpToTerminal(handle: "term_B1")

        #expect(model.jumpError == nil)
    }

    @Test func summarizeFailureMarksStructuredAgentTerminalFailedNotCrash() async throws {
        let summarizer = MockSummarizer { _ in throw DeepSeekError.missingAPIKey }
        let model = makeModel(orca: makeOrca(), summarizer: summarizer)
        await model.tick()
        let display = try #require(model.displays.first { $0.handle == "term_B1" })
        #expect(display.summary == .failed("未配置 API Key"))
    }

    @Test func orcaFailureSetsErrorAndKeepsRunning() async throws {
        let failing = OrcaClient { _ in throw OrcaError.missingBinary("/usr/local/bin/orca") }
        let summarizer = MockSummarizer { _ in
            TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(orca: failing, summarizer: summarizer)
        await model.tick()
        #expect(model.orcaError != nil)
        #expect(model.displays.isEmpty)
        // 恢复后下一次 tick 正常。
        model.setOrcaForTesting(makeOrca())
        await model.tick()
        #expect(model.orcaError == nil)
        #expect(model.focusedHandle == "term_A2")
    }

    @Test func pollIntervalPersisted() {
        let defaults = UserDefaults(suiteName: "test-poll-\(UUID().uuidString)")!
        let model = AppModel(orca: makeOrca(),
                             summarizer: MockSummarizer { _ in TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无") },
                             defaults: defaults)
        #expect(model.pollInterval == 5)  // 默认 5 秒
        model.pollInterval = 10
        #expect(defaults.double(forKey: "pollIntervalSeconds") == 10)
    }

    nonisolated private static let psWithNoAgents = """
    {
      "id": "cmd-no-agents",
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
            "agents": []
          },
          {
            "worktreeId": "222::/Users/dev/orca/repoB",
            "repo": "repoB",
            "path": "/Users/dev/orca/repoB",
            "branch": "refs/heads/feat-y",
            "isActive": false,
            "status": "active",
            "lastOutputAt": 1786990000000,
            "agents": []
          }
        ]
      }
    }
    """

    nonisolated private static func psWithTwoDoneAgents(
        repoAMessage: String = "repoA 完成",
        repoBMessage: String = "已找到三处风险，需要你确认选 A 还是 B？"
    ) -> String {
        """
        {
          "id": "cmd-two-agents",
          "ok": true,
          "result": {
            "worktrees": [
              {
                "workspaceKind": "git",
                "worktreeId": "111::/Users/dev/orca/repoA",
                "repoId": "111",
                "repo": "repoA",
                "path": "/Users/dev/orca/repoA",
                "branch": "refs/heads/main",
                "isMainWorktree": true,
                "isActive": true,
                "liveTerminalCount": 2,
                "status": "working",
                "lastOutputAt": 1786993627799,
                "agents": [
                  {
                    "paneKey": "tab2:leaf2",
                    "state": "done",
                    "agentType": "grok",
                    "prompt": "实现功能 X",
                    "taskTitle": "实现功能 X",
                    "lastAssistantMessage": "\(repoAMessage)",
                    "interrupted": false,
                    "updatedAt": 1786993627219
                  }
                ]
              },
              {
                "worktreeId": "222::/Users/dev/orca/repoB",
                "repo": "repoB",
                "path": "/Users/dev/orca/repoB",
                "branch": "refs/heads/feat-y",
                "isActive": false,
                "liveTerminalCount": 2,
                "status": "active",
                "lastOutputAt": 1786990000000,
                "agents": [
                  {
                    "paneKey": "tab3:leaf3",
                    "state": "done",
                    "agentType": "claude",
                    "prompt": "审查 PR",
                    "lastAssistantMessage": "\(repoBMessage)",
                    "interrupted": false,
                    "updatedAt": 1786990000000
                  }
                ]
              }
            ]
          }
        }
        """
    }
}

/// 可编程的总结 mock。
struct MockSummarizer: SummaryProviding {
    let handler: @Sendable (SummaryContext) throws -> TerminalSummary
    func summarize(context: SummaryContext) async throws -> TerminalSummary {
        try handler(context)
    }
}
