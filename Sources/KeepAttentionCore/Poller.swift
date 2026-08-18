import Foundation
import Observation

/// 应用视图模型：一次 tick = 采集 Orca hook → 结构化结果去重 → 总结 → 发布。
@MainActor
@Observable
public final class AppModel {
    public struct TerminalDisplay: Identifiable, Equatable, Sendable {
        public let id: String
        public let handle: String
        public let repo: String
        public let branch: String?
        public let title: String?
        public var status: TerminalActivityStatus
        public var summary: SummaryState
        public var lastOutputAt: Date?
        public var updatedAt: Date?

        public init(id: String, handle: String, repo: String, branch: String?, title: String?, status: TerminalActivityStatus, summary: SummaryState, lastOutputAt: Date?, updatedAt: Date?) {
            self.id = id
            self.handle = handle
            self.repo = repo
            self.branch = branch
            self.title = title
            self.status = status
            self.summary = summary
            self.lastOutputAt = lastOutputAt
            self.updatedAt = updatedAt
        }
    }

    static let pollIntervalKey = "pollIntervalSeconds"
    static let defaultPollInterval: Double = 5
    public private(set) var displays: [TerminalDisplay] = []
    public private(set) var focusedHandle: String?
    public private(set) var orcaError: String?

    /// 轮询间隔（秒），持久化到 UserDefaults（spec §4 设置，硬需求）。
    public var pollInterval: Double {
        didSet {
            guard oldValue != pollInterval else { return }
            pollInterval = min(max(pollInterval, 1), 600)
            defaults.set(pollInterval, forKey: Self.pollIntervalKey)
            onPollIntervalChanged?()
        }
    }

    private(set) var orca: OrcaClient
    private let summarizer: SummaryProviding
    private let defaults: DefaultsStoring
    private let onPollIntervalChanged: (@MainActor () -> Void)?

    /// handle → 结构化 agent result 指纹（去重键）
    private var fingerprints: [String: String] = [:]
    /// handle → 缓存摘要（指纹未变时复用，不重复烧 API）
    private var summaries: [String: TerminalSummary] = [:]
    private var isTicking = false
    /// cwd → TraeX hook 会话状态（TraeX 是 Orca agents[] 之外的结构化输入源）
    private var traexStates: [String: TraeXSessionState] = [:]

    /// TraeX hook 会话状态：working 表示当前请求处理中，lastAssistantMessage 是最近完整回复。
    private struct TraeXSessionState {
        var prompt: String?
        var working: Bool
        var lastAssistantMessage: String?
    }

    public init(
        orca: OrcaClient,
        summarizer: SummaryProviding,
        defaults: DefaultsStoring = UserDefaults.standard,
        onPollIntervalChanged: (@MainActor () -> Void)? = nil
    ) {
        self.orca = orca
        self.summarizer = summarizer
        self.defaults = defaults
        self.onPollIntervalChanged = onPollIntervalChanged
        let stored = defaults.double(forKey: Self.pollIntervalKey)
        self.pollInterval = stored > 0 ? stored : Self.defaultPollInterval
    }

    /// 测试用：替换数据源。
    func setOrcaForTesting(_ orca: OrcaClient) {
        self.orca = orca
    }

    // MARK: - TraeX hook 事件（新结构化输入源，Orca agents[] 行为保持优先）

    /// 接收 TraeX hook 事件并立即重算显示。
    /// UserPromptSubmit → 显示正在处理当前请求；Stop → last_assistant_message 走既有总结/去重管线。
    public func applyTraeXEvent(_ event: TraeXEvent) async {
        guard event.isSupported, let cwd = event.cwd, !cwd.isEmpty else { return }
        var state = traexStates[cwd] ?? TraeXSessionState(prompt: nil, working: false, lastAssistantMessage: nil)
        switch event.hookEventName {
        case TraeXEvent.userPromptSubmit:
            state.prompt = Self.trimmedStatic(event.prompt)
            state.working = true
        case TraeXEvent.stop:
            state.working = false
            if let message = Self.trimmedStatic(event.lastAssistantMessage), !message.isEmpty {
                state.lastAssistantMessage = message
            }
        default:
            return
        }
        traexStates[cwd] = state
        await tick()
    }

    // MARK: - 派生视图状态

    /// 最紧急的等待终端（lastOutputAt 最久未更新者，spec §4 抢显）。
    public var mostUrgentWaiting: TerminalDisplay? {
        displays
            .filter { $0.status == .waitingForInput }
            .min { ($0.lastOutputAt ?? .distantPast) < ($1.lastOutputAt ?? .distantPast) }
    }

    public var waitingCount: Int {
        displays.filter { $0.status == .waitingForInput }.count
    }

    /// 药丸默认展示：抢显等待终端 > 已有结构化结果的终端 > 焦点终端 > 任意终端。
    public var pillDisplay: TerminalDisplay? {
        mostUrgentWaiting
            ?? displays.first { $0.summary.hasStructuredResult }
            ?? displays.first { $0.handle == focusedHandle }
            ?? displays.first
    }

    // MARK: - attention 排序与聚合（issue #12）

    /// attention 排序优先级：等待输入(0) > 有结构化结果(1) > 普通 busy(2) > idle/无输出(3)。
    static func attentionRank(_ display: TerminalDisplay) -> Int {
        if display.status == .waitingForInput { return 0 }
        if display.summary.hasStructuredResult { return 1 }
        if display.status == .busy { return 2 }
        return 3
    }

    /// 按 attention 优先级排序的终端列表；同组内保持 displays 原序，避免 UI 抖动。
    public var attentionDisplays: [TerminalDisplay] {
        Self.sortByAttentionPreservingOriginalOrder(displays)
    }

    static func sortByAttentionPreservingOriginalOrder(_ displays: [TerminalDisplay]) -> [TerminalDisplay] {
        displays.enumerated()
            .sorted { lhs, rhs in
                let leftRank = Self.attentionRank(lhs.element)
                let rightRank = Self.attentionRank(rhs.element)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// live terminal 总数（collapsed pill 聚合徽标，issue #12）。
    public var totalTerminalCount: Int {
        displays.count
    }

    // MARK: - 详情选择（issue #13）

    /// 展开面板详情目标：用户点击的 handle 命中则保持选择；未选择或 terminal 消失时回退 fallback。
    /// 纯查询，不触发任何总结调用。
    public static func resolveDetailDisplay(
        selectedHandle: String?,
        displays: [TerminalDisplay],
        fallback: TerminalDisplay?
    ) -> TerminalDisplay? {
        guard let selectedHandle else { return fallback }
        return displays.first { $0.handle == selectedHandle } ?? fallback
    }

    /// 值得注意的终端数：等待输入或有结构化结果。
    public var attentionCount: Int {
        displays.filter { Self.attentionRank($0) <= 1 }.count
    }

    // MARK: - 跳转到终端（issue #15）

    /// 跳转专用的轻量错误文案；独立于 orcaError（后者只反映采集通道状态）。
    public private(set) var jumpError: String?

    /// 调 `orca terminal switch` 切回对应终端；成功清空错误，失败设置轻量文案，不崩溃。
    public func jumpToTerminal(handle: String) async {
        do {
            try await orca.terminalSwitch(handle: handle)
            jumpError = nil
        } catch {
            jumpError = "跳转失败，稍后重试"
        }
    }

    // MARK: - 一次采集

    public func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        do {
            async let ps = orca.worktreePS()
            async let list = orca.terminalList()
            let (psResult, listResult) = try await (ps, list)
            orcaError = nil
            await process(ps: psResult, list: listResult)
        } catch {
            orcaError = Self.describe(error)
            displays = []
        }
    }

    private struct AgentBinding {
        let worktreeId: String
        let agent: AgentInfo
    }

    private static let workingAgentStates: Set<String> = [
        "working", "running", "thinking", "streaming", "in_progress", "in-progress", "busy",
    ]

    private func process(ps: WorktreePSResult, list: TerminalListResult) async {
        let worktreeById = Dictionary(ps.worktrees.map { ($0.worktreeId, $0) },
                                      uniquingKeysWith: { a, _ in a })
        let resolver = FocusResolver(snapshot: .init(
            worktrees: ps.worktrees,
            terminals: list.terminals,
            layouts: list.visualLayouts
        ))
        let focus = resolver.focusedHandle()
        focusedHandle = focus

        let agentByPaneKey = Dictionary(
            ps.worktrees.flatMap { w in
                (w.agents ?? []).compactMap { agent -> (String, AgentBinding)? in
                    guard let paneKey = agent.paneKey, !paneKey.isEmpty else { return nil }
                    return (Self.agentLookupKey(worktreeId: w.worktreeId, paneKey: paneKey), AgentBinding(worktreeId: w.worktreeId, agent: agent))
                }
            },
            uniquingKeysWith: { a, _ in a }
        )

        let now = Date()
        let traexByHandle = traexTargets(ps: ps, list: list, focus: focus, agentByPaneKey: agentByPaneKey)
        displays = list.terminals.map { t in
            let w = t.worktreeId.flatMap { worktreeById[$0] }
            let agent = matchedAgent(for: t, in: agentByPaneKey)?.agent
            let status = StatusResolver.resolve(StatusInput(
                agentStates: agent.flatMap { [$0.state].compactMap { $0 } } ?? [],
                worktreeStatus: w?.status,
                lastOutputAt: t.lastOutputDate,
                tail: nil,
                now: now
            ))
            return TerminalDisplay(
                id: t.handle,
                handle: t.handle,
                repo: w?.repo ?? "未知",
                branch: t.shortBranch ?? w?.shortBranch,
                title: t.title,
                status: status,
                summary: initialSummary(for: t, agent: agent, traex: traexByHandle[t.handle]),
                lastOutputAt: t.lastOutputDate,
                updatedAt: nil
            )
        }

        for t in list.terminals {
            guard let binding = matchedAgent(for: t, in: agentByPaneKey),
                  let idx = displays.firstIndex(where: { $0.handle == t.handle })
            else { continue }
            let agent = binding.agent
            guard !Self.isWorking(agent.state),
                  let message = trimmed(agent.lastAssistantMessage),
                  !message.isEmpty
            else { continue }

            let fingerprint = contentFingerprint([binding.worktreeId, agent.paneKey ?? "", message])
            if fingerprint == fingerprints[t.handle], let cached = summaries[t.handle] {
                displays[idx].summary = .ready(cached)
                continue
            }

            displays[idx].summary = .loading
            let context = SummaryContext(
                repo: displays[idx].repo,
                branch: displays[idx].branch,
                title: displays[idx].title,
                agentMessage: Self.summaryMessage(for: agent, message: message),
                tail: []
            )
            do {
                let summary = try await summarizer.summarize(context: context)
                fingerprints[t.handle] = fingerprint
                summaries[t.handle] = summary
                displays[idx].summary = .ready(summary)
                displays[idx].updatedAt = Date()
            } catch {
                displays[idx].summary = .failed(Self.describeSummaryError(error))
                displays[idx].updatedAt = Date()
            }
        }

        // TraeX hook 源：Stop 的 last_assistant_message 走与 Orca 相同的总结/去重管线。
        for (handle, state) in traexByHandle {
            guard let idx = displays.firstIndex(where: { $0.handle == handle }),
                  !state.working,
                  let message = state.lastAssistantMessage,
                  !message.isEmpty
            else { continue }

            let fingerprint = contentFingerprint(["traex", handle, message])
            if fingerprint == fingerprints[handle], let cached = summaries[handle] {
                displays[idx].summary = .ready(cached)
                continue
            }

            displays[idx].summary = .loading
            let context = SummaryContext(
                repo: displays[idx].repo,
                branch: displays[idx].branch,
                title: displays[idx].title,
                agentMessage: Self.traexSummaryMessage(prompt: state.prompt, message: message),
                tail: []
            )
            do {
                let summary = try await summarizer.summarize(context: context)
                fingerprints[handle] = fingerprint
                summaries[handle] = summary
                displays[idx].summary = .ready(summary)
                displays[idx].updatedAt = Date()
            } catch {
                displays[idx].summary = .failed(Self.describeSummaryError(error))
                displays[idx].updatedAt = Date()
            }
        }
    }

    private func matchedAgent(for terminal: TerminalInfo, in agentByPaneKey: [String: AgentBinding]) -> AgentBinding? {
        guard let worktreeId = terminal.worktreeId,
              let tabId = terminal.tabId,
              let leafId = terminal.leafId
        else { return nil }
        return agentByPaneKey[Self.agentLookupKey(worktreeId: worktreeId, paneKey: "\(tabId):\(leafId)")]
    }

    /// cwd → 焦点（否则首个）terminal 的映射；该 terminal 已有 orca agent 匹配时丢弃（Orca 优先）。
    private func traexTargets(
        ps: WorktreePSResult,
        list: TerminalListResult,
        focus: String?,
        agentByPaneKey: [String: AgentBinding]
    ) -> [String: TraeXSessionState] {
        var targets: [String: TraeXSessionState] = [:]
        for (cwd, state) in traexStates {
            let worktreeIds = Set(ps.worktrees.filter { $0.path == cwd }.map(\.worktreeId))
            let candidates = list.terminals.filter { t in
                t.worktreePath == cwd || (t.worktreeId.map(worktreeIds.contains) ?? false)
            }
            guard let target = candidates.first(where: { $0.handle == focus }) ?? candidates.first else { continue }
            guard matchedAgent(for: target, in: agentByPaneKey) == nil else { continue }
            targets[target.handle] = state
        }
        return targets
    }

    private func initialSummary(for terminal: TerminalInfo, agent: AgentInfo?, traex: TraeXSessionState?) -> SummaryState {
        if let agent {
            guard let message = trimmed(agent.lastAssistantMessage), !message.isEmpty else {
                if Self.isWorking(agent.state) { return .unavailable("Agent 正在执行，等待下一条完整回复") }
                return .unavailable("暂无结构化 agent 输出")
            }
            let fingerprint = contentFingerprint([terminal.worktreeId ?? "", agent.paneKey ?? "", message])
            if fingerprint == fingerprints[terminal.handle], let cached = summaries[terminal.handle] {
                return .ready(cached)
            }
            if Self.isWorking(agent.state) { return .unavailable("Agent 正在执行，等待下一条完整回复") }
            return .loading
        }
        // TraeX hook 源：仅当该 terminal 没有 orca agent 匹配时接管显示。
        if let traex {
            if traex.working { return .unavailable("TraeX 正在处理当前请求…") }
            if let message = traex.lastAssistantMessage, !message.isEmpty {
                let fingerprint = contentFingerprint(["traex", terminal.handle, message])
                if fingerprint == fingerprints[terminal.handle], let cached = summaries[terminal.handle] {
                    return .ready(cached)
                }
                return .loading
            }
        }
        return .unavailable("未检测到结构化 agent 输出")
    }

    private static func summaryMessage(for agent: AgentInfo, message: String) -> String {
        let request = trimmedStatic(agent.taskTitle) ?? trimmedStatic(agent.prompt)
        guard let request, !request.isEmpty else { return message }
        return """
        用户请求：\(request)

        Agent 回复：
        \(message)
        """
    }

    private static func traexSummaryMessage(prompt: String?, message: String) -> String {
        guard let prompt, !prompt.isEmpty else { return message }
        return """
        用户请求：\(prompt)

        Agent 回复：
        \(message)
        """
    }

    private static func agentLookupKey(worktreeId: String, paneKey: String) -> String {
        "\(worktreeId)|\(paneKey)"
    }

    private static func isWorking(_ state: String?) -> Bool {
        guard let state else { return false }
        return workingAgentStates.contains(state.lowercased())
    }

    private static func trimmedStatic(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmed(_ text: String?) -> String? {
        Self.trimmedStatic(text)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case OrcaError.missingBinary(let path):
            return "orca CLI 不可用（\(path)）"
        case OrcaError.exit(let code):
            return "orca 命令失败（exit \(code)）"
        case OrcaError.emptyOutput:
            return "orca 输出解析失败"
        default:
            return "采集失败：\(error.localizedDescription)"
        }
    }

    static func describeSummaryError(_ error: Error) -> String {
        if case DeepSeekError.missingAPIKey = error { return "未配置 API Key" }
        return "总结失败，稍后重试"
    }
}

/// UserDefaults 抽象（测试注入内存实现）。
public protocol DefaultsStoring: Sendable {
    func double(forKey key: String) -> Double
    func set(_ value: Double, forKey key: String)
}

extension UserDefaults: DefaultsStoring {}

/// 轮询驱动：循环 tick 的 Task，间隔变化时重启生效。
@MainActor
public final class Poller {
    public init() {}
    private weak var model: AppModel?
    private var task: Task<Void, Never>?

    public func attach(_ model: AppModel) {
        self.model = model
    }

    public func start() {
        task?.cancel()
        guard let model else { return }
        task = Task {
            while !Task.isCancelled {
                await model.tick()
                let interval = model.pollInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func reschedule() {
        start()
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
