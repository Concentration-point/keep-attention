import Foundation
import Testing
@testable import KeepAttentionCore

// issue #33：session-aware jump 的 fail-closed 导航与验证。
// 契约：
// - 目标以"稳定会话/pane 选择器引用"存储，terminal handle 只是上次已知的提示；
// - 点击跳转时用当前 Orca 快照重新解析实时路由；
// - 只有路由证据一致（worktree/tab/leaf、可验证的会话关联）才调用底层 switch 原语；
// - switch 后用最新 layout 数据验证目标 tab/pane 是否 active；
// - 任何失败（stale handle / 选择器不匹配 / 终端消失 / runtime 不可用 / 验证不匹配）
//   都 fail closed，且整体流程至多重试一次（初始尝试 + 1 次重试）。
// - macOS frontmost 激活在没有真实 GUI 证据时永不声称成功（本实现固定 .unsupported）。
@Suite struct SessionAwareJumpTests {

    // MARK: - 测试脚手架

    private let worktreeA = "111::/Users/dev/orca/repoA"
    private let worktreeB = "222::/Users/dev/orca/repoB"
    private let observedAt = Date(timeIntervalSince1970: 1_786_100_000)

    private func decodeSnapshot(
        psJSON: String = Fixtures.worktreePS,
        listJSON: String = Fixtures.terminalList
    ) throws -> FocusResolver.Snapshot {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(psJSON))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(listJSON))
        return FocusResolver.Snapshot(
            worktrees: ps.worktrees,
            terminals: list.terminals,
            layouts: list.visualLayouts
        )
    }

    private func snapshot(
        mutatingTerminals transform: (inout [TerminalInfo]) -> Void,
        mutatingLayouts layoutTransform: ((inout [VisualLayout]) -> Void)? = nil
    ) throws -> FocusResolver.Snapshot {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        var terminals = list.terminals
        transform(&terminals)
        var layouts = list.visualLayouts
        layoutTransform?(&layouts)
        return FocusResolver.Snapshot(worktrees: ps.worktrees, terminals: terminals, layouts: layouts)
    }

    private func ref(
        handle: String,
        worktree: String?,
        tab: String? = nil,
        leaf: String? = nil,
        correlation: JumpSessionCorrelation? = nil
    ) -> JumpTargetRef {
        JumpTargetRef(
            terminalHandle: handle,
            worktreeID: worktree,
            worktreePath: nil,
            tabID: tab,
            leafID: leaf,
            sessionCorrelation: correlation,
            observedAt: observedAt
        )
    }

    // MARK: - RouteResolver：实时路由重解析（纯函数）

    @Test func freshRouteWhenStoredHandleStillOccupiesStoredPaneSlot() throws {
        let snapshot = try decodeSnapshot()
        let resolution = RouteResolver.resolve(
            reference: ref(handle: "term_A2", worktree: worktreeA, tab: "tab2", leaf: "leaf2"),
            snapshot: snapshot
        )
        #expect(resolution == .fresh(JumpRoute(
            terminalHandle: "term_A2",
            worktreeID: worktreeA,
            tabID: "tab2",
            leafID: "leaf2",
            incarnation: .sameTerminalAsStored
        )))
    }

    @Test func reResolvesRouteWhenTerminalIncarnationChangedAtSamePaneSlot() throws {
        // 槽位 tab2:leaf2 现在由新 handle 占据：位置身份仍在，按选择器重解析到新 handle。
        let snapshot = try snapshot { terminals in
            let index = terminals.firstIndex { $0.handle == "term_A2" }!
            terminals[index].handle = "term_A2_new"
        }
        let resolution = RouteResolver.resolve(
            reference: ref(handle: "term_A2", worktree: worktreeA, tab: "tab2", leaf: "leaf2"),
            snapshot: snapshot
        )
        #expect(resolution == .fresh(JumpRoute(
            terminalHandle: "term_A2_new",
            worktreeID: worktreeA,
            tabID: "tab2",
            leafID: "leaf2",
            incarnation: .reResolvedFromSelector(previousHandle: "term_A2")
        )))
    }

    @Test func selectorMismatchWhenStoredSlotGoneAndHandleMovedElsewhere() throws {
        // 存储的槽位空了、handle 还活着但挂在别的槽：选择器证据矛盾 → fail closed。
        let snapshot = try snapshot { terminals in
            let index = terminals.firstIndex { $0.handle == "term_A2" }!
            terminals[index].tabId = "tab5"
            terminals[index].leafId = "leaf5"
        }
        let resolution = RouteResolver.resolve(
            reference: ref(handle: "term_A2", worktree: worktreeA, tab: "tab2", leaf: "leaf2"),
            snapshot: snapshot
        )
        guard case .failed(.selectorMismatch) = resolution else {
            Issue.record("槽位消失且 handle 挪位应 selectorMismatch，实际 \(resolution)")
            return
        }
    }

    @Test func terminalDisappearedWhenSlotAndHandleBothGone() throws {
        let snapshot = try snapshot { terminals in
            terminals.removeAll { $0.handle == "term_A2" }
        }
        let resolution = RouteResolver.resolve(
            reference: ref(handle: "term_A2", worktree: worktreeA, tab: "tab2", leaf: "leaf2"),
            snapshot: snapshot
        )
        guard case .failed(.terminalDisappeared) = resolution else {
            Issue.record("槽位与 handle 都消失应 terminalDisappeared，实际 \(resolution)")
            return
        }
    }

    @Test func degradedHandleOnlyRefResolvesWithWorktreeCheck() throws {
        // 无 pane 选择器（旧引用/数据缺失）时退化为 handle + worktree 校验。
        let snapshot = try decodeSnapshot()
        let resolution = RouteResolver.resolve(
            reference: ref(handle: "term_B1", worktree: worktreeB),
            snapshot: snapshot
        )
        #expect(resolution == .fresh(JumpRoute(
            terminalHandle: "term_B1",
            worktreeID: worktreeB,
            tabID: "tab3",
            leafID: "leaf3",
            incarnation: .sameTerminalAsStored
        )))
    }

    @Test func degradedRefFailsClosedWhenHandleNowBelongsToDifferentWorktree() throws {
        let snapshot = try decodeSnapshot()
        let resolution = RouteResolver.resolve(
            reference: ref(handle: "term_B1", worktree: worktreeA),
            snapshot: snapshot
        )
        guard case .failed(.selectorMismatch) = resolution else {
            Issue.record("handle 挂到别的 worktree 应 selectorMismatch，实际 \(resolution)")
            return
        }
    }

    @Test func degradedRefStaleWhenHandleMissing() throws {
        let snapshot = try decodeSnapshot()
        let resolution = RouteResolver.resolve(
            reference: ref(handle: "term_gone", worktree: nil),
            snapshot: snapshot
        )
        guard case .failed(.staleHandle) = resolution else {
            Issue.record("handle 不在 live terminals 应 staleHandle，实际 \(resolution)")
            return
        }
    }

    @Test func traeXCorrelationValidatesWorktreePathWhereAvailable() throws {
        let snapshot = try decodeSnapshot()
        let matching = RouteResolver.resolve(
            reference: ref(
                handle: "term_B1",
                worktree: worktreeB,
                tab: "tab3",
                leaf: "leaf3",
                correlation: .traeX(sessionID: "session-1", cwd: "/Users/dev/orca/repoB")
            ),
            snapshot: snapshot
        )
        guard case .fresh = matching else {
            Issue.record("cwd 匹配应放行，实际 \(matching)")
            return
        }

        let diverged = RouteResolver.resolve(
            reference: ref(
                handle: "term_B1",
                worktree: worktreeB,
                tab: "tab3",
                leaf: "leaf3",
                correlation: .traeX(sessionID: "session-1", cwd: "/Users/dev/orca/repoA")
            ),
            snapshot: snapshot
        )
        guard case .failed(.selectorMismatch) = diverged else {
            Issue.record("会话 cwd 与目标 worktree 不符应 fail closed，实际 \(diverged)")
            return
        }
    }

    @Test func supervisedWorkflowCorrelationIsNotCLIverifiableAndDoesNotBlock() throws {
        // CLI 数据没有 workflow→pane 关联：按"可得到的信息范围内"原则不阻塞槽位匹配。
        let snapshot = try decodeSnapshot()
        let resolution = RouteResolver.resolve(
            reference: ref(
                handle: "term_B1",
                worktree: worktreeB,
                tab: "tab3",
                leaf: "leaf3",
                correlation: .supervisedWorkflow(workflowID: "wf-1")
            ),
            snapshot: snapshot
        )
        guard case .fresh = resolution else {
            Issue.record("supervised 关联不可验证时不应阻塞，实际 \(resolution)")
            return
        }
    }

    // MARK: - SwitchVerifier：switch 后的 layout 验证（纯函数）

    private func routeB1() -> JumpRoute {
        JumpRoute(
            terminalHandle: "term_B1",
            worktreeID: "222::/Users/dev/orca/repoB",
            tabID: "tab3",
            leafID: "leaf3",
            incarnation: .sameTerminalAsStored
        )
    }

    @Test func verifierConfirmsTargetTabAndLeafActive() throws {
        let snapshot = try decodeSnapshot()
        let verification = SwitchVerifier.verify(route: routeB1(), snapshot: snapshot)
        #expect(verification == .layoutActive(
            worktreeID: "222::/Users/dev/orca/repoB",
            tabID: "tab3",
            leafID: "leaf3"
        ))
    }

    @Test func verifierMismatchesWhenAnotherTabIsActive() throws {
        let snapshot = try snapshot(mutatingTerminals: { _ in }) { layouts in
            let index = layouts.firstIndex { $0.worktreeId == "222::/Users/dev/orca/repoB" }!
            layouts[index].root.activeTabId = "tab4"
        }
        let verification = SwitchVerifier.verify(route: routeB1(), snapshot: snapshot)
        guard case .mismatch = verification else {
            Issue.record("其他 tab active 应 mismatch，实际 \(verification)")
            return
        }
    }

    @Test func verifierMismatchesWhenAnotherLeafIsActiveInSameTab() throws {
        let snapshot = try snapshot(mutatingTerminals: { _ in }) { layouts in
            let layoutIndex = layouts.firstIndex { $0.worktreeId == "222::/Users/dev/orca/repoB" }!
            let tabIndex = layouts[layoutIndex].root.tabs.firstIndex { $0.tabId == "tab3" }!
            layouts[layoutIndex].root.tabs[tabIndex].activeLeafId = "leaf3_other"
        }
        let verification = SwitchVerifier.verify(route: routeB1(), snapshot: snapshot)
        guard case .mismatch = verification else {
            Issue.record("同 tab 其他 leaf active 应 mismatch，实际 \(verification)")
            return
        }
    }

    @Test func verifierFallsBackToPaneActiveFlagWhenLeafIDMissing() throws {
        // activeLeafId 缺失时用 pane 树的 active 标志兜底：active=true → layoutActive，false → mismatch。
        func snapshotWithTab3Pane(active: Bool) throws -> FocusResolver.Snapshot {
            try snapshot(mutatingTerminals: { _ in }) { layouts in
                let layoutIndex = layouts.firstIndex { $0.worktreeId == "222::/Users/dev/orca/repoB" }!
                let tabIndex = layouts[layoutIndex].root.tabs.firstIndex { $0.tabId == "tab3" }!
                layouts[layoutIndex].root.tabs[tabIndex].activeLeafId = nil
                layouts[layoutIndex].root.tabs[tabIndex].panes = .terminal(PaneTerminal(
                    handle: "term_B1",
                    tabId: "tab3",
                    leafId: "leaf3",
                    title: "claude",
                    connected: true,
                    active: active
                ))
            }
        }

        let activeSnapshot = try snapshotWithTab3Pane(active: true)
        #expect(SwitchVerifier.verify(route: routeB1(), snapshot: activeSnapshot) == .layoutActive(
            worktreeID: "222::/Users/dev/orca/repoB",
            tabID: "tab3",
            leafID: "leaf3"
        ))

        let inactiveSnapshot = try snapshotWithTab3Pane(active: false)
        guard case .mismatch = SwitchVerifier.verify(route: routeB1(), snapshot: inactiveSnapshot) else {
            Issue.record("目标 pane active=false 应 mismatch")
            return
        }
    }

    @Test func verifierReportsUnverifiableWhenWorktreeHasNoLayout() throws {
        let snapshot = try decodeSnapshot(listJSON: Fixtures.terminalListNoFocus)
        let route = JumpRoute(
            terminalHandle: "term_X1",
            worktreeID: "333::/x",
            tabID: nil,
            leafID: nil,
            incarnation: .sameTerminalAsStored
        )
        guard case .unverifiable = SwitchVerifier.verify(route: route, snapshot: snapshot) else {
            Issue.record("无 layout 应 unverifiable")
            return
        }
    }

    // MARK: - SessionAwareJumper：fail-closed 编排 + 至多重试一次

    private actor MockJumpClient: SessionAwareJumpClient {
        private var snapshotScript: [Result<FocusResolver.Snapshot, any Error>]
        private var switchScript: [Result<Void, any Error>]
        private var fetchCount = 0
        private var switchCalls: [String] = []

        init(
            snapshotScript: [Result<FocusResolver.Snapshot, any Error>],
            switchScript: [Result<Void, any Error>] = []
        ) {
            self.snapshotScript = snapshotScript
            self.switchScript = switchScript
        }

        func fetchSnapshot() async throws -> FocusResolver.Snapshot {
            let index = min(fetchCount, snapshotScript.count - 1)
            fetchCount += 1
            return try snapshotScript[index].get()
        }

        func switchTerminal(handle: String) async throws {
            switchCalls.append(handle)
            guard !switchScript.isEmpty else { return }
            let index = min(switchCalls.count - 1, switchScript.count - 1)
            try switchScript[index].get()
        }

        var recordedFetchCount: Int { fetchCount }
        var recordedSwitchCalls: [String] { switchCalls }
    }

    @Test func freshRouteJumpsOnceAndVerifiesLayout() async throws {
        let snapshot = try decodeSnapshot()
        let client = MockJumpClient(snapshotScript: [.success(snapshot)])
        let jumper = SessionAwareJumper(client: client)

        let outcome = await jumper.jump(reference: ref(
            handle: "term_B1", worktree: worktreeB, tab: "tab3", leaf: "leaf3"
        ))

        guard case .succeeded(let success) = outcome else {
            Issue.record("fresh route 应成功，实际 \(outcome)")
            return
        }
        #expect(success.route.terminalHandle == "term_B1")
        #expect(success.verification == .layoutActive(
            worktreeID: worktreeB, tabID: "tab3", leafID: "leaf3"
        ))
        #expect(success.frontmost == .unsupported)
        #expect(success.attempts == 1)
        let switchCalls = await client.recordedSwitchCalls
        let fetchCount = await client.recordedFetchCount
        #expect(switchCalls == ["term_B1"])
        #expect(fetchCount == 2) // 解析前 1 次 + 验证前 1 次
    }

    @Test func staleHandleFromSwitchRetriesOnceWithReResolvedRoute() async throws {
        // 第一次 switch 被 CLI 判 stale（terminal_handle_stale，进程 exit 0、ok=false）；
        // 唯一一次重试用新快照按槽位重解析到换代 handle 后成功。
        let firstSnapshot = try decodeSnapshot()
        let reResolvedSnapshot = try snapshot { terminals in
            let index = terminals.firstIndex { $0.handle == "term_B1" }!
            terminals[index].handle = "term_B9"
        }
        let client = MockJumpClient(
            snapshotScript: [.success(firstSnapshot), .success(reResolvedSnapshot)],
            switchScript: [
                .failure(OrcaError.commandFailed("terminal_handle_stale")),
                .success(()),
            ]
        )
        let jumper = SessionAwareJumper(client: client)

        let outcome = await jumper.jump(reference: ref(
            handle: "term_B1", worktree: worktreeB, tab: "tab3", leaf: "leaf3"
        ))

        guard case .succeeded(let success) = outcome else {
            Issue.record("重试后应成功，实际 \(outcome)")
            return
        }
        #expect(success.route.terminalHandle == "term_B9")
        #expect(success.route.incarnation == .reResolvedFromSelector(previousHandle: "term_B1"))
        #expect(success.attempts == 2)
        let switchCalls = await client.recordedSwitchCalls
        #expect(switchCalls == ["term_B1", "term_B9"])
    }

    @Test func retriesAtMostOnceWhenSwitchKeepsBeingRejected() async throws {
        let snapshot = try decodeSnapshot()
        let client = MockJumpClient(
            snapshotScript: [.success(snapshot)],
            switchScript: [.failure(OrcaError.commandFailed("terminal_handle_stale"))]
        )
        let jumper = SessionAwareJumper(client: client)

        let outcome = await jumper.jump(reference: ref(
            handle: "term_B1", worktree: worktreeB, tab: "tab3", leaf: "leaf3"
        ))

        guard case .failed(let failure, let attempts) = outcome else {
            Issue.record("持续拒绝应失败，实际 \(outcome)")
            return
        }
        #expect(failure == .switchRejected(handle: "term_B1", message: "terminal_handle_stale"))
        #expect(attempts == 2) // 初始尝试 + 至多 1 次重试
        let switchCalls = await client.recordedSwitchCalls
        #expect(switchCalls.count == 2)
    }

    @Test func verificationMismatchFailsClosedAfterSingleRetry() async throws {
        // switch 命令 ok，但 post-switch layout 的 activeTab 始终不是目标 → fail closed。
        let mismatchSnapshot = try snapshot(mutatingTerminals: { _ in }) { layouts in
            let index = layouts.firstIndex { $0.worktreeId == "222::/Users/dev/orca/repoB" }!
            layouts[index].root.activeTabId = "tab4"
        }
        let client = MockJumpClient(snapshotScript: [.success(mismatchSnapshot)])
        let jumper = SessionAwareJumper(client: client)

        let outcome = await jumper.jump(reference: ref(
            handle: "term_B1", worktree: worktreeB, tab: "tab3", leaf: "leaf3"
        ))

        guard case .failed(let failure, let attempts) = outcome else {
            Issue.record("验证不匹配应失败，实际 \(outcome)")
            return
        }
        guard case .verificationMismatch = failure else {
            Issue.record("应为 verificationMismatch，实际 \(failure)")
            return
        }
        #expect(attempts == 2)
        let switchCalls = await client.recordedSwitchCalls
        #expect(switchCalls == ["term_B1", "term_B1"])
    }

    @Test func runtimeNotReadyFailsClosedAndNeverSwitches() async throws {
        let client = MockJumpClient(
            snapshotScript: [.failure(OrcaError.missingBinary("/usr/local/bin/orca"))]
        )
        let jumper = SessionAwareJumper(client: client)

        let outcome = await jumper.jump(reference: ref(handle: "term_B1", worktree: worktreeB))

        guard case .failed(.runtimeNotReady, let attempts) = outcome else {
            Issue.record("runtime 不可用应 fail closed，实际 \(outcome)")
            return
        }
        #expect(attempts == 2)
        let switchCalls = await client.recordedSwitchCalls
        #expect(switchCalls.isEmpty)
    }

    @Test func routeFailureNeverCallsSwitch() async throws {
        let snapshot = try decodeSnapshot()
        let client = MockJumpClient(snapshotScript: [.success(snapshot)])
        let jumper = SessionAwareJumper(client: client)

        let outcome = await jumper.jump(reference: ref(handle: "term_gone", worktree: nil))

        guard case .failed(.route(.staleHandle), let attempts) = outcome else {
            Issue.record("路由失败应 fail closed 且归因 route，实际 \(outcome)")
            return
        }
        #expect(attempts == 2)
        let switchCalls = await client.recordedSwitchCalls
        #expect(switchCalls.isEmpty)
    }

    @Test func unverifiableLayoutSucceedsWithExplicitCaveat() async throws {
        // worktree 无 layout 数据：命令成功 + 布局不可验证 → 成功但带 caveat，不声称布局已验证。
        let snapshot = try decodeSnapshot(listJSON: Fixtures.terminalListNoFocus)
        let client = MockJumpClient(snapshotScript: [.success(snapshot)])
        let jumper = SessionAwareJumper(client: client)

        let outcome = await jumper.jump(reference: ref(handle: "term_X1", worktree: "333::/x"))

        guard case .succeeded(let success) = outcome else {
            Issue.record("布局不可验证应仍算命令级成功，实际 \(outcome)")
            return
        }
        guard case .unverifiable = success.verification else {
            Issue.record("应为 unverifiable，实际 \(success.verification)")
            return
        }
        #expect(success.attempts == 1)
    }

    // MARK: - 状态文案（jump 状态 copy 的唯一来源；frontmost 永不声称成功）

    @Test func statusCopyDistinguishesVerificationTiers() throws {
        let route = routeB1()
        let verified = JumpSuccess(
            route: route,
            verification: .layoutActive(worktreeID: worktreeB, tabID: "tab3", leafID: "leaf3"),
            frontmost: .unsupported,
            attempts: 1
        )
        let unverifiable = JumpSuccess(
            route: route,
            verification: .unverifiable(reason: "no visual layout"),
            frontmost: .unsupported,
            attempts: 1
        )
        #expect(JumpStatusCopy.successMessage(verified) == "已切换并验证布局")
        #expect(JumpStatusCopy.successMessage(unverifiable) == "已切换（布局验证不可用）")

        let failureCopies: [String] = [
            JumpStatusCopy.failureMessage(.runtimeNotReady("x"), attempts: 2),
            JumpStatusCopy.failureMessage(.route(.staleHandle("term")), attempts: 2),
            JumpStatusCopy.failureMessage(.route(.selectorMismatch("x")), attempts: 2),
            JumpStatusCopy.failureMessage(.route(.terminalDisappeared("x")), attempts: 2),
            JumpStatusCopy.failureMessage(.switchRejected(handle: "term", message: nil), attempts: 2),
            JumpStatusCopy.failureMessage(.verificationMismatch("x"), attempts: 2),
        ]
        for copy in failureCopies {
            #expect(!copy.isEmpty)
            #expect(!copy.contains("已切换"))
        }
    }

    // MARK: - OrcaClient 作为只读快照/switch 通道的适配

    @Test func orcaClientFetchSnapshotCombinesBothReadQueries() async throws {
        let recorder = LockedBox([[String]]())
        let client = OrcaClient { args in
            recorder.with { $0.append(args) }
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return Fixtures.data(Fixtures.worktreePS) }
            return Fixtures.data(Fixtures.terminalList)
        }
        let jumpClient: any SessionAwareJumpClient = client
        let snapshot = try await jumpClient.fetchSnapshot()
        #expect(snapshot.worktrees.count == 2)
        #expect(snapshot.terminals.count == 5)
        #expect(snapshot.layouts.count == 2)
        let commands = recorder.with { $0 }
        #expect(commands.contains(["worktree", "ps", "--json"]))
        #expect(commands.contains(["terminal", "list", "--include-visual-layouts", "--json"]))
    }

    @Test func orcaClientSwitchDelegatesToTerminalSwitchPrimitive() async throws {
        let recorder = LockedBox([[String]]())
        let client = OrcaClient { args in
            recorder.with { $0.append(args) }
            return Fixtures.data(#"{"id":"cmd-js","ok":true,"result":{}}"#)
        }
        let jumpClient: any SessionAwareJumpClient = client
        try await jumpClient.switchTerminal(handle: "term_B1")
        #expect(recorder.with { $0 } == [["terminal", "switch", "--terminal", "term_B1", "--json"]])
    }
}
