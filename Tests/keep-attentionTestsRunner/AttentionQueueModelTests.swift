import Testing
import Foundation
@testable import KeepAttentionCore

// M1 runtime 集成：AttentionQueueModel 协调器。
// 覆盖：TraeX 事件→projection 出现/闭环、Orca 快照→ambient/coverage gap、
// markSeen/snooze/dismissStale、升级"至多一次+60s 节流"与抑制、
// jump reference 构造与 fail-closed、启动 restart→stale。
@MainActor
@Suite struct AttentionQueueModelTests {
    private let repoA = "/Users/dev/orca/repoA"

    // MARK: - 测试基建

    final class MutableClock: @unchecked Sendable {
        var current: Date
        init(_ current: Date) { self.current = current }
    }

    /// 内存 defaults：同时实现 Double 与 Data 存取（AttentionQueueDefaultsStoring）。
    final class InMemoryDefaults: AttentionQueueDefaultsStoring, @unchecked Sendable {
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

    private func makeOrca(
        ps: String = Fixtures.worktreePS,
        list: String = Fixtures.terminalList
    ) -> OrcaClient {
        OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("switch") { return Data(#"{"ok":true}"#.utf8) }
            if joined.contains("worktree") { return Fixtures.data(ps) }
            return Fixtures.data(list)
        }
    }

    private func makeFailingOrca() -> OrcaClient {
        OrcaClient { _ in throw OrcaError.missingBinary("/usr/local/bin/orca") }
    }

    private func makeModel(
        orca: OrcaClient? = nil,
        jumper: SessionAwareJumper? = nil,
        defaults: AttentionQueueDefaultsStoring = InMemoryDefaults(),
        clock: MutableClock
    ) -> AttentionQueueModel {
        AttentionQueueModel(orca: orca ?? makeOrca(), jumper: jumper, defaults: defaults) {
            clock.current
        }
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

    private func sessionStart(sessionID: String, cwd: String) -> TraeXEvent {
        TraeXEvent(hookEventName: TraeXEvent.sessionStart, sessionId: sessionID, cwd: cwd)
    }

    private func permissionEvent(
        sessionID: String,
        turnID: String,
        toolUseID: String,
        toolName: String = "Bash"
    ) -> TraeXEvent {
        TraeXEvent(
            hookEventName: TraeXEvent.permissionRequest,
            sessionId: sessionID,
            turnId: turnID,
            toolUseId: toolUseID,
            toolName: toolName
        )
    }

    private func questionOpened(sessionID: String, turnID: String, toolUseID: String) -> TraeXEvent {
        TraeXEvent(
            hookEventName: TraeXEvent.preToolUse,
            sessionId: sessionID,
            turnId: turnID,
            toolUseId: toolUseID,
            toolName: "request_user_input"
        )
    }

    private func toolDone(sessionID: String, turnID: String, toolUseID: String) -> TraeXEvent {
        TraeXEvent(
            hookEventName: TraeXEvent.postToolUse,
            sessionId: sessionID,
            turnId: turnID,
            toolUseId: toolUseID,
            toolName: "request_user_input"
        )
    }

    private func permissionCompleted(sessionID: String, turnID: String, toolUseID: String) -> TraeXEvent {
        TraeXEvent(
            hookEventName: TraeXEvent.postToolUse,
            sessionId: sessionID,
            turnId: turnID,
            toolUseId: toolUseID,
            toolName: "Bash"
        )
    }

    private func sessionEnd(sessionID: String) -> TraeXEvent {
        TraeXEvent(
            hookEventName: TraeXEvent.sessionEnd,
            sessionId: sessionID,
            turnId: "t-end",
            cwd: repoA
        )
    }

    // MARK: - TraeX 事件 → projection

    @Test func traeXPermissionEventSurfacesInQueueAndClosesOnCompletion() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(clock: clock)

        model.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        model.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))

        #expect(model.projection.requestCount == 1)
        #expect(model.projection.queueHead?.kindLabel == "Permission required")
        #expect(model.projection.queueHead?.statusLabel == "Unseen")
        #expect(model.headRequest?.key == .traeXTool(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))

        model.applyTraeXEvent(permissionCompleted(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        #expect(model.projection.requestCount == 0)
        #expect(model.projection.queueHead == nil)
        #expect(model.headRequest == nil)
    }

    @Test func traeXQuestionLifecycleOpensAndResolves() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(clock: clock)

        model.applyTraeXEvent(sessionStart(sessionID: "sQ", cwd: repoA))
        model.applyTraeXEvent(questionOpened(sessionID: "sQ", turnID: "tQ", toolUseID: "toolQ"))

        #expect(model.projection.queueHead?.kindLabel == "Answer required")
        #expect(model.projection.requestCount == 1)

        model.applyTraeXEvent(toolDone(sessionID: "sQ", turnID: "tQ", toolUseID: "toolQ"))
        #expect(model.projection.requestCount == 0)
    }

    @Test func sessionWithoutStartBoundaryReportsDiscoveryButStillMaps() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(clock: clock)

        // 未见 SessionStart 的会话事件：discovery 标记 start_boundary_missing。
        model.applyTraeXEvent(permissionEvent(sessionID: "sX", turnID: "tX", toolUseID: "toolX"))
        #expect(model.lastTraeXDiscovery == .startBoundaryMissing)
        #expect(model.projection.requestCount == 1)

        // SessionStart 之后同会话事件不再标记。
        model.applyTraeXEvent(sessionStart(sessionID: "sY", cwd: repoA))
        model.applyTraeXEvent(questionOpened(sessionID: "sY", turnID: "tY", toolUseID: "toolY"))
        #expect(model.lastTraeXDiscovery == nil)
    }

    // MARK: - Orca ambient 投影

    @Test func orcaPollFeedsAmbientEntriesAndCoverageGaps() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(clock: clock)

        await model.pollOrcaOnce()

        #expect(model.projection.ambient.count == 5)
        // fixtures 里只有 term_A2（111/tab2:leaf2）与 term_B1（222/tab3:leaf3）匹配 agent。
        let structured = model.projection.ambient.filter { $0.coverageLabel == "structured agent" }
        let gaps = model.projection.ambient.filter { $0.coverageLabel == "coverage gap" }
        #expect(structured.count == 2)
        #expect(gaps.count == 3)

        guard case let .ambient(title, detail, count) = model.projection.collapsed else {
            Issue.record("无 request 时 collapsed 应为 ambient，实际 \(model.projection.collapsed)")
            return
        }
        #expect(title.hasPrefix("Session Overview · 5"))
        #expect(detail.contains("3 coverage gaps"))
        #expect(count == 5)
    }

    @Test func orcaPollFailureMarksAmbientUnavailableWithoutCrash() async {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(orca: makeFailingOrca(), clock: clock)

        await model.pollOrcaOnce()

        #expect(model.projection.ambientAvailabilityLabel == "Orca unavailable")
        guard case let .ambient(title, _, count) = model.projection.collapsed else {
            Issue.record("期望 unavailable ambient collapsed")
            return
        }
        #expect(title == "Orca unavailable")
        #expect(count == 0)
        // 采集恢复后回到 available。
        let snapshot = try! makeSnapshot()
        model.applyOrcaSnapshot(snapshot)
        #expect(model.projection.ambientAvailabilityLabel == nil)
    }

    @Test func orcaPollFailureClearsPreviouslySuccessfulRowsRatherThanShowingStaleTruth() async {
        let calls = LockedBox(0)
        let orca = OrcaClient { args in
            let current = calls.with { value -> Int in
                defer { value += 1 }
                return value
            }
            if current < 2 {
                return Fixtures.data(args.contains("worktree") ? Fixtures.worktreePS : Fixtures.terminalList)
            }
            throw OrcaError.exit(1)
        }
        let clock = MutableClock(Date(timeIntervalSince1970: 1_787_300_000))
        let model = makeModel(orca: orca, clock: clock)

        await model.pollOrcaOnce()
        #expect(!model.projection.ambient.isEmpty)
        await model.pollOrcaOnce()

        #expect(model.projection.ambient.isEmpty)
        #expect(model.projection.ambientAvailabilityLabel == "Orca unavailable")
    }

    // MARK: - 操作端

    @Test func markSeenAndSnoozeUpdateQueuePlacement() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(clock: clock)
        model.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        model.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        let key = model.headRequest!.key

        model.markSeen(key)
        #expect(model.projection.queueHead?.statusLabel == "Seen != Resolved")
        #expect(model.projection.requestCount == 1)

        model.snooze(key, until: clock.current.addingTimeInterval(600))
        #expect(model.projection.requestCount == 0)
        #expect(model.projection.snoozed.count == 1)
        #expect(model.projection.queueHead == nil)

        // snooze 到期后回到队列（下一次状态变更/轮询重算时）。
        clock.current = clock.current.addingTimeInterval(601)
        model.applyTraeXEvent(sessionStart(sessionID: "sB", cwd: repoA))
        #expect(model.projection.requestCount == 1)
        #expect(model.projection.queueHead?.statusLabel == "Snoozed")
    }

    @Test func dismissStaleRemovesStaleHistory() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(clock: clock)
        model.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        model.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))

        model.applyTraeXEvent(sessionEnd(sessionID: "sA"))
        #expect(model.projection.staleHistory.count == 1)
        #expect(model.projection.requestCount == 0)

        model.dismissStale()
        #expect(model.projection.staleHistory.count == 0)
    }

    @Test func clearLocalHistoryKeepsActiveObligations() {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000_000))
        let model = makeModel(clock: clock)
        model.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        model.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        model.applyTraeXEvent(sessionEnd(sessionID: "sA"))
        model.applyTraeXEvent(permissionEvent(sessionID: "sB", turnID: "tB", toolUseID: "toolB"))
        #expect(model.projection.staleHistory.count == 1)
        #expect(model.projection.requestCount == 1)

        model.clearLocalHistory()
        #expect(model.projection.staleHistory.count == 0)
        #expect(model.projection.requestCount == 1)
    }

    // MARK: - 升级：至多一次 + 60s 全局节流 + 抑制

    @Test func escalationFiresOncePerObligationAndRespectsGlobalThrottle() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let clock = MutableClock(t0)
        let model = makeModel(clock: clock)

        model.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        model.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        #expect(model.lastEscalationNotice != nil)
        #expect(model.lastEscalationNotice?.escalatedAt == t0)
        #expect(model.headRequest?.escalationCount == 1)
        let firstNotice = model.lastEscalationNotice

        // 60 秒窗口内的第二个强义务：被全局节流抑制，不产生新升级。
        clock.current = t0.addingTimeInterval(10)
        model.applyTraeXEvent(permissionEvent(sessionID: "sB", turnID: "tB", toolUseID: "toolB"))
        #expect(model.lastEscalationNotice == firstNotice)
        let requestB = model.store.activeRequests.first {
            $0.key == .traeXTool(sessionID: "sB", turnID: "tB", toolUseID: "toolB")
        }
        #expect(requestB?.escalationCount == 0)

        // 窗口过后下一次状态变更：B 升级，A 不重复消耗配额。
        clock.current = t0.addingTimeInterval(70)
        model.applyTraeXEvent(sessionStart(sessionID: "sC", cwd: repoA))
        #expect(model.lastEscalationNotice != firstNotice)
        #expect(model.lastEscalationNotice?.escalatedAt == clock.current)
        let requestA = model.store.activeRequests.first {
            $0.key == .traeXTool(sessionID: "sA", turnID: "tA", toolUseID: "toolA")
        }
        let requestBAfter = model.store.activeRequests.first {
            $0.key == .traeXTool(sessionID: "sB", turnID: "tB", toolUseID: "toolB")
        }
        #expect(requestA?.escalationCount == 1)
        #expect(requestBAfter?.escalationCount == 1)

        // 再触发也不会第三次升级（两个义务配额均已用掉）。
        let noticeAfterSecond = model.lastEscalationNotice
        clock.current = t0.addingTimeInterval(200)
        model.applyTraeXEvent(sessionStart(sessionID: "sD", cwd: repoA))
        #expect(model.lastEscalationNotice == noticeAfterSecond)
    }

    @Test func escalationSuppressedWhenNotificationsDisabledOrWorkspaceMuted() async throws {
        // 全局通知开关关闭。
        let clock = MutableClock(Date(timeIntervalSince1970: 3_000_000))
        let disabledModel = makeModel(clock: clock)
        disabledModel.setNotificationsEnabled(false)
        disabledModel.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        disabledModel.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        #expect(disabledModel.lastEscalationNotice == nil)
        #expect(disabledModel.headRequest?.escalationCount == 0)

        // workspace 静音（cwd → worktree repo 解析后抑制该 session）。
        let mutedModel = makeModel(clock: clock)
        await mutedModel.pollOrcaOnce() // 载入 repoA worktree 证据
        mutedModel.setMuted("repoA", muted: true)
        mutedModel.applyTraeXEvent(sessionStart(sessionID: "sM", cwd: repoA))
        mutedModel.applyTraeXEvent(permissionEvent(sessionID: "sM", turnID: "tM", toolUseID: "toolM"))
        #expect(mutedModel.lastEscalationNotice == nil)

        // 同一 workspace 未静音时正常升级。
        let openModel = makeModel(clock: clock)
        await openModel.pollOrcaOnce()
        openModel.applyTraeXEvent(sessionStart(sessionID: "sN", cwd: repoA))
        openModel.applyTraeXEvent(permissionEvent(sessionID: "sN", turnID: "tN", toolUseID: "toolN"))
        #expect(openModel.lastEscalationNotice != nil)
    }

    @Test func controlsPersistAcrossModelInstances() {
        let defaults = InMemoryDefaults()
        let clock = MutableClock(Date(timeIntervalSince1970: 4_000_000))
        let first = makeModel(defaults: defaults, clock: clock)
        first.setNotificationsEnabled(false)
        first.setMuted("repoA", muted: true)

        let second = makeModel(defaults: defaults, clock: clock)
        second.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        second.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        #expect(second.lastEscalationNotice == nil) // notificationsEnabled=false 已持久化
    }

    // MARK: - 启动恢复（restart → stale）

    @Test func restartRestoresSnapshotMarksStaleAndKeepsSessionKnowledge() async throws {
        let defaults = InMemoryDefaults()
        let t0 = Date(timeIntervalSince1970: 5_000_000)
        let clock = MutableClock(t0)
        let first = makeModel(defaults: defaults, clock: clock)
        first.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        first.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        #expect(first.projection.requestCount == 1)

        // 新实例模拟 app 重启：恢复快照，active 义务降级 stale。
        let second = AttentionQueueModel(orca: makeOrca(), jumper: nil, defaults: defaults) {
            t0.addingTimeInterval(120)
        }
        #expect(second.projection.requestCount == 0)
        #expect(second.projection.staleHistory.count == 1)
        #expect(second.headRequest == nil)

        // 已见 session 集合与 cwd 映射恢复：同 session 后续事件不报 discovery，
        // 且 jump reference 可用 cwd 解析。
        second.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA2", toolUseID: "toolA2"))
        #expect(second.lastTraeXDiscovery == nil)
        #expect(second.projection.requestCount == 1)

        await second.pollOrcaOnce()
        let reference = second.jumpReference(for: second.headRequest!)
        #expect(reference?.sessionCorrelation == .traeX(sessionID: "sA", cwd: repoA))
        #expect(reference?.terminalHandle == "term_A2")
    }

    // MARK: - Jump reference 构造与 fail-closed

    @Test func jumpReferenceRequiresSnapshotCwdAndTraeXSession() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 6_000_000))
        let model = makeModel(clock: clock)
        model.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        model.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        let request = model.headRequest!

        // 尚无 Orca 快照：fail-closed。
        #expect(model.jumpReference(for: request) == nil)

        await model.pollOrcaOnce()
        let reference = model.jumpReference(for: request)
        #expect(reference != nil)
        #expect(reference?.worktreeID == "111::/Users/dev/orca/repoA")
        #expect(reference?.tabID == "tab2")
        #expect(reference?.leafID == "leaf2")

        // 未知 cwd：fail-closed。
        let orphanModel = makeModel(clock: clock)
        await orphanModel.pollOrcaOnce()
        orphanModel.applyTraeXEvent(sessionStart(sessionID: "sZ", cwd: "/no/such/path"))
        orphanModel.applyTraeXEvent(permissionEvent(sessionID: "sZ", turnID: "tZ", toolUseID: "toolZ"))
        #expect(orphanModel.jumpReference(for: orphanModel.headRequest!) == nil)
    }

    @Test func jumpUsesSessionAwareJumperAndFailClosedWithoutEvidence() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 7_000_000))
        let orca = makeOrca()
        let model = makeModel(orca: orca, jumper: SessionAwareJumper(client: orca), clock: clock)
        model.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        model.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))

        let outcome = await model.jump(for: model.headRequest!)
        guard case .succeeded(let success) = outcome else {
            Issue.record("期望跳转成功，实际 \(String(describing: outcome))")
            return
        }
        #expect(success.route.terminalHandle == "term_A2")
        #expect(success.verification == .layoutActive(worktreeID: "111::/Users/dev/orca/repoA", tabID: "tab2", leafID: "leaf2"))

        // 无 jumper / 无 cwd 证据：返回 nil，不执行任何 switch。
        let noJumperModel = makeModel(clock: clock)
        noJumperModel.applyTraeXEvent(sessionStart(sessionID: "sA", cwd: repoA))
        noJumperModel.applyTraeXEvent(permissionEvent(sessionID: "sA", turnID: "tA", toolUseID: "toolA"))
        let nilOutcome = await noJumperModel.jump(for: noJumperModel.headRequest!)
        #expect(nilOutcome == nil)
    }
}
