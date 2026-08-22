import Foundation

/// Attention Queue 视图唯一的交互契约。GUI 和回归测试共用同一组闭包，
/// 避免按钮仍可见但实际接到了错误的 model action。
@MainActor
public struct AttentionQueueActions {
    public var onMarkSeen: (@MainActor @Sendable () -> Void)?
    public var onSnooze: (@MainActor @Sendable (_ until: Date) -> Void)?
    public var onDismissStale: (@MainActor @Sendable () -> Void)?
    public var onSetAISummaryOptIn: (@MainActor @Sendable (_ workspaceID: String, _ enabled: Bool) -> Void)?
    public var performJump: (@MainActor @Sendable () async -> JumpOutcome?)?

    public init(
        onMarkSeen: (@MainActor @Sendable () -> Void)? = nil,
        onSnooze: (@MainActor @Sendable (_ until: Date) -> Void)? = nil,
        onDismissStale: (@MainActor @Sendable () -> Void)? = nil,
        onSetAISummaryOptIn: (@MainActor @Sendable (_ workspaceID: String, _ enabled: Bool) -> Void)? = nil,
        performJump: (@MainActor @Sendable () async -> JumpOutcome?)? = nil
    ) {
        self.onMarkSeen = onMarkSeen
        self.onSnooze = onSnooze
        self.onDismissStale = onDismissStale
        self.onSetAISummaryOptIn = onSetAISummaryOptIn
        self.performJump = performJump
    }

    public static func live(model: AttentionQueueModel) -> AttentionQueueActions {
        let dismissStale: (@MainActor @Sendable () -> Void)?
        if model.projection.staleHistory.isEmpty {
            dismissStale = nil
        } else {
            dismissStale = { model.dismissStale() }
        }
        guard let head = model.headRequest else {
            return AttentionQueueActions(
                onDismissStale: dismissStale,
                onSetAISummaryOptIn: { workspaceID, enabled in
                    model.setAISummaryOptIn(workspaceID, enabled: enabled)
                }
            )
        }
        return AttentionQueueActions(
            onMarkSeen: { model.markSeen(head.key) },
            onSnooze: { until in model.snooze(head.key, until: until) },
            onDismissStale: dismissStale,
            onSetAISummaryOptIn: { workspaceID, enabled in
                model.setAISummaryOptIn(workspaceID, enabled: enabled)
            },
            performJump: { await model.jump(for: head) }
        )
    }
}

/// GUI 自动化的稳定标识。文案可以演进，回归脚本不依赖显示字符串定位控件。
public enum AttentionAccessibilityID {
    public static let surface = "attention.surface"
    public static let pill = "attention.pill"
    public static let requestCard = "request.card"
    public static let requestStatus = "request.status"
    public static let evidenceToggle = "request.evidence.toggle"
    public static let markSeen = "request.mark-seen"
    public static let snooze = "request.snooze"
    public static let snoozeFiveMinutes = "request.snooze.5m"
    public static let dismissStale = "request.dismiss-stale"
    public static let jump = "request.jump"
    public static let ambient = "section.ambient"
}
