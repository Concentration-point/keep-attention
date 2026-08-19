import Foundation

// issue #34：Workspace 控制（mute / AI summary opt-in）+ AI 摘要白名单最小 payload
// + fail-open 回退 + 本地历史清理纯逻辑。
//
// 设计要点：
// - mute 与 AI opt-in 都按 workspace（repo 名）粒度持久化（Codable），AI 增强必须
//   "全局 opt-in（DEEPSEEK_API_KEY 等既有全局开关）且该 workspace 显式 opt-in" 双重满足。
// - AI 摘要只接收白名单最小片段：repo/branch（脱敏）、kind 标签、确定性文案、
//   证据事件的安全标签；绝不携带 session id、correlation label、路径、terminal 标题、
//   原始 hook payload。payload 在本地 redact + 截断后才构造 SummaryContext。
// - 构造出的 SummaryContext 是一次性瞬态值，不持久化原始 payload；
//   返回给 UI 的只有有长度上限的显示文案（RequestDisplayCopy）。
// - fail-open：provider（DeepSeekClient 等 SummaryProviding 实现）抛错或输出超长时，
//   一律回退本地确定性文案，绝不因 AI 失败阻塞显示。不改 DeepSeekClient 行为。
// - StaleDismissal / LocalHistoryClearance 是对持久化快照的纯函数，
//   供"Dismiss stale"和"clear local history"控件驱动 runtime 重建 store。
//   真实通知/控件行为属于人工/真实运行验证缺口。

// MARK: - Workspace 控制状态

/// 按 workspace（repo 名）粒度的 mute 与 AI 摘要 opt-in 状态。
public struct WorkspaceControlsState: Codable, Equatable, Sendable {
    public var mutedWorkspaces: Set<String>
    public var aiSummaryOptInWorkspaces: Set<String>

    public init(
        mutedWorkspaces: Set<String> = [],
        aiSummaryOptInWorkspaces: Set<String> = []
    ) {
        self.mutedWorkspaces = mutedWorkspaces
        self.aiSummaryOptInWorkspaces = aiSummaryOptInWorkspaces
    }

    public func isMuted(_ workspaceID: String) -> Bool {
        mutedWorkspaces.contains(workspaceID)
    }

    public mutating func setMuted(_ workspaceID: String, muted: Bool) {
        if muted {
            mutedWorkspaces.insert(workspaceID)
        } else {
            mutedWorkspaces.remove(workspaceID)
        }
    }

    /// AI 摘要增强需要全局开关与 workspace 级 opt-in 同时满足。
    public func isAISummaryEnabled(_ workspaceID: String, globalAISummaryEnabled: Bool) -> Bool {
        globalAISummaryEnabled && aiSummaryOptInWorkspaces.contains(workspaceID)
    }

    public mutating func setAISummaryOptIn(_ workspaceID: String, enabled: Bool) {
        if enabled {
            aiSummaryOptInWorkspaces.insert(workspaceID)
        } else {
            aiSummaryOptInWorkspaces.remove(workspaceID)
        }
    }
}

// MARK: - AI 显示文案（fail-open 的两端）

/// request 卡片摘要的显示文案：只有有界字符串，不携带任何原始 payload。
public struct RequestDisplayCopy: Codable, Equatable, Sendable {
    public static let aiSourceLabel = "AI summary · whitelisted minimal payload"
    public static let fallbackSourceLabel = "Deterministic local fallback"

    public var whyAttention: String
    public var needFromYou: String
    public var sourceLabel: String

    public init(whyAttention: String, needFromYou: String, sourceLabel: String) {
        self.whyAttention = whyAttention
        self.needFromYou = needFromYou
        self.sourceLabel = sourceLabel
    }

    /// 本地确定性回退文案（#32 投影既有 copy 的等价物，供 AI 失败时 fail-open）。
    public static func deterministicFallback(
        whyAttention: String = "A structured request is waiting.",
        needFromYou: String = "Check the request and respond in the source app."
    ) -> RequestDisplayCopy {
        RequestDisplayCopy(
            whyAttention: whyAttention,
            needFromYou: needFromYou,
            sourceLabel: fallbackSourceLabel
        )
    }
}

// MARK: - AI 白名单策略

public enum AISummaryPolicy: Sendable {
    /// 白名单 payload 的总长度上限（远小于 DeepSeek 输入的通用 6000 字符上限）。
    public static let maxPayloadCharacters = 1_200
    /// 证据事件安全标签最多携带条数。
    public static let maxEvidenceEventLabels = 5
    /// AI 返回后允许进入 UI 的单字段显示长度上限。
    public static let maxDisplayCharacters = 160

    /// 用白名单片段构造最小 SummaryContext：
    /// - repo / branch 先做安全分量清洗（去掉路径、反斜杠等，同 #32 投影的 safeComponent 规则）；
    /// - agentMessage 只拼接 kind 标签、确定性文案与安全事件标签，并做 redact + 截断；
    /// - tail 恒为空、title 恒为 nil：绝不外发 terminal 渲染文本、标题或原始 hook payload。
    public static func makeWhitelistedContext(
        repo: String?,
        branch: String?,
        kindLabel: String,
        needFromYou: String,
        evidenceEventLabels: [String]
    ) -> SummaryContext {
        var lines: [String] = []
        lines.append("kind: \(kindLabel)")
        lines.append("need: \(needFromYou)")
        let safeEvents = evidenceEventLabels.prefix(maxEvidenceEventLabels)
        if !safeEvents.isEmpty {
            lines.append("events: \(safeEvents.joined(separator: ", "))")
        }
        let payload = redactAndTruncate(lines.joined(separator: "\n"), maxCharacters: maxPayloadCharacters)
        return SummaryContext(
            repo: safeComponent(repo) ?? "workspace",
            branch: safeComponent(branch),
            title: nil,
            agentMessage: payload.isEmpty ? nil : payload,
            tail: []
        )
    }

    /// fail-open 增强：provider 成功则映射为有长度上限的显示文案；任何失败
    /// （无 key、网络、解析、超长）都回退本地确定性文案。原始 payload 不返回、不持久化。
    public static func enhance(
        context: SummaryContext,
        provider: any SummaryProviding,
        fallback: RequestDisplayCopy
    ) async -> RequestDisplayCopy {
        let summary: TerminalSummary
        do {
            summary = try await provider.summarize(context: context)
        } catch {
            return fallback
        }
        let why = clampDisplay(summary.currentTask, fallback: fallback.whyAttention)
        let need = clampDisplay(
            summary.needsInput == "无" ? summary.nextStep : summary.needsInput,
            fallback: fallback.needFromYou
        )
        if why == nil && need == nil { return fallback }
        return RequestDisplayCopy(
            whyAttention: why ?? fallback.whyAttention,
            needFromYou: need ?? fallback.needFromYou,
            sourceLabel: RequestDisplayCopy.aiSourceLabel
        )
    }

    /// 显示文案长度守卫：空或超长视为不可信输出，回退 nil 由调用方用确定性文案。
    private static func clampDisplay(_ text: String, fallback: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "未知" else { return nil }
        guard trimmed.count <= maxDisplayCharacters else { return nil }
        return trimmed
    }

    /// 与 #32 AmbientEntryProjection.safeComponent 相同规则的安全分量：
    /// 去空白、拒绝包含路径分隔符的值。
    private static func safeComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\")
        else { return nil }
        return value
    }
}

// MARK: - 本地历史清理（纯函数）

/// "Dismiss stale"：从持久化快照中移除 stale 历史（可指定 key，nil 表示全部 stale）。
/// active 请求与非 stale 历史保持不动；由调用方用返回的快照重建 store。
public enum StaleDismissal {
    public static func dismissStale(
        in snapshot: AttentionRequestPersistenceSnapshot,
        matching keys: Set<AttentionRequestKey>? = nil
    ) -> AttentionRequestPersistenceSnapshot {
        AttentionRequestPersistenceSnapshot(
            activeRequests: snapshot.activeRequests,
            closedHistory: snapshot.closedHistory.filter { request in
                guard request.status == .stale else { return true }
                if let keys { return !keys.contains(request.key) }
                return false
            }
        )
    }
}

/// "Clear local history"：清空全部 closed 历史，保留仍在进行的义务（active 请求）。
public enum LocalHistoryClearance {
    public static func clearClosedHistory(
        in snapshot: AttentionRequestPersistenceSnapshot
    ) -> AttentionRequestPersistenceSnapshot {
        AttentionRequestPersistenceSnapshot(
            activeRequests: snapshot.activeRequests,
            closedHistory: []
        )
    }
}
