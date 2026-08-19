import Foundation
import Observation

// M1 runtime 集成：AttentionQueueModel 运行时协调器。
//
// 设计要点：
// - 本模型是 keep-attention 唯一的 request-centric 表面：把真实 TraeX hook
//   事件 + Orca 快照喂进 #29~#35 的纯领域内核
//   （adapter / store / sorter / projection / escalation / jump）。
// - TraeX 是唯一 AttentionRequest 来源；Orca 侧只做 Ambient 投影
//   （OrcaAttentionAdapter.adapt 的 supervisedSignals 恒为空数组）。
// - 升级只在 runtime 计算 + 应用内呈现（AttentionEscalationNotice），
//   绝不接 macOS 系统通知；每次状态变更至多升级一个队首优先的强义务，
//   至多一次/义务（escalationCount）+ 全局 60s 节流由 EscalationPolicy 保证。
// - escalation 字段写回：store 没有对应 mutation，本模型用公开的
//   snapshot()/init(snapshot:) 重建 store（EscalationPolicy.markEscalated 文档
//   预期的"调用方写回副本"方式），不改动 #29 既有文件。
// - Jump：sessionID→cwd（来自 TraeX 事件）+ 最近 Orca 快照解析 JumpTargetRef；
//   解析不出返回 nil（fail-closed），点击时再由 SessionAwareJumper 即时重拉验证。
// - 持久化：store 快照 + 已见 session 集合 + sessionID→cwd 映射存为一个 JSON
//   payload；升级/workspace 控制状态存另一个 JSON payload。key 见下方常量注释。
//
// 人工/真实运行验证缺口：真实 TraeX hook 载入、菜单栏浮层交互、真实 Orca CLI
// 环境下的 poll/jump 行为需真机验证；单元测试只覆盖协调逻辑。

// MARK: - Defaults 抽象

/// UserDefaults 抽象（测试注入内存实现）：轮询间隔等 Double 配置存取。
public protocol DefaultsStoring: Sendable {
    func double(forKey key: String) -> Double
    func set(_ value: Double, forKey key: String)
}

extension UserDefaults: DefaultsStoring {}

/// `DefaultsStoring` 只支持 Double；持久化 Codable payload 需要
/// Data 存取。这里定义子协议并让 UserDefaults 在本文件扩展
/// 遵循（UserDefaults 天然具备这两个方法的精确签名）。
public protocol AttentionQueueDefaultsStoring: DefaultsStoring {
    func data(forKey key: String) -> Data?
    func set(_ value: Data, forKey key: String)
}

extension UserDefaults: AttentionQueueDefaultsStoring {
    /// UserDefaults 对 Data 没有精确的 set 重载（只有 Any? 版本），这里显式桥接。
    public func set(_ value: Data, forKey key: String) {
        set(value as Any?, forKey: key)
    }
}

// MARK: - 持久化 payload

/// 运行时持久化 payload v1：store 快照 + TraeX 会话知识。
/// key：`attentionQueue.runtimePersistence.v1`。
public struct AttentionQueueRuntimePayload: Codable, Equatable, Sendable {
    public var snapshot: AttentionRequestPersistenceSnapshot
    public var seenTraeXSessionIDs: [String]
    public var traeXSessionCWDMappings: [String: String]

    public init(
        snapshot: AttentionRequestPersistenceSnapshot,
        seenTraeXSessionIDs: [String],
        traeXSessionCWDMappings: [String: String]
    ) {
        self.snapshot = snapshot
        self.seenTraeXSessionIDs = seenTraeXSessionIDs
        self.traeXSessionCWDMappings = traeXSessionCWDMappings
    }
}

/// 升级/workspace 控制状态 payload v1（通知开关 + mute + AI opt-in）。
/// key：`attentionQueue.controls.v1`。
public struct AttentionQueueControlsSnapshot: Codable, Equatable, Sendable {
    public var notificationsEnabled: Bool
    public var workspaceControls: WorkspaceControlsState

    public init(
        notificationsEnabled: Bool = true,
        workspaceControls: WorkspaceControlsState = WorkspaceControlsState()
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.workspaceControls = workspaceControls
    }
}

// MARK: - 应用内升级呈现

/// 一次强升级的应用内呈现信号（不接系统通知）。只携带安全 kind 标签与时间。
public struct AttentionEscalationNotice: Equatable, Sendable {
    public var kindLabel: String
    public var escalatedAt: Date

    public init(kindLabel: String, escalatedAt: Date) {
        self.kindLabel = kindLabel
        self.escalatedAt = escalatedAt
    }
}

// MARK: - 运行时协调器

@MainActor
@Observable
public final class AttentionQueueModel {
    /// store 快照 + TraeX 会话知识（v1，见 AttentionQueueRuntimePayload 注释）。
    public static let runtimeStorageKey = "attentionQueue.runtimePersistence.v1"
    /// 升级/workspace 控制状态（v1，见 AttentionQueueControlsSnapshot 注释）。
    public static let controlsStorageKey = "attentionQueue.controls.v1"
    /// Orca ambient 轮询间隔的持久化 key（沿用历史 key，保持用户既有配置兼容）。
    public static let pollIntervalKey = "pollIntervalSeconds"
    /// Orca ambient 轮询间隔默认值（秒）。
    public static let defaultPollInterval: Double = 5

    // 依赖（可注入）
    private let orca: OrcaClient
    private let jumper: SessionAwareJumper?
    private let defaults: any AttentionQueueDefaultsStoring
    private let now: () -> Date

    // 领域内核状态
    private(set) var store = AttentionRequestStore()
    private(set) var throttle = InterruptionThrottleState()
    private(set) var workspaceControls = WorkspaceControlsState()
    private(set) var notificationsEnabled = true

    // TraeX 会话知识
    /// 已见 sessionID 集合：只有 SessionStart 记入（语义 = 见过会话起点边界）。
    private(set) var seenTraeXSessionIDs: Set<String> = []
    /// sessionID → cwd：jump reference 与 workspace(repo) 解析依据。
    private(set) var traeXSessionCWDMappings: [String: String] = [:]
    private(set) var lastTraeXDiscovery: TraeXSessionDiscovery?

    // Ambient（Orca 只读投影）
    private(set) var ambient = AmbientOverview(entries: [])
    private(set) var ambientAvailability: AmbientAvailability = .available
    private(set) var latestOrcaSnapshot: FocusResolver.Snapshot?

    // 发布给 UI 的派生状态
    public private(set) var projection: AttentionQueueProjection
    /// 排序后的队首 active 请求（UI 操作回调构造用）。
    public private(set) var headRequest: AttentionRequest?
    /// 最近一次强升级信号（应用内 banner 呈现；不重复、不外发）。
    public private(set) var lastEscalationNotice: AttentionEscalationNotice?

    /// Orca ambient 轮询间隔：读取 `pollIntervalKey` 持久化值，默认 5s。
    public let pollInterval: Double

    public init(
        orca: OrcaClient,
        jumper: SessionAwareJumper?,
        defaults: any AttentionQueueDefaultsStoring = UserDefaults.standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.orca = orca
        self.jumper = jumper
        self.defaults = defaults
        self.now = now

        let storedInterval = defaults.double(forKey: Self.pollIntervalKey)
        self.pollInterval = storedInterval > 0 ? storedInterval : Self.defaultPollInterval

        if let data = defaults.data(forKey: Self.controlsStorageKey),
           let controls = try? JSONDecoder().decode(AttentionQueueControlsSnapshot.self, from: data) {
            self.notificationsEnabled = controls.notificationsEnabled
            self.workspaceControls = controls.workspaceControls
        } else {
            self.notificationsEnabled = true
            self.workspaceControls = WorkspaceControlsState()
        }

        if let data = defaults.data(forKey: Self.runtimeStorageKey),
           let payload = try? JSONDecoder().decode(AttentionQueueRuntimePayload.self, from: data) {
            self.store = AttentionRequestStore(snapshot: payload.snapshot, now: now())
            self.seenTraeXSessionIDs = Set(payload.seenTraeXSessionIDs)
            self.traeXSessionCWDMappings = payload.traeXSessionCWDMappings
        } else {
            self.store = AttentionRequestStore()
            self.seenTraeXSessionIDs = []
            self.traeXSessionCWDMappings = [:]
        }

        self.projection = AttentionQueueProjection.make(
            store: AttentionRequestStore(),
            ambient: AmbientOverview(entries: []),
            now: now(),
            aiSummariesEnabled: false
        )

        // 启动恢复：重启前的 active 义务一律降级 stale（state needs confirmation）。
        store.apply(TraeXAttentionAdapter.staleAfterRestart(observedAt: now()))
        recomputeProjection()
        persist()
    }

    // MARK: - 输入端：TraeX hook 事件

    /// 真实 TraeX hook 事件 → TraeXAttentionAdapter → store。
    /// SessionStart 记入已见集合；所有带 cwd 的事件刷新 sessionID→cwd 映射。
    public func applyTraeXEvent(_ event: TraeXEvent) {
        let observedAt = now()
        let sessionID = event.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionIsKnown = sessionID.map { seenTraeXSessionIDs.contains($0) } ?? false
        let result = TraeXAttentionAdapter.adapt(
            event,
            observedAt: observedAt,
            sessionIsKnown: sessionIsKnown
        )
        if let sessionID, !sessionID.isEmpty {
            if event.hookEventName == TraeXEvent.sessionStart {
                seenTraeXSessionIDs.insert(sessionID)
            }
            if let cwd = event.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
                traeXSessionCWDMappings[sessionID] = cwd
            }
        }
        for domainEvent in result.events {
            store.apply(domainEvent)
        }
        lastTraeXDiscovery = result.discovery
        refresh()
    }

    // MARK: - 输入端：Orca ambient

    /// Orca 快照 → 仅 Ambient 投影（supervisedSignals 恒空，不产生 AttentionRequest）。
    public func applyOrcaSnapshot(_ snapshot: FocusResolver.Snapshot) {
        let result = OrcaAttentionAdapter.adapt(
            snapshot: snapshot,
            supervisedSignals: [],
            observedAt: now()
        )
        ambient = result.ambient
        latestOrcaSnapshot = snapshot
        ambientAvailability = .available
        recomputeProjection()
    }

    /// 一次 Orca 采集：成功更新 ambient；失败标记 unavailable（不崩溃）。
    public func pollOrcaOnce() async {
        do {
            let snapshot = try await orca.fetchSnapshot()
            applyOrcaSnapshot(snapshot)
        } catch {
            ambientAvailability = .unavailable
            recomputeProjection()
        }
    }

    // MARK: - 操作端

    public func markSeen(_ key: AttentionRequestKey) {
        store.apply(.markSeen(key: key, observedAt: now()))
        refresh()
    }

    public func snooze(_ key: AttentionRequestKey, until: Date) {
        store.apply(.snooze(key: key, until: until, observedAt: now()))
        refresh()
    }

    /// Dismiss stale：key 为 nil 时清除全部 stale 历史，否则只清除指定义务。
    public func dismissStale(_ key: AttentionRequestKey? = nil) {
        let dismissed = StaleDismissal.dismissStale(
            in: store.snapshot(now: now()),
            matching: key.map { [$0] }
        )
        store = AttentionRequestStore(snapshot: dismissed, now: now())
        refresh()
    }

    /// 清空全部 closed 历史，保留进行中的义务。
    public func clearLocalHistory() {
        let cleared = LocalHistoryClearance.clearClosedHistory(in: store.snapshot(now: now()))
        store = AttentionRequestStore(snapshot: cleared, now: now())
        refresh()
    }

    // MARK: - 控制端（mute / 通知开关 / AI opt-in，持久化）

    public func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        persistControls()
        refresh()
    }

    public func setMuted(_ workspaceID: String, muted: Bool) {
        workspaceControls.setMuted(workspaceID, muted: muted)
        persistControls()
        refresh()
    }

    public func setAISummaryOptIn(_ workspaceID: String, enabled: Bool) {
        workspaceControls.setAISummaryOptIn(workspaceID, enabled: enabled)
        persistControls()
        refresh()
    }

    // MARK: - Jump

    /// 用最近 Orca 快照解析 jump reference；解析不出返回 nil（fail-closed）。
    public func jumpReference(for request: AttentionRequest) -> JumpTargetRef? {
        guard case let .traeX(sessionID) = request.sessionKey,
              let cwd = traeXSessionCWDMappings[sessionID]
        else { return nil }
        guard let snapshot = latestOrcaSnapshot else { return nil }
        return Self.makeJumpReference(
            sessionID: sessionID,
            cwd: cwd,
            snapshot: snapshot,
            observedAt: now(),
            focusedHandle: FocusResolver(snapshot: snapshot).focusedHandle()
        )
    }

    /// 点击跳转：优先即时拉取新快照（失败回退最近快照），构造 reference 后交给
    /// SessionAwareJumper（其内部还会重拉验证，路由不一致 fail-closed）。
    public func jump(for request: AttentionRequest) async -> JumpOutcome? {
        guard let jumper,
              case let .traeX(sessionID) = request.sessionKey,
              let cwd = traeXSessionCWDMappings[sessionID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty
        else { return nil }
        let snapshot = (try? await orca.fetchSnapshot()) ?? latestOrcaSnapshot
        guard let snapshot else { return nil }
        guard let reference = Self.makeJumpReference(
            sessionID: sessionID,
            cwd: cwd,
            snapshot: snapshot,
            observedAt: now(),
            focusedHandle: FocusResolver(snapshot: snapshot).focusedHandle()
        ) else { return nil }
        return await jumper.jump(reference: reference)
    }

    /// 纯函数：cwd 匹配的 live terminals 中优先焦点、否则第一个，构造带
    /// sessionCorrelation 的 JumpTargetRef；无候选返回 nil。
    static func makeJumpReference(
        sessionID: String,
        cwd: String,
        snapshot: FocusResolver.Snapshot,
        observedAt: Date,
        focusedHandle: String?
    ) -> JumpTargetRef? {
        let cwdWorktreeIDs = Set(snapshot.worktrees.filter { $0.path == cwd }.map(\.worktreeId))
        let candidates = snapshot.terminals.filter { terminal in
            terminal.worktreePath == cwd || (terminal.worktreeId.map(cwdWorktreeIDs.contains) ?? false)
        }
        guard let target = candidates.first(where: { $0.handle == focusedHandle }) ?? candidates.first else {
            return nil
        }
        return JumpTargetRef(
            terminalHandle: target.handle,
            worktreeID: target.worktreeId,
            worktreePath: target.worktreePath,
            tabID: target.tabId,
            leafID: target.leafId,
            sessionCorrelation: .traeX(sessionID: sessionID, cwd: cwd),
            observedAt: observedAt
        )
    }

    // MARK: - 状态变更后的统一收口

    /// 升级判定 → 重算投影 → 持久化。
    private func refresh() {
        runEscalationIfNeeded()
        recomputeProjection()
        persist()
    }

    /// 对排序后的强阻塞候选（队首优先）跑升级判定；每次状态变更至多升级一个。
    /// 全局开关/mute/snooze/seen/已升级配额/60s 节流全部由 EscalationPolicy 抑制。
    private func runEscalationIfNeeded() {
        let currentNow = now()
        let candidates = GlobalAttentionQueueSorter.sorted(store.activeRequests, now: currentNow)
            .filter { EscalationPolicy.strongBlockingKinds.contains($0.kind) }
        for candidate in candidates {
            let verdict = EscalationPolicy.evaluate(
                request: candidate,
                now: currentNow,
                mutedSessionKeys: mutedSessionKeys,
                notificationsEnabled: notificationsEnabled,
                throttle: throttle
            )
            if case .escalate = verdict {
                writeBackActiveRequest(EscalationPolicy.markEscalated(request: candidate, at: currentNow))
                throttle.recordEscalation(at: currentNow)
                lastEscalationNotice = AttentionEscalationNotice(
                    kindLabel: Self.escalationKindLabel(candidate.kind),
                    escalatedAt: currentNow
                )
                return
            }
        }
    }

    /// 把更新了 escalation 字段的副本写回 store 内对应 active request。
    /// store 无对应 mutation：用公开 snapshot()/init(snapshot:) 重建（不改 #29 文件）。
    private func writeBackActiveRequest(_ request: AttentionRequest) {
        var snapshot = store.snapshot(now: now())
        guard let index = snapshot.activeRequests.firstIndex(where: { $0.key == request.key }) else {
            return
        }
        snapshot.activeRequests[index] = request
        store = AttentionRequestStore(snapshot: snapshot, now: now())
    }

    private func recomputeProjection() {
        let currentNow = now()
        let sorted = GlobalAttentionQueueSorter.sorted(store.activeRequests, now: currentNow)
        headRequest = sorted.first
        let aiSummariesEnabled: Bool
        if let head = sorted.first, let repo = workspaceRepo(for: head) {
            aiSummariesEnabled = workspaceControls.isAISummaryEnabled(
                repo,
                globalAISummaryEnabled: DeepSeekClient.apiKeyFromEnvironment() != nil
            )
        } else {
            aiSummariesEnabled = false
        }
        projection = AttentionQueueProjection.make(
            store: store,
            ambient: ambient,
            now: currentNow,
            aiSummariesEnabled: aiSummariesEnabled,
            ambientAvailability: ambientAvailability
        )
    }

    // MARK: - workspace 解析与 mute 映射

    /// request → 所在 workspace repo 名：TraeX session 的 cwd 对照最近 Orca 快照
    /// 的 worktree path；supervised workflow 无 CLI 关联数据，解析不出（不参与 mute）。
    private func workspaceRepo(for request: AttentionRequest) -> String? {
        guard case let .traeX(sessionID) = request.sessionKey,
              let cwd = traeXSessionCWDMappings[sessionID]
        else { return nil }
        return latestOrcaSnapshot?.worktrees.first { $0.path == cwd }?.repo
    }

    /// 能解析出 repo 且该 repo 被静音的 session keys（升级抑制输入）。
    private var mutedSessionKeys: Set<AgentSessionKey> {
        var keys = Set<AgentSessionKey>()
        for request in store.activeRequests {
            if let repo = workspaceRepo(for: request), workspaceControls.isMuted(repo) {
                keys.insert(request.sessionKey)
            }
        }
        return keys
    }

    // MARK: - 持久化

    private func persist() {
        let payload = AttentionQueueRuntimePayload(
            snapshot: store.snapshot(now: now()),
            seenTraeXSessionIDs: seenTraeXSessionIDs.sorted(),
            traeXSessionCWDMappings: traeXSessionCWDMappings
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: Self.runtimeStorageKey)
        }
    }

    private func persistControls() {
        let snapshot = AttentionQueueControlsSnapshot(
            notificationsEnabled: notificationsEnabled,
            workspaceControls: workspaceControls
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.controlsStorageKey)
        }
    }

    static func escalationKindLabel(_ kind: AttentionRequestKind) -> String {
        switch kind {
        case .permissionRequired: "Permission required"
        case .userAnswerRequired: "Answer required"
        case .userActionRequired: "Action required"
        case .reviewRequired: "Review required"
        case .stateNeedsConfirmation: "State needs confirmation"
        }
    }
}
