import Foundation

// issue #34（承接 #20）：中断升级纯逻辑判定器。
//
// 设计要点：
// - 只有高置信来源（structuredHook / supervisedWorkflow）的强阻塞义务
//   （permissionRequired / userAnswerRequired）才可能升级为强中断。
// - 仅 Unseen 义务可升级；Seen、未到期的 Snooze、被 mute 的 workspace 一律抑制。
// - 同一用户义务至多升级一次：复用 #29 域内核的 escalationCount / lastEscalatedAt
//   字段语义（escalationCount > 0 即该义务的中断配额已用掉），不改 store 行为。
// - 全局短窗节流：最近一次强升级后 60 秒内不再升级（窗口可注入）。
// - stale 默认低调：只有"原本强阻塞"的 stale 才允许一次低频 uncertain 通知，
//   同样受 mute / 全局通知开关 / 自有低频节流窗约束。
// - 本文件是纯函数判定器：不接触通知权限、声音、GUI，也不接入 Poller 主循环；
//   真实通知投递属于人工/真实运行验证缺口。

// MARK: - 节流状态（可注入，UI/runtime 持有）

/// 中断通知的全局节流状态。强升级与 stale uncertain 通知使用相互独立的窗口。
public struct InterruptionThrottleState: Equatable, Sendable {
    /// 强升级全局节流窗（issue #20 建议 60 秒短窗）。
    public var escalationWindow: TimeInterval
    /// stale uncertain 通知的低频节流窗（默认 15 分钟，显著低于强升级频率）。
    public var staleWindow: TimeInterval
    /// 最近一次强升级时间。
    public var lastEscalationAt: Date?
    /// 最近一次 stale uncertain 通知时间。
    public var lastStaleNotificationAt: Date?

    public init(
        escalationWindow: TimeInterval = 60,
        staleWindow: TimeInterval = 15 * 60,
        lastEscalationAt: Date? = nil,
        lastStaleNotificationAt: Date? = nil
    ) {
        self.escalationWindow = escalationWindow
        self.staleWindow = staleWindow
        self.lastEscalationAt = lastEscalationAt
        self.lastStaleNotificationAt = lastStaleNotificationAt
    }

    public mutating func recordEscalation(at date: Date) {
        lastEscalationAt = date
    }

    public mutating func recordStaleNotification(at date: Date) {
        lastStaleNotificationAt = date
    }

    func isEscalationThrottled(now: Date) -> Bool {
        guard let last = lastEscalationAt else { return false }
        return now.timeIntervalSince(last) < escalationWindow
    }

    func isStaleThrottled(now: Date) -> Bool {
        guard let last = lastStaleNotificationAt else { return false }
        return now.timeIntervalSince(last) < staleWindow
    }
}

// MARK: - 升级判定

public enum EscalationVerdict: Equatable, Sendable {
    case escalate
    case suppressed(EscalationSuppression)
}

public enum EscalationSuppression: Equatable, Sendable {
    case notificationsDisabled
    case notStrongBlockingKind
    case notHighConfidenceSource
    case notUnseen
    case snoozed(until: Date)
    case mutedWorkspace
    case obligationAlreadyEscalated(escalationCount: Int)
    case globalThrottleWindow(lastEscalatedAt: Date)
}

public enum EscalationPolicy: Sendable {
    /// 强阻塞义务类型：只有这两类可以直接阻断 agent 工作、值得强中断。
    public static let strongBlockingKinds: Set<AttentionRequestKind> = [
        .permissionRequired, .userAnswerRequired,
    ]

    /// 判定一个 request 当前是否应升级为强中断。
    /// 检查顺序即抑制优先级：全局开关 → 强阻塞类型 → 高置信来源 → Unseen/未到期
    /// snooze → 未 mute → 该义务未升级过 → 全局节流窗。
    public static func evaluate(
        request: AttentionRequest,
        now: Date,
        mutedSessionKeys: Set<AgentSessionKey> = [],
        notificationsEnabled: Bool = true,
        throttle: InterruptionThrottleState = InterruptionThrottleState()
    ) -> EscalationVerdict {
        guard notificationsEnabled else { return .suppressed(.notificationsDisabled) }
        guard strongBlockingKinds.contains(request.kind) else {
            return .suppressed(.notStrongBlockingKind)
        }
        guard request.sourceConfidence != .genericObservation else {
            return .suppressed(.notHighConfidenceSource)
        }
        switch request.status {
        case .unseen:
            break
        case let .snoozed(until):
            // 未到期 snooze 抑制；到期后回到队列，可重新参与判定（一次性配额另由 escalationCount 保证）。
            if until > now { return .suppressed(.snoozed(until: until)) }
        case .seen, .resolved, .stale:
            return .suppressed(.notUnseen)
        }
        guard !mutedSessionKeys.contains(request.sessionKey) else {
            return .suppressed(.mutedWorkspace)
        }
        guard request.escalationCount == 0 else {
            return .suppressed(.obligationAlreadyEscalated(escalationCount: request.escalationCount))
        }
        if let last = throttle.lastEscalationAt, throttle.isEscalationThrottled(now: now) {
            return .suppressed(.globalThrottleWindow(lastEscalatedAt: last))
        }
        return .escalate
    }

    /// 记录一次升级：返回更新了 escalationCount / lastEscalatedAt 的副本。
    /// 不改 store 行为；由调用方（未来的 runtime 接线）把副本写回自己的持久化层。
    public static func markEscalated(request: AttentionRequest, at date: Date) -> AttentionRequest {
        var marked = request
        marked.escalationCount = request.escalationCount + 1
        marked.lastEscalatedAt = date
        return marked
    }
}

// MARK: - stale uncertain 通知判定

public enum StaleNotificationVerdict: Equatable, Sendable {
    case notifyOnceUncertain
    case silent(StaleNotificationSuppression)
}

public enum StaleNotificationSuppression: Equatable, Sendable {
    case notificationsDisabled
    case notStale
    case notOriginallyStrongBlocking
    case mutedWorkspace
    case obligationAlreadyInterrupted(escalationCount: Int)
    case staleThrottleWindow(lastNotifiedAt: Date)
}

public enum StaleNotificationPolicy: Sendable {
    /// stale 默认低调（silent）；只有原本强阻塞的 stale 才可发一次低频 uncertain 通知。
    /// "只发一次"复用 escalationCount 语义：同一义务的中断配额（强升级或 uncertain 通知）总共一次。
    public static func evaluate(
        request: AttentionRequest,
        now: Date,
        mutedSessionKeys: Set<AgentSessionKey> = [],
        notificationsEnabled: Bool = true,
        throttle: InterruptionThrottleState = InterruptionThrottleState()
    ) -> StaleNotificationVerdict {
        guard notificationsEnabled else { return .silent(.notificationsDisabled) }
        guard request.status == .stale else { return .silent(.notStale) }
        guard EscalationPolicy.strongBlockingKinds.contains(request.kind),
              request.sourceConfidence != .genericObservation
        else { return .silent(.notOriginallyStrongBlocking) }
        guard !mutedSessionKeys.contains(request.sessionKey) else {
            return .silent(.mutedWorkspace)
        }
        guard request.escalationCount == 0 else {
            return .silent(.obligationAlreadyInterrupted(escalationCount: request.escalationCount))
        }
        if let last = throttle.lastStaleNotificationAt, throttle.isStaleThrottled(now: now) {
            return .silent(.staleThrottleWindow(lastNotifiedAt: last))
        }
        return .notifyOnceUncertain
    }
}
