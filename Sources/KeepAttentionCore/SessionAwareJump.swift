import Foundation

// issue #33：session-aware jump（fail-closed 导航 + 验证）。
//
// 设计要点：
// - 稳定身份是"会话/证据引用"（pane 选择器 worktree/tab/leaf + 可验证的会话关联），
//   terminal handle 只是上次已知的提示，绝不作为持久身份直接信任。
// - 点击跳转时从当前 Orca 快照**重新解析**实时路由（runtime epoch 校验：CLI 输出没有
//   显式 epoch 字段，可得到范围内的等价做法是每次点击即时拉取完整快照并对选择器复验，
//   即路由新鲜度由"即时重拉 + 证据复验"保证；显式 epoch 标记属于已知验证缺口）。
// - 只有路由证据一致才调用底层 switch 原语（OrcaClient.terminalSwitch 保持不变）。
// - switch 后用最新 layout 数据验证目标 tab/pane 是否 active；验证不匹配 fail closed。
// - 整个流程至多重试一次（初始尝试 + 1 次重试）；每次重试都重新拉快照、重新解析。
// - macOS frontmost 激活层级：本实现没有任何真实 GUI 证据通道，固定报 `.unsupported`，
//   永不声称 frontmost 成功（真实 GUI 验证属于人工/真实运行验证缺口）。
// - 非目标：不向目标终端发送输入；不自动启动/重启 agent。

// MARK: - 跳转目标引用（稳定会话/证据引用）

/// 会话关联证据：在 CLI 数据可验证的范围内做身份交叉校验。
/// - traeX：sessionID + cwd，cwd 可对照 terminal 的 worktreePath/worktree 归属；
/// - supervisedWorkflow：CLI 暂无 workflow→pane 关联数据，按"可得到的信息范围内"原则不参与校验。
public enum JumpSessionCorrelation: Equatable, Sendable {
    case traeX(sessionID: String, cwd: String)
    case supervisedWorkflow(workflowID: String)
}

/// 点击跳转时携带的目标引用：pane 选择器是主身份，handle 只是 hint（issue #33）。
public struct JumpTargetRef: Equatable, Sendable {
    /// 上次已知的 terminal handle（提示，不作为持久身份）。
    public var terminalHandle: String
    public var worktreeID: String?
    public var worktreePath: String?
    public var tabID: String?
    public var leafID: String?
    public var sessionCorrelation: JumpSessionCorrelation?
    /// 路由证据的采集时间。路由新鲜度由跳转时即时重拉快照保证，此处仅作证据记录。
    public var observedAt: Date

    public init(
        terminalHandle: String,
        worktreeID: String?,
        worktreePath: String? = nil,
        tabID: String?,
        leafID: String?,
        sessionCorrelation: JumpSessionCorrelation? = nil,
        observedAt: Date
    ) {
        self.terminalHandle = terminalHandle
        self.worktreeID = worktreeID
        self.worktreePath = worktreePath
        self.tabID = tabID
        self.leafID = leafID
        self.sessionCorrelation = sessionCorrelation
        self.observedAt = observedAt
    }
}

// MARK: - 实时路由

/// 解析后的实时路由：应 switch 到的当前 handle + 其面板身份。
public struct JumpRoute: Equatable, Sendable {
    public var terminalHandle: String
    public var worktreeID: String?
    public var tabID: String?
    public var leafID: String?
    public var incarnation: JumpIncarnation

    public init(
        terminalHandle: String,
        worktreeID: String?,
        tabID: String?,
        leafID: String?,
        incarnation: JumpIncarnation
    ) {
        self.terminalHandle = terminalHandle
        self.worktreeID = worktreeID
        self.tabID = tabID
        self.leafID = leafID
        self.incarnation = incarnation
    }
}

/// 终端换代判定：槽位内 handle 是否与存储引用一致。
public enum JumpIncarnation: Equatable, Sendable {
    /// 槽位内仍是存储时的 handle（同一终端实例）。
    case sameTerminalAsStored
    /// 槽位内已是新 handle：位置身份未变，按选择器重解析到换代终端。
    case reResolvedFromSelector(previousHandle: String)
}

// MARK: - 路由解析失败（fail closed 语义）

/// 路由解析失败原因：
/// - staleHandle：存储的 handle 已不在 live terminals（CLI 语义的 stale）；
/// - selectorMismatch：handle 还活着，但身份证据（worktree/pane 槽位/会话关联）与实时状态矛盾；
/// - terminalDisappeared：存储的 pane 槽位与 handle 都已不存在。
public enum RouteFailure: Equatable, Sendable {
    case staleHandle(String)
    case selectorMismatch(String)
    case terminalDisappeared(String)
}

public enum RouteResolution: Equatable, Sendable {
    case fresh(JumpRoute)
    case failed(RouteFailure)
}

// MARK: - 路由解析器（纯函数）

public enum RouteResolver: Sendable {
    /// 从当前快照重新解析实时路由：
    /// 1. pane 槽位优先（worktree+tab+leaf 精确匹配），槽位内 handle 换代则按槽位重解析；
    /// 2. 槽位消失但 handle 挪到别处 → selectorMismatch（证据矛盾，fail closed）；
    /// 3. 槽位与 handle 都不在 → terminalDisappeared；
    /// 4. 无 pane 选择器（退化引用）时用 handle + worktree 校验，仍不匹配即 fail closed。
    public static func resolve(reference: JumpTargetRef, snapshot: FocusResolver.Snapshot) -> RouteResolution {
        if let worktreeID = reference.worktreeID,
           let tabID = reference.tabID,
           let leafID = reference.leafID {
            if let incumbent = snapshot.terminals.first(where: {
                $0.worktreeId == worktreeID && $0.tabId == tabID && $0.leafId == leafID
            }) {
                guard correlationHolds(reference, incumbent, snapshot) else {
                    return .failed(.selectorMismatch(
                        "session correlation diverged from terminal \(incumbent.handle)"
                    ))
                }
                let incarnation: JumpIncarnation = incumbent.handle == reference.terminalHandle
                    ? .sameTerminalAsStored
                    : .reResolvedFromSelector(previousHandle: reference.terminalHandle)
                return .fresh(JumpRoute(
                    terminalHandle: incumbent.handle,
                    worktreeID: incumbent.worktreeId,
                    tabID: incumbent.tabId,
                    leafID: incumbent.leafId,
                    incarnation: incarnation
                ))
            }
            if let moved = snapshot.terminals.first(where: { $0.handle == reference.terminalHandle }) {
                return .failed(.selectorMismatch(
                    "stored pane slot \(worktreeID)/\(tabID):\(leafID) is empty, but handle "
                        + "\(reference.terminalHandle) now lives at "
                        + "\(moved.worktreeId ?? "?")/\(moved.tabId ?? "?"):\(moved.leafId ?? "?")"
                ))
            }
            return .failed(.terminalDisappeared(
                "no live terminal occupies \(worktreeID)/\(tabID):\(leafID) "
                    + "and handle \(reference.terminalHandle) is gone"
            ))
        }

        // 退化路径：引用缺 pane 选择器（旧数据/数据缺失），仅 handle + worktree 证据。
        guard let live = snapshot.terminals.first(where: { $0.handle == reference.terminalHandle }) else {
            return .failed(.staleHandle(
                "handle \(reference.terminalHandle) not found among \(snapshot.terminals.count) live terminals"
            ))
        }
        if let worktreeID = reference.worktreeID, live.worktreeId != worktreeID {
            return .failed(.selectorMismatch(
                "handle \(reference.terminalHandle) now belongs to worktree \(live.worktreeId ?? "?") "
                    + "instead of \(worktreeID)"
            ))
        }
        guard correlationHolds(reference, live, snapshot) else {
            return .failed(.selectorMismatch(
                "session correlation diverged from terminal \(live.handle)"
            ))
        }
        return .fresh(JumpRoute(
            terminalHandle: live.handle,
            worktreeID: live.worktreeId,
            tabID: live.tabId,
            leafID: live.leafId,
            incarnation: .sameTerminalAsStored
        ))
    }

    /// 会话关联校验（可得到的信息范围内）：
    /// TraeX 用 cwd 对照 terminal 的 worktreePath 或其 worktree 归属路径；supervised 无数据不校验。
    private static func correlationHolds(
        _ reference: JumpTargetRef,
        _ terminal: TerminalInfo,
        _ snapshot: FocusResolver.Snapshot
    ) -> Bool {
        guard case let .traeX(_, cwd) = reference.sessionCorrelation else { return true }
        if terminal.worktreePath == cwd { return true }
        guard let worktreeID = terminal.worktreeId else { return false }
        return snapshot.worktrees
            .first { $0.worktreeId == worktreeID }?
            .path == cwd
    }
}

// MARK: - switch 后的布局验证（纯函数）

public enum SwitchVerification: Equatable, Sendable {
    /// layout 数据确认目标 worktree 的 activeTabId/activeLeafId 指向路由目标。
    case layoutActive(worktreeID: String?, tabID: String?, leafID: String?)
    /// 布局数据不可用（worktree 无 layout / 缺 activeTabId 等）：不声称验证成功，也不算失败。
    case unverifiable(reason: String)
    /// 布局存在但 active 指向别处：验证不匹配。
    case mismatch(detail: String)
}

public enum SwitchVerifier: Sendable {
    /// 用 switch 后拉取的快照验证目标 tab/pane 是否 active：
    /// activeTabId 必须等于路由 tabID；leaf 层优先 activeLeafId，缺失时用 pane 树 active 标志兜底。
    public static func verify(route: JumpRoute, snapshot: FocusResolver.Snapshot) -> SwitchVerification {
        guard let worktreeID = route.worktreeID else {
            return .unverifiable(reason: "route has no worktree identity")
        }
        guard let layout = snapshot.layouts.first(where: { $0.worktreeId == worktreeID }) else {
            return .unverifiable(reason: "no visual layout for worktree \(worktreeID)")
        }
        guard let tabID = route.tabID else {
            return .unverifiable(reason: "route has no tab identity")
        }
        guard let activeTabID = layout.root.activeTabId else {
            return .unverifiable(reason: "layout for \(worktreeID) has no activeTabId")
        }
        guard activeTabID == tabID else {
            return .mismatch(detail: "active tab \(activeTabID) != target \(tabID)")
        }
        let activeTab = layout.root.tabs.first { $0.tabId == activeTabID }
        if let activeLeafID = activeTab?.activeLeafId {
            guard activeLeafID == route.leafID else {
                return .mismatch(detail: "active leaf \(activeLeafID) != target \(route.leafID ?? "?")")
            }
            return .layoutActive(worktreeID: worktreeID, tabID: tabID, leafID: activeLeafID)
        }
        guard let activeTab else {
            return .unverifiable(reason: "active tab \(activeTabID) missing from layout tabs")
        }
        // activeLeafId 缺失：用 pane 树中路由目标的 active 标志兜底。
        switch paneTerminal(handle: route.terminalHandle, in: activeTab.panes) {
        case .some(let pane) where pane.active == true:
            return .layoutActive(worktreeID: worktreeID, tabID: tabID, leafID: route.leafID)
        case .some:
            return .mismatch(detail: "target pane \(route.terminalHandle) exists but is not active")
        case .none:
            return .unverifiable(reason: "target pane \(route.terminalHandle) not found in active tab tree")
        }
    }

    private static func paneTerminal(handle: String, in node: PaneNode) -> PaneTerminal? {
        switch node {
        case .terminal(let pane):
            return pane.handle == handle ? pane : nil
        case .split(let split):
            return paneTerminal(handle: handle, in: split.first)
                ?? paneTerminal(handle: handle, in: split.second)
        case .unknown:
            return nil
        }
    }
}

// MARK: - 副作用通道（注入的 client 抽象）

/// jump 流程仅有的两类副作用：拉取只读快照、调用底层 switch 原语。
public protocol SessionAwareJumpClient: Sendable {
    /// 一次拉取构成路由/验证依据的完整快照（worktrees + terminals + layouts）。
    func fetchSnapshot() async throws -> FocusResolver.Snapshot
    /// 底层 switch 原语（等价于 `orca terminal switch --terminal <handle> --json`）。
    func switchTerminal(handle: String) async throws
}

extension OrcaClient: SessionAwareJumpClient {
    /// 只读组合查询：worktree ps + terminal list（含 visual layouts）。
    /// 两次调用非原子，接受快照内轻微时序偏差（fail-closed 验证会复拉复核）。
    public func fetchSnapshot() async throws -> FocusResolver.Snapshot {
        async let ps = worktreePS()
        async let list = terminalList()
        let (psResult, listResult) = try await (ps, list)
        return FocusResolver.Snapshot(
            worktrees: psResult.worktrees,
            terminals: listResult.terminals,
            layouts: listResult.visualLayouts
        )
    }

    public func switchTerminal(handle: String) async throws {
        try await terminalSwitch(handle: handle)
    }
}

// MARK: - 结果分层

/// macOS frontmost/应用激活层级：本实现无真实 GUI 证据通道，永不声称已验证。
/// 宣称 verified 需要真实运行环境的 GUI 证据（人工/真实运行验证缺口）。
public enum JumpFrontmostStatus: Equatable, Sendable {
    case unsupported
}

/// 跳转失败原因（全部 fail closed：绝不带着不确定路由执行 switch 后就当成功）。
public enum JumpFailure: Error, Equatable, Sendable {
    /// Orca 快照不可得（CLI 缺失/退出码/解析失败）。
    case runtimeNotReady(String)
    /// 路由重解析失败（stale handle / 选择器不匹配 / 终端消失）。
    case route(RouteFailure)
    /// 底层 switch 命令业务失败（如 terminal_handle_stale）。
    case switchRejected(handle: String, message: String?)
    /// switch 后布局验证不匹配。
    case verificationMismatch(String)
}

public struct JumpSuccess: Equatable, Sendable {
    public var route: JumpRoute
    public var verification: SwitchVerification
    public var frontmost: JumpFrontmostStatus
    public var attempts: Int

    public init(
        route: JumpRoute,
        verification: SwitchVerification,
        frontmost: JumpFrontmostStatus,
        attempts: Int
    ) {
        self.route = route
        self.verification = verification
        self.frontmost = frontmost
        self.attempts = attempts
    }
}

public enum JumpOutcome: Equatable, Sendable {
    case succeeded(JumpSuccess)
    case failed(JumpFailure, attempts: Int)
}

// MARK: - 编排：初始尝试 + 至多一次重试

public struct SessionAwareJumper: Sendable {
    /// 至多重试一次（初始尝试 + 1 次重试 = 至多 2 次尝试）。
    public static let maxRetries = 1

    public let client: any SessionAwareJumpClient

    public init(client: any SessionAwareJumpClient) {
        self.client = client
    }

    public func jump(reference: JumpTargetRef) async -> JumpOutcome {
        var lastFailure: JumpFailure?
        var attempts = 0
        while attempts <= Self.maxRetries {
            attempts += 1
            switch await attemptOnce(reference: reference) {
            case .success(var success):
                success.attempts = attempts
                return .succeeded(success)
            case .failure(let failure):
                lastFailure = failure
            }
        }
        return .failed(lastFailure ?? .runtimeNotReady("unknown"), attempts: attempts)
    }

    /// 单次尝试：拉快照 → 重解析路由 → switch → 复拉快照 → 布局验证。
    /// 任何一步失败都立即 fail closed，由外层决定是否用掉唯一一次重试。
    private func attemptOnce(reference: JumpTargetRef) async -> Result<JumpSuccess, JumpFailure> {
        let snapshot: FocusResolver.Snapshot
        do {
            snapshot = try await client.fetchSnapshot()
        } catch {
            return .failure(.runtimeNotReady(Self.describe(error)))
        }

        let route: JumpRoute
        switch RouteResolver.resolve(reference: reference, snapshot: snapshot) {
        case .fresh(let resolved):
            route = resolved
        case .failed(let routeFailure):
            return .failure(.route(routeFailure))
        }

        do {
            try await client.switchTerminal(handle: route.terminalHandle)
        } catch let error as OrcaError {
            if case .commandFailed(let message) = error {
                return .failure(.switchRejected(handle: route.terminalHandle, message: message))
            }
            return .failure(.runtimeNotReady(Self.describe(error)))
        } catch {
            return .failure(.runtimeNotReady(Self.describe(error)))
        }

        let postSwitch: FocusResolver.Snapshot
        do {
            postSwitch = try await client.fetchSnapshot()
        } catch {
            return .failure(.runtimeNotReady(Self.describe(error)))
        }

        switch SwitchVerifier.verify(route: route, snapshot: postSwitch) {
        case .mismatch(let detail):
            return .failure(.verificationMismatch(detail))
        case .layoutActive, .unverifiable:
            return .success(JumpSuccess(
                route: route,
                verification: SwitchVerifier.verify(route: route, snapshot: postSwitch),
                frontmost: .unsupported,
                attempts: 0
            ))
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case OrcaError.missingBinary(let path):
            return "orca CLI unavailable (\(path))"
        case OrcaError.exit(let code):
            return "orca command failed (exit \(code))"
        case OrcaError.emptyOutput:
            return "orca output undecodable"
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - jump 状态文案（Views 层唯一 copy 来源）

/// 分层状态文案：成功只声称"Orca 内部目标已选中（布局已验证/不可验证）"，
/// frontmost 层级永不声称成功；失败文案保持可恢复、不惊吓（issue #33 非目标：不做 UI 大改）。
public enum JumpStatusCopy {
    public static func successMessage(_ success: JumpSuccess) -> String {
        switch success.verification {
        case .layoutActive:
            return "已切换并验证布局"
        case .unverifiable:
            return "已切换（布局验证不可用）"
        case .mismatch:
            return "切换后布局未指向目标"
        }
    }

    public static func failureMessage(_ failure: JumpFailure, attempts: Int) -> String {
        switch failure {
        case .runtimeNotReady:
            return "Orca 状态不可用，稍后重试"
        case .route(.staleHandle):
            return "目标终端句柄已失效，请刷新后重试"
        case .route(.selectorMismatch):
            return "终端身份与记录不匹配，已取消跳转"
        case .route(.terminalDisappeared):
            return "目标终端已关闭"
        case .switchRejected:
            return attempts > 1 ? "Orca 拒绝切换，已停止重试" : "Orca 拒绝切换"
        case .verificationMismatch:
            return "切换后未验证到目标面板，请手动确认"
        }
    }
}
