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
    public var sessionSummaries: [String: SessionSummaryCacheEntry]

    public init(
        snapshot: AttentionRequestPersistenceSnapshot,
        seenTraeXSessionIDs: [String],
        traeXSessionCWDMappings: [String: String],
        sessionSummaries: [String: SessionSummaryCacheEntry] = [:]
    ) {
        self.snapshot = snapshot
        self.seenTraeXSessionIDs = seenTraeXSessionIDs
        self.traeXSessionCWDMappings = traeXSessionCWDMappings
        self.sessionSummaries = sessionSummaries
    }

    private enum CodingKeys: String, CodingKey {
        case snapshot
        case seenTraeXSessionIDs
        case traeXSessionCWDMappings
        case sessionSummaries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decode(AttentionRequestPersistenceSnapshot.self, forKey: .snapshot)
        seenTraeXSessionIDs = try container.decode([String].self, forKey: .seenTraeXSessionIDs)
        traeXSessionCWDMappings = try container.decode([String: String].self, forKey: .traeXSessionCWDMappings)
        sessionSummaries = try container.decodeIfPresent(
            [String: SessionSummaryCacheEntry].self,
            forKey: .sessionSummaries
        ) ?? [:]
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

public enum SummaryProviderFactory {
    public static func deepSeekFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any SummaryProviding)? {
        guard let key = DeepSeekClient.apiKeyFromEnvironment(env) else { return nil }
        return DeepSeekClient(apiKey: key)
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
    private let summaryProvider: (any SummaryProviding)?
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
    private var latestOrcaAmbient = AmbientOverview(entries: [])
    private var sessionSummaryCache: [String: SessionSummaryCacheEntry] = [:]
    private var traeXOverviewEntries: [String: AmbientOverviewEntry] = [:]
    private var summaryTasks: [String: Task<SessionOverviewDisplay, Never>] = [:]
    private var latestOrcaPollGeneration: UInt64 = 0
    private let summaryConcurrencyLimit = 3
    private var activeSummaryCount = 0
    private var summaryWaiters: [CheckedContinuation<Void, Never>] = []

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
        summaryProvider: (any SummaryProviding)? = SummaryProviderFactory.deepSeekFromEnvironment(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.orca = orca
        self.jumper = jumper
        self.defaults = defaults
        self.summaryProvider = summaryProvider
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
            self.sessionSummaryCache = payload.sessionSummaries
        } else {
            self.store = AttentionRequestStore()
            self.seenTraeXSessionIDs = []
            self.traeXSessionCWDMappings = [:]
            self.sessionSummaryCache = [:]
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
        let sessionIsKnown = sessionID.map(isKnownTraeXSessionID) ?? false
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
            updateTraeXOverview(event, sessionID: sessionID, observedAt: observedAt)
            ambient = combinedOverview(applyCachedSummaries(to: latestOrcaAmbient))
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
        let overview = applyCachedSummaries(to: result.ambient)
        latestOrcaAmbient = overview
        pruneSessionSummaryCache(liveOrcaKeys: Set(overview.entries.compactMap(\.summaryCacheKey)))
        ambient = combinedOverview(overview)
        latestOrcaSnapshot = snapshot
        ambientAvailability = .available
        recomputeProjection()
    }

    /// 一次 Orca 采集：成功更新 ambient；失败标记 unavailable（不崩溃）。
    public func pollOrcaOnce() async {
        do {
            let snapshot = try await orca.fetchSnapshot()
            await applyOrcaSnapshotWithSummaries(snapshot)
        } catch {
            ambientAvailability = .unavailable
            latestOrcaAmbient = AmbientOverview(entries: [])
            ambient = combinedOverview(latestOrcaAmbient)
            recomputeProjection()
        }
    }

    private func applyOrcaSnapshotWithSummaries(_ snapshot: FocusResolver.Snapshot) async {
        latestOrcaPollGeneration &+= 1
        let generation = latestOrcaPollGeneration
        let result = OrcaAttentionAdapter.adapt(
            snapshot: snapshot,
            supervisedSignals: [],
            observedAt: now()
        )
        var overview = applyCachedSummaries(to: result.ambient)
        guard generation == latestOrcaPollGeneration else { return }
        latestOrcaAmbient = overview
        ambient = combinedOverview(overview)
        latestOrcaSnapshot = snapshot
        ambientAvailability = .available
        recomputeProjection()
        if summaryProvider != nil {
            await withTaskGroup(of: (Int, SessionOverviewDisplay?).self) { group in
                for index in overview.entries.indices {
                    let entry = overview.entries[index]
                    guard shouldStartSummary(for: entry) else { continue }
                    overview.entries[index].isSummaryLoading = true
                    group.addTask { [weak self] in
                        guard let self else { return (index, nil) }
                        return (index, await self.summaryDisplay(for: entry))
                    }
                }
                if !group.isEmpty {
                    latestOrcaAmbient = overview
                    ambient = combinedOverview(overview)
                    recomputeProjection()
                }
                for await (index, display) in group {
                    overview.entries[index].isSummaryLoading = false
                    guard let display,
                          summaryResultIsCurrent(
                            for: overview.entries[index],
                            in: latestOrcaAmbient
                          )
                    else { continue }
                    if display.sourceConfidence == "AI summary · whitelisted structured agent payload",
                       let cacheKey = overview.entries[index].summaryCacheKey,
                       let fingerprint = overview.entries[index].session.summaryFingerprint {
                        sessionSummaryCache[cacheKey] = SessionSummaryCacheEntry(
                            fingerprint: fingerprint,
                            display: display
                        )
                    }
                    overview.entries[index].session = display
                }
            }
        }
        guard generation == latestOrcaPollGeneration else { return }
        latestOrcaAmbient = overview
        pruneSessionSummaryCache(liveOrcaKeys: Set(overview.entries.compactMap(\.summaryCacheKey)))
        ambient = combinedOverview(overview)
        latestOrcaSnapshot = snapshot
        ambientAvailability = .available
        recomputeProjection()
        persist()
    }

    private func applyCachedSummaries(to overview: AmbientOverview) -> AmbientOverview {
        AmbientOverview(entries: overview.entries.map { entry in
            var copy = entry
            if let key = entry.summaryCacheKey,
               shouldUseAISummary(for: entry),
               let cached = sessionSummaryCache[key],
               cached.fingerprint == entry.session.summaryFingerprint {
                copy.session = cached.display
            }
            return copy
        })
    }

    private func shouldUseAISummary(for entry: AmbientOverviewEntry) -> Bool {
        guard summaryProvider != nil,
              entry.coverage == .structuredAgent,
              let repo = entry.repository
        else { return false }
        return workspaceControls.isAISummaryEnabled(repo, globalAISummaryEnabled: true)
    }

    private func shouldStartSummary(for entry: AmbientOverviewEntry) -> Bool {
        guard shouldUseAISummary(for: entry),
              let cacheKey = entry.summaryCacheKey,
              let fingerprint = entry.session.summaryFingerprint,
              sessionSummaryCache[cacheKey]?.fingerprint != fingerprint
        else { return false }
        return true
    }

    private func summaryDisplay(for entry: AmbientOverviewEntry) async -> SessionOverviewDisplay? {
        guard let provider = summaryProvider,
              let cacheKey = entry.summaryCacheKey,
              let fingerprint = entry.session.summaryFingerprint,
              let context = entry.summaryContext
        else { return nil }
        let taskKey = "\(cacheKey):\(fingerprint)"
        let task: Task<SessionOverviewDisplay, Never>
        if let existing = summaryTasks[taskKey] {
            task = existing
        } else {
            task = Task {
                await self.acquireSummaryPermit()
                defer { Task { @MainActor in self.releaseSummaryPermit() } }
                return await Self.makeSummaryDisplay(
                    context: context,
                    provider: provider,
                    fallback: entry.session
                )
            }
            summaryTasks[taskKey] = task
        }
        let display = await task.value
        summaryTasks[taskKey] = nil
        guard workspaceControls.isAISummaryEnabled(
            entry.repository ?? "",
            globalAISummaryEnabled: true
        ) else { return nil }
        return display
    }

    private func acquireSummaryPermit() async {
        if activeSummaryCount < summaryConcurrencyLimit {
            activeSummaryCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            summaryWaiters.append(continuation)
        }
    }

    private func releaseSummaryPermit() {
        if summaryWaiters.isEmpty {
            activeSummaryCount -= 1
        } else {
            summaryWaiters.removeFirst().resume()
        }
    }

    private func summaryResultIsCurrent(
        for entry: AmbientOverviewEntry,
        in latestOverview: AmbientOverview
    ) -> Bool {
        guard shouldUseAISummary(for: entry),
              let cacheKey = entry.summaryCacheKey,
              let fingerprint = entry.session.summaryFingerprint,
              let latest = latestOverview.entries.first(where: { $0.summaryCacheKey == cacheKey })
        else { return false }
        return entry.summaryCacheKey == cacheKey
            && latest.session.summaryFingerprint == fingerprint
    }

    private func summarizeSession(
        context: SummaryContext,
        provider: any SummaryProviding,
        fallback: SessionOverviewDisplay
    ) async -> SessionOverviewDisplay {
        await Self.makeSummaryDisplay(context: context, provider: provider, fallback: fallback)
    }

    nonisolated private static func makeSummaryDisplay(
        context: SummaryContext,
        provider: any SummaryProviding,
        fallback: SessionOverviewDisplay
    ) async -> SessionOverviewDisplay {
        do {
            let summary = try await provider.summarize(context: context)
            return SessionOverviewDisplay(
                currentTask: safeSummaryField(summary.currentTask, fallback: fallback.currentTask),
                progress: safeSummaryField(summary.progress, fallback: fallback.progress),
                nextStep: safeSummaryField(summary.nextStep, fallback: fallback.nextStep),
                needsInput: safeSummaryField(summary.needsInput, fallback: fallback.needsInput),
                sourceConfidence: "AI summary · whitelisted structured agent payload",
                updatedAt: fallback.updatedAt,
                summaryFingerprint: fallback.summaryFingerprint
            )
        } catch {
            var display = fallback
            display.sourceConfidence = "structured agent · deterministic local fallback · AI unavailable"
            return display
        }
    }

    nonisolated private static func safeSummaryField(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "未知",
              trimmed.count <= AISummaryPolicy.maxDisplayCharacters
        else { return fallback }
        return trimmed
    }

    private func updateTraeXOverview(_ event: TraeXEvent, sessionID: String, observedAt: Date) {
        switch event.hookEventName {
        case TraeXEvent.userPromptSubmit:
            guard let repo = workspaceRepo(forCWD: event.cwd) else { return }
            traeXOverviewEntries[sessionID] = makeTraeXEntry(
                sessionID: sessionID,
                repo: repo,
                cwd: event.cwd,
                activity: .busy,
                session: SessionOverviewDisplay(
                    currentTask: "TraeX task submitted",
                    progress: "Processing structured prompt.",
                    nextStep: "Waiting for Stop.last_assistant_message.",
                    needsInput: "无",
                    sourceConfidence: "TraeX structured hook · deterministic local fallback · AI disabled",
                    updatedAt: observedAt,
                    summaryFingerprint: nil
                ),
                observedAt: observedAt
            )
            pruneTraeXOverviewEntries()
        case TraeXEvent.stop:
            guard let message = event.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !message.isEmpty,
                  let repo = workspaceRepo(forCWD: event.cwd)
            else { return }
            let fingerprint = Self.stableFingerprint(message)
            let fallback = SessionOverviewDisplay(
                currentTask: "TraeX completed response",
                progress: "Received complete structured reply.",
                nextStep: "Review the latest TraeX response if needed.",
                needsInput: "Unknown · not request",
                sourceConfidence: summaryProvider == nil
                    ? "TraeX structured hook · deterministic local fallback · AI disabled"
                    : "TraeX structured hook · deterministic local fallback · AI unavailable",
                updatedAt: observedAt,
                summaryFingerprint: fingerprint
            )
            let cacheKey = Self.safeSessionCacheKey(source: "traex", identity: sessionID)
            let context = AISummaryPolicy.makeSessionOverviewContext(
                repo: repo,
                branch: nil,
                state: "complete",
                taskLabel: "TraeX completed response",
                toolName: nil,
                assistantReply: message
            )
            var entry = makeTraeXEntry(
                sessionID: sessionID,
                repo: repo,
                cwd: event.cwd,
                activity: .idle,
                session: fallback,
                observedAt: observedAt,
                summaryCacheKey: cacheKey,
                summaryContext: context
            )
            if shouldUseAISummary(for: entry),
               let cached = sessionSummaryCache[cacheKey],
               cached.fingerprint == fingerprint {
                entry.session = cached.display
            }
            traeXOverviewEntries[sessionID] = entry
            pruneTraeXOverviewEntries()
            if shouldUseAISummary(for: entry), let provider = summaryProvider {
                Task { @MainActor in
                    await summarizeTraeXSession(
                        sessionID: sessionID,
                        cacheKey: cacheKey,
                        fingerprint: fingerprint,
                        context: context,
                        provider: provider,
                        fallback: fallback
                    )
                }
            }
        case TraeXEvent.sessionEnd:
            traeXOverviewEntries[sessionID] = nil
            pruneSessionSummaryCache(liveOrcaKeys: Set(latestOrcaAmbient.entries.compactMap(\.summaryCacheKey)))
        default:
            break
        }
    }

    private func summarizeTraeXSession(
        sessionID: String,
        cacheKey: String,
        fingerprint: String,
        context: SummaryContext,
        provider: any SummaryProviding,
        fallback: SessionOverviewDisplay
    ) async {
        let taskKey = "\(cacheKey):\(fingerprint)"
        guard sessionSummaryCache[cacheKey]?.fingerprint != fingerprint else { return }
        let task: Task<SessionOverviewDisplay, Never>
        if let existing = summaryTasks[taskKey] {
            task = existing
        } else {
            task = Task {
                await self.acquireSummaryPermit()
                defer { Task { @MainActor in self.releaseSummaryPermit() } }
                return await Self.makeSummaryDisplay(context: context, provider: provider, fallback: fallback)
            }
            summaryTasks[taskKey] = task
        }
        if var entry = traeXOverviewEntries[sessionID] {
            entry.isSummaryLoading = true
            traeXOverviewEntries[sessionID] = entry
            ambient = combinedOverview(applyCachedSummaries(to: latestOrcaAmbient))
            recomputeProjection()
        }
        let display = await task.value
        summaryTasks[taskKey] = nil
        guard shouldUseAISummaryForTraeX(sessionID: sessionID, cacheKey: cacheKey, fingerprint: fingerprint) else {
            ambient = combinedOverview(applyCachedSummaries(to: latestOrcaAmbient))
            recomputeProjection()
            return
        }
        guard display.sourceConfidence == "AI summary · whitelisted structured agent payload" else {
            if var entry = traeXOverviewEntries[sessionID] {
                entry.isSummaryLoading = false
                entry.session = display
                traeXOverviewEntries[sessionID] = entry
                ambient = combinedOverview(applyCachedSummaries(to: latestOrcaAmbient))
                recomputeProjection()
            }
            return
        }
        sessionSummaryCache[cacheKey] = SessionSummaryCacheEntry(fingerprint: fingerprint, display: display)
        if var entry = traeXOverviewEntries[sessionID] {
            entry.session = display
            entry.isSummaryLoading = false
            traeXOverviewEntries[sessionID] = entry
        }
        ambient = combinedOverview(applyCachedSummaries(to: latestOrcaAmbient))
        recomputeProjection()
        persist()
    }

    private func shouldUseAISummaryForTraeX(
        sessionID: String,
        cacheKey: String,
        fingerprint: String
    ) -> Bool {
        guard let entry = traeXOverviewEntries[sessionID],
              entry.summaryCacheKey == cacheKey,
              entry.session.summaryFingerprint == fingerprint
        else { return false }
        return shouldUseAISummary(for: entry)
    }

    private func makeTraeXEntry(
        sessionID: String,
        repo: String,
        cwd: String?,
        activity: TerminalActivityStatus,
        session: SessionOverviewDisplay,
        observedAt: Date,
        summaryCacheKey: String? = nil,
        summaryContext: SummaryContext? = nil
    ) -> AmbientOverviewEntry {
        AmbientOverviewEntry(
            terminalHandle: "traex-\(Self.stableFingerprint(sessionID))",
            worktreeID: cwd.map { "traex-\(Self.stableFingerprint($0))" },
            repository: repo,
            branch: "TraeX",
            title: nil,
            connected: true,
            lastOutputAt: observedAt,
            isFocused: false,
            activity: activity,
            coverage: .structuredAgent,
            session: session,
            summaryCacheKey: summaryCacheKey,
            summaryContext: summaryContext
        )
    }

    private func combinedOverview(_ orcaOverview: AmbientOverview) -> AmbientOverview {
        AmbientOverview(entries: orcaOverview.entries + traeXOverviewEntries.values)
    }

    private func pruneTraeXOverviewEntries() {
        let maxEntries = 25
        guard traeXOverviewEntries.count > maxEntries else { return }
        let retainedSessionIDs = Set(
            traeXOverviewEntries
                .sorted { lhs, rhs in
                    let left = lhs.value.session.updatedAt ?? .distantPast
                    let right = rhs.value.session.updatedAt ?? .distantPast
                    if left != right { return left > right }
                    return lhs.key < rhs.key
                }
                .prefix(maxEntries)
                .map(\.key)
        )
        traeXOverviewEntries = traeXOverviewEntries.filter { retainedSessionIDs.contains($0.key) }
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
        if !enabled {
            sessionSummaryCache = sessionSummaryCache.filter { _, entry in
                entry.display.sourceConfidence != "AI summary · whitelisted structured agent payload"
            }
            latestOrcaAmbient = OrcaAttentionAdapter.adapt(
                snapshot: latestOrcaSnapshot ?? FocusResolver.Snapshot(worktrees: [], terminals: [], layouts: []),
                supervisedSignals: [],
                observedAt: now()
            ).ambient
            for sessionID in traeXOverviewEntries.keys {
                guard var entry = traeXOverviewEntries[sessionID], entry.repository == workspaceID else { continue }
                entry.isSummaryLoading = false
                if entry.session.sourceConfidence == "AI summary · whitelisted structured agent payload" {
                    entry.session.currentTask = "TraeX completed response"
                    entry.session.progress = "Received complete structured reply."
                    entry.session.nextStep = "Review the latest TraeX response if needed."
                    entry.session.needsInput = "Unknown · not request"
                    entry.session.sourceConfidence = "TraeX structured hook · deterministic local fallback · AI disabled"
                }
                traeXOverviewEntries[sessionID] = entry
            }
            ambient = combinedOverview(latestOrcaAmbient)
        }
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
            ambientAvailability: ambientAvailability,
            workspaceControls: workspaceControls,
            aiSummaryProviderAvailable: summaryProvider != nil
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

    private func workspaceRepo(forCWD cwd: String?) -> String? {
        guard let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else {
            return nil
        }
        if let repo = latestOrcaSnapshot?.worktrees.first(where: { $0.path == cwd })?.repo {
            return repo
        }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func isKnownTraeXSessionID(_ sessionID: String) -> Bool {
        seenTraeXSessionIDs.contains(sessionID) || traeXSessionCWDMappings[sessionID] != nil
    }

    private func pruneSessionSummaryCache(liveOrcaKeys: Set<String>) {
        let liveTraeXKeys = Set(traeXOverviewEntries.keys.map {
            Self.safeSessionCacheKey(source: "traex", identity: $0)
        })
        sessionSummaryCache = sessionSummaryCache.filter { key, _ in
            if key.hasPrefix("orca:") {
                return liveOrcaKeys.contains(key)
            }
            if key.hasPrefix("traex:") {
                return liveTraeXKeys.contains(key)
            }
            return false
        }
        let maxTraeXCacheEntries = 25
        let traeXKeys = sessionSummaryCache.keys.filter { $0.hasPrefix("traex:") }
        guard traeXKeys.count > maxTraeXCacheEntries else { return }
        let newestKeys = Set(
            traeXKeys.sorted { lhs, rhs in
                (sessionSummaryCache[lhs]?.display.updatedAt ?? .distantPast) >
                    (sessionSummaryCache[rhs]?.display.updatedAt ?? .distantPast)
            }
            .prefix(maxTraeXCacheEntries)
        )
        sessionSummaryCache = sessionSummaryCache.filter { key, _ in
            !key.hasPrefix("traex:") || newestKeys.contains(key)
        }
    }

    nonisolated static func safeSessionCacheKey(source: String, identity: String) -> String {
        "\(source):\(stableFingerprint(identity))"
    }

    nonisolated static func stableFingerprint(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
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
            seenTraeXSessionIDs: persistentSeenTraeXSessionIDs().sorted(),
            traeXSessionCWDMappings: persistentTraeXSessionCWDMappings(),
            sessionSummaries: sessionSummaryCache
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

    private func persistentTraeXSessionCWDMappings() -> [String: String] {
        let requestSessionIDs = persistentRequestSessionIDs()
        return traeXSessionCWDMappings.filter { sessionID, _ in
            requestSessionIDs.contains(sessionID)
        }
    }

    private func persistentSeenTraeXSessionIDs() -> Set<String> {
        seenTraeXSessionIDs.intersection(persistentRequestSessionIDs())
    }

    private func persistentRequestSessionIDs() -> Set<String> {
        let snapshot = store.snapshot(now: now())
        return Set((snapshot.activeRequests + snapshot.closedHistory).compactMap { request -> String? in
            if case let .traeX(sessionID) = request.sessionKey {
                return sessionID
            }
            return nil
        })
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
