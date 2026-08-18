import Foundation
import Observation

/// 应用视图模型：一次 tick = 采集 → 去重 → 总结 → 发布（spec §2/§3 编排）。
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
    /// 单次 tick 最多读取的终端数（防终端数失控）。
    static let maxReadsPerTick = 32

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

    /// handle → 内容指纹（去重键）
    private var fingerprints: [String: String] = [:]
    /// handle → 缓存摘要（指纹未变时复用，不重复烧 API）
    private var summaries: [String: TerminalSummary] = [:]
    /// handle → 最近一次渲染 tail（供忙闲启发式跨 tick 复用）
    private var tails: [String: [String]] = [:]
    /// 上一 tick 已知等待输入的终端（本 tick 继续读取刷新）
    private var waitingHandles: Set<String> = []
    private var isTicking = false

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

    /// 药丸默认展示：抢显等待终端 > 焦点终端 > 任意终端。
    public var pillDisplay: TerminalDisplay? {
        mostUrgentWaiting
            ?? displays.first { $0.handle == focusedHandle }
            ?? displays.first
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

        // 读取集合：焦点终端 + 等待态 agent 所在 worktree 的终端 + 上一 tick 已知等待
        var readSet = Set<String>()
        if let focus { readSet.insert(focus) }
        for w in ps.worktrees {
            let hasWaitingAgent = (w.agents ?? []).contains {
                StatusResolver.waitingStates.contains($0.state?.lowercased() ?? "")
            }
            if hasWaitingAgent {
                for t in list.terminals where t.worktreeId == w.worktreeId {
                    readSet.insert(t.handle)
                }
            }
        }
        readSet.formUnion(waitingHandles)
        let handlesToRead = Array(readSet.prefix(Self.maxReadsPerTick))

        let newTails = await readTails(handles: handlesToRead)
        for (handle, tail) in newTails { tails[handle] = tail }

        // 组装全部终端的展示状态
        let now = Date()
        displays = list.terminals.map { t in
            let w = t.worktreeId.flatMap { worktreeById[$0] }
            let status = StatusResolver.resolve(StatusInput(
                agentStates: (w?.agents ?? []).compactMap(\.state),
                worktreeStatus: w?.status,
                lastOutputAt: t.lastOutputDate,
                tail: tails[t.handle],
                now: now
            ))
            return TerminalDisplay(
                id: t.handle,
                handle: t.handle,
                repo: w?.repo ?? "未知",
                branch: t.shortBranch ?? w?.shortBranch,
                title: t.title,
                status: status,
                summary: .loading,
                lastOutputAt: t.lastOutputDate,
                updatedAt: nil
            )
        }

        // 总结集合：焦点 + 全部等待中的终端（指纹去重后才真正调 API）
        let waitingNow = displays.filter { $0.status == .waitingForInput }.map(\.handle)
        waitingHandles = Set(waitingNow)
        var summarizeSet = Set(waitingNow)
        if let focus { summarizeSet.insert(focus) }

        for handle in summarizeSet {
            guard let idx = displays.firstIndex(where: { $0.handle == handle }) else { continue }
            let t = list.terminals.first { $0.handle == handle }
            let w = t?.worktreeId.flatMap { worktreeById[$0] }
            let agents = w?.agents ?? []
            let agentMessage = agents.compactMap(\.lastAssistantMessage).last
                ?? agents.compactMap(\.taskTitle).last
            let tail = tails[handle] ?? []
            let fingerprint = contentFingerprint([agentMessage ?? ""] + tail)

            if fingerprint == fingerprints[handle], let cached = summaries[handle] {
                displays[idx].summary = .ready(cached)
                continue
            }
            let context = SummaryContext(
                repo: displays[idx].repo,
                branch: displays[idx].branch,
                title: displays[idx].title,
                agentMessage: agentMessage,
                tail: tail
            )
            do {
                let summary = try await summarizer.summarize(context: context)
                fingerprints[handle] = fingerprint
                summaries[handle] = summary
                displays[idx].summary = .ready(summary)
                displays[idx].updatedAt = Date()
            } catch {
                // 失败不记录指纹 → 下一 tick 自动重试（spec §3 稍后重试）
                displays[idx].summary = .failed(Self.describeSummaryError(error))
                displays[idx].updatedAt = Date()
            }
        }
    }

    /// 并行读取多个终端的渲染 tail；单个失败只跳过该终端。
    private func readTails(handles: [String]) async -> [String: [String]] {
        guard !handles.isEmpty else { return [:] }
        let client = orca
        return await withTaskGroup(of: (String, [String]?).self) { group in
            for handle in handles {
                group.addTask {
                    do {
                        let read = try await client.terminalRead(handle: handle)
                        return (handle, read.tail)
                    } catch {
                        return (handle, nil)
                    }
                }
            }
            var result: [String: [String]] = [:]
            for await (handle, tail) in group {
                if let tail { result[handle] = tail }
            }
            return result
        }
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
