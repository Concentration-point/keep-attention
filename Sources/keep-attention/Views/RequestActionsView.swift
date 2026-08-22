import SwiftUI
import KeepAttentionCore

// issue #34：request 操作（Seen / Snooze / Dismiss stale / Jump）。
//
// 边界：
// - Seen / Snooze / Dismiss stale 通过闭包把意图交回调用方（runtime 用
//   AttentionRequestStore 的 markSeen / snooze 事件与 StaleDismissal 纯函数接线），
//   本视图不直接改 store，也不接入 Poller 主循环。
// - Jump 只连接 #33 SessionAwareJump 的状态/文案（JumpStatusCopy），不改其逻辑；
//   performJump 返回 JumpOutcome，失败也 fail-closed 展示可恢复文案。
// - 控件像素级行为属于人工 GUI 验证缺口。

struct RequestActionsView: View {
    let request: AttentionRequestCardProjection
    var onMarkSeen: (() -> Void)?
    var onSnooze: ((_ until: Date) -> Void)?
    var onDismissStale: (() -> Void)?
    var performJump: (@MainActor @Sendable () async -> JumpOutcome?)?
    @State private var jumpStatus: String?

    private static let snoozeChoices: [(label: String, interval: TimeInterval)] = [
        ("5 分钟", 5 * 60),
        ("15 分钟", 15 * 60),
        ("1 小时", 60 * 60),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let onMarkSeen {
                    Button("Seen") { onMarkSeen() }
                        .buttonStyle(SignalGlassButtonStyle())
                        .accessibilityIdentifier(AttentionAccessibilityID.markSeen)
                        .accessibilityLabel("Mark request as seen")
                }
                if onSnooze != nil {
                    Menu {
                        ForEach(Self.snoozeChoices, id: \.interval) { choice in
                            Button(choice.label) {
                                onSnooze?(Date().addingTimeInterval(choice.interval))
                            }
                            .accessibilityIdentifier(choice.interval == 5 * 60
                                ? AttentionAccessibilityID.snoozeFiveMinutes
                                : "request.snooze.\(Int(choice.interval))")
                        }
                    } label: {
                        Label("Snooze", systemImage: "moon.zzz")
                    }
                    .buttonStyle(SignalGlassButtonStyle())
                    .fixedSize()
                    .accessibilityIdentifier(AttentionAccessibilityID.snooze)
                    .accessibilityLabel("Snooze request")
                }
                if let onDismissStale {
                    Button("Dismiss stale") { onDismissStale() }
                        .buttonStyle(SignalGlassButtonStyle())
                        .accessibilityIdentifier(AttentionAccessibilityID.dismissStale)
                        .accessibilityLabel("Dismiss stale request")
                }
                Spacer()
                if let performJump {
                    Button {
                        Task { await runJump(performJump) }
                    } label: {
                        Label("Jump", systemImage: "arrow.down.forward.square")
                    }
                    .buttonStyle(SignalGlassButtonStyle())
                    .accessibilityIdentifier(AttentionAccessibilityID.jump)
                    .accessibilityLabel("Jump to request")
                }
            }
            if let jumpStatus {
                Text(jumpStatus)
                    .font(.system(size: 9.5))
                    .foregroundStyle(SignalGlass.secondaryText)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func runJump(_ performJump: () async -> JumpOutcome?) async {
        jumpStatus = "正在跳转…"
        switch await performJump() {
        case .succeeded(let success):
            jumpStatus = JumpStatusCopy.successMessage(success)
        case .failed(let failure, let attempts):
            jumpStatus = JumpStatusCopy.failureMessage(failure, attempts: attempts)
        case nil:
            jumpStatus = "跳转不可用（Orca 状态未就绪）"
        }
    }
}
