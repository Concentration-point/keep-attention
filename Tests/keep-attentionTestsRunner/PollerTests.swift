import Testing
import Foundation
@testable import KeepAttentionCore

/// Poller 编排：焦点总结、去重（相同内容指纹不重复烧 API）、失败降级。
@MainActor
@Suite struct PollerTests {
    /// 按 handle 分发 fixture；可让指定 handle 在第 N 次 read 后内容变化。
    private func makeOrca(tailOverride: [String]? = nil) -> OrcaClient {
        OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return Fixtures.data(Fixtures.worktreePS) }
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

    @Test func summarizesFocusedTerminalOnceAndDedupes() async throws {
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(orca: makeOrca(), summarizer: summarizer)

        await model.tick()
        #expect(model.focusedHandle == "term_A2")
        #expect(calls.with { $0 } == 1)  // 焦点终端被总结
        let display = try #require(model.displays.first { $0.handle == "term_A2" })
        guard case .ready(let s) = display.summary else {
            Issue.record("应为 ready，实际 \(display.summary)")
            return
        }
        #expect(s.currentTask == "t")

        // 第二次 tick：内容指纹未变 → 不再调用
        await model.tick()
        #expect(calls.with { $0 } == 1)
    }

    @Test func contentChangeTriggersResummarize() async throws {
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(orca: makeOrca(), summarizer: summarizer)
        await model.tick()
        #expect(calls.with { $0 } == 1)

        // 内容变化（新 tail）→ 指纹变化 → 重新总结
        let changed = makeOrca(tailOverride: ["新的一行输出", "继续干活"])
        model.setOrcaForTesting(changed)
        await model.tick()
        #expect(calls.with { $0 } == 2)
    }

    @Test func doneAgentWithoutTailIsIdleNotWaiting() async throws {
        // repoB 的 agent state=done 且无 tail 缓存 → idle（不乱报等待）
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "需要选择方案")
        }
        let orca = OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return Fixtures.data(Fixtures.worktreePS) }
            if joined.contains("list") { return Fixtures.data(Fixtures.terminalList) }
            return Fixtures.data(Fixtures.terminalRead)
        }
        let model = makeModel(orca: orca, summarizer: summarizer)
        await model.tick()
        // 焦点 term_A2（busy）被总结；其余无等待信号 → 只有 1 次调用
        #expect(calls.with { $0 } == 1)
        #expect(model.displays.first { $0.handle == "term_A2" }?.status == .busy)
        #expect(model.displays.first { $0.handle == "term_B1" }?.status == .idle)
    }

    @Test func waitingAgentStateSummarizedAndPillTakesOver() async throws {
        // repoB 的 agent 置为 waiting → 其终端被读取并总结；药丸抢显最久未更新的 term_B2
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "需要选择方案")
        }
        let psWaiting = Fixtures.data(
            Fixtures.worktreePS.replacingOccurrences(of: "\"state\": \"done\"", with: "\"state\": \"waiting\"")
        )
        let orca = OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return psWaiting }
            if joined.contains("list") { return Fixtures.data(Fixtures.terminalList) }
            return Fixtures.data(Fixtures.terminalRead)
        }
        let model = makeModel(orca: orca, summarizer: summarizer)
        await model.tick()
        // 焦点 term_A2 + repoB 的 term_B1/term_B2
        #expect(calls.with { $0 } == 3)
        #expect(model.waitingCount == 2)
        #expect(model.mostUrgentWaiting?.handle == "term_B2")
        #expect(model.pillDisplay?.handle == "term_B2")
        // 抢显终端的摘要可用
        let pill = try #require(model.pillDisplay)
        #expect(pill.summary == .ready(TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "需要选择方案")))
    }

    @Test func summarizeFailureMarksFailedNotCrash() async throws {
        let summarizer = MockSummarizer { _ in throw DeepSeekError.missingAPIKey }
        let model = makeModel(orca: makeOrca(), summarizer: summarizer)
        await model.tick()
        let display = try #require(model.displays.first { $0.handle == "term_A2" })
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
        // 恢复后下一次 tick 正常
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
}

/// 可编程的总结 mock。
struct MockSummarizer: SummaryProviding {
    let handler: @Sendable (SummaryContext) throws -> TerminalSummary
    func summarize(context: SummaryContext) async throws -> TerminalSummary {
        try handler(context)
    }
}
