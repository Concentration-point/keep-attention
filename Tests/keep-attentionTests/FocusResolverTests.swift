import Testing
import Foundation
@testable import keep_attention

/// 两级焦点推导 + lastOutputAt 兜底（spec §2 焦点推导）。
@Suite struct FocusResolverTests {
    @Test func twoLevelResolutionFindsActivePaneInsideSplit() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        let resolver = FocusResolver(snapshot: .init(
            worktrees: ps.worktrees,
            terminals: list.terminals,
            layouts: list.visualLayouts
        ))
        // repoA isActive → tab2（activeTabId）→ pane-split 递归里 active 的 term_A2
        #expect(resolver.focusedHandle() == "term_A2")
    }

    @Test func fallsBackToLatestOutputWhenNoActiveWorktree() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalListNoFocus))
        let resolver = FocusResolver(snapshot: .init(
            worktrees: ps.worktrees.map { var w = $0; w.isActive = false; return w },
            terminals: list.terminals,
            layouts: list.visualLayouts
        ))
        #expect(resolver.focusedHandle() == "term_X2")
    }

    @Test func fallsBackWhenLayoutChainIsBroken() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        // 断链场景 1：active worktree 没有 visualLayout
        do {
            let resolver = FocusResolver(snapshot: .init(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts.filter { $0.worktreeId != "111::/Users/dev/orca/repoA" }
            ))
            // 兜底：所有终端里 lastOutputAt 最新 → term_A2 (1786993627799)
            #expect(resolver.focusedHandle() == "term_A2")
        }
        // 断链场景 2：activeTabId 指向不存在的 tab
        do {
            var layouts = list.visualLayouts
            layouts[0].root.activeTabId = "missing-tab"
            let resolver = FocusResolver(snapshot: .init(
                worktrees: ps.worktrees, terminals: list.terminals, layouts: layouts
            ))
            #expect(resolver.focusedHandle() == "term_A2")
        }
        // 断链场景 3：active tab 里没有 active==true 的 pane
        do {
            var layouts = list.visualLayouts
            var tabs = layouts[0].root.tabs
            guard case .split(var split) = tabs[1].panes,
                  case .terminal(var first) = split.first else { return }
            first.active = false
            split.first = .terminal(first)
            tabs[1].panes = .split(split)
            layouts[0].root.tabs = tabs
            let resolver = FocusResolver(snapshot: .init(
                worktrees: ps.worktrees, terminals: list.terminals, layouts: layouts
            ))
            #expect(resolver.focusedHandle() == "term_A2")
        }
    }

    @Test func emptySnapshotYieldsNil() {
        let resolver = FocusResolver(snapshot: .init(worktrees: [], terminals: [], layouts: []))
        #expect(resolver.focusedHandle() == nil)
    }
}

/// 忙闲判定（spec §2 忙闲判定 + waitingForInput 简化启发式）。
@Suite struct StatusResolverTests {
    private func makeInput(
        agents: [String] = [],
        worktreeStatus: String? = nil,
        lastOutputAgo: TimeInterval? = nil,
        tail: [String]? = nil
    ) -> StatusInput {
        StatusInput(
            agentStates: agents,
            worktreeStatus: worktreeStatus,
            lastOutputAt: lastOutputAgo.map { Date(timeIntervalSinceNow: -$0) },
            tail: tail,
            now: Date()
        )
    }

    @Test func agentStateWorkingIsBusy() {
        #expect(StatusResolver.resolve(makeInput(agents: ["working"])) == .busy)
    }

    @Test func agentStateWaitingIsWaitingForInput() {
        #expect(StatusResolver.resolve(makeInput(agents: ["waiting"])) == .waitingForInput)
        #expect(StatusResolver.resolve(makeInput(agents: ["waiting-for-input"])) == .waitingForInput)
    }

    @Test func agentDoneWithQuestionTailIsWaitingForInput() {
        let tail = ["分析完成", "下一个问题：选 A 还是 B？"]
        #expect(StatusResolver.resolve(makeInput(agents: ["done"], tail: tail)) == .waitingForInput)
    }

    @Test func agentDoneWithoutQuestionIsIdle() {
        #expect(StatusResolver.resolve(makeInput(agents: ["done"], tail: ["全部完成"])) == .idle)
    }

    @Test func workingWorktreeWithFreshOutputIsBusyEvenWithQuestionTail() {
        // 拿不准就归 busy，不要乱报等待
        let tail = ["构建中…", "要不要继续？"]
        #expect(StatusResolver.resolve(makeInput(worktreeStatus: "working", lastOutputAgo: 10, tail: tail)) == .busy)
    }

    @Test func staleWorkingWorktreeWithPromptTailIsWaitingForInput() {
        let tail = ["npm install 完毕", "Do you want to proceed? [y/n]"]
        #expect(StatusResolver.resolve(makeInput(worktreeStatus: "working", lastOutputAgo: 120, tail: tail)) == .waitingForInput)
    }

    @Test func staleWithoutPromptIsIdle() {
        #expect(StatusResolver.resolve(makeInput(worktreeStatus: "working", lastOutputAgo: 120, tail: ["$"])) == .idle)
        #expect(StatusResolver.resolve(makeInput(lastOutputAgo: 120)) == .idle)
    }

    @Test func chineseQuestionMarkCounts() {
        #expect(StatusResolver.resolve(makeInput(tail: ["请确认配置", "是否继续？"])) == .waitingForInput)
    }

    @Test func questionTooFarFromTailIgnored() {
        let tail = ["要继续吗？"] + Array(repeating: "日志输出行", count: 20)
        #expect(StatusResolver.resolve(makeInput(tail: tail)) == .idle)
    }
}

/// 内容指纹（去重键）。
@Suite struct FingerprintTests {
    @Test func sameContentSameFingerprint() {
        #expect(contentFingerprint(["a", "b"]) == contentFingerprint(["a", "b"]))
    }

    @Test func differentContentDifferentFingerprint() {
        #expect(contentFingerprint(["a", "b"]) != contentFingerprint(["a", "b", "c"]))
    }

    @Test func emptyIsStable() {
        #expect(contentFingerprint([]) == contentFingerprint([]))
        #expect(!contentFingerprint([]).isEmpty)
    }
}
