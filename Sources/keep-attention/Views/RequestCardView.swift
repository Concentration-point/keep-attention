import SwiftUI
import KeepAttentionCore

struct RequestCardView: View {
    let request: AttentionRequestCardProjection
    @Binding var evidenceExpanded: Bool
    var onJump: () -> Void = {}
    // M1 runtime 接线：可选操作回调（live root 传入，静态 preview 默认 nil 保持只读）。
    // @MainActor 闭包由 AttentionQueueView 传入后在嵌入 RequestActionsView 时统一 Task 跳回主线程。
    var onMarkSeen: (@MainActor () -> Void)? = nil
    var onSnooze: (@MainActor (_ until: Date) -> Void)? = nil
    var onDismissStale: (@MainActor () -> Void)? = nil
    var performJump: (() async -> JumpOutcome?)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SignalGlass.hairline)
            cardSection(label: "WHY ATTENTION", value: request.whyAttention)
            Divider().overlay(SignalGlass.hairline)
            cardSection(label: "NEED FROM YOU", value: request.needFromYou, highlighted: true)
            Divider().overlay(SignalGlass.hairline)
            evidenceActions
            if evidenceExpanded {
                EvidenceDrawerView(evidence: request.evidence, onJump: onJump)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if hasRuntimeActions {
                Divider().overlay(SignalGlass.hairline)
                RequestActionsView(
                    request: request,
                    onMarkSeen: onMarkSeen.map { action in { Task { @MainActor in action() } } },
                    onSnooze: onSnooze.map { action in { until in Task { @MainActor in action(until) } } },
                    onDismissStale: onDismissStale.map { action in { Task { @MainActor in action() } } },
                    performJump: performJump
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(SignalGlass.raised)
                .overlay(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .strokeBorder(request.usesStrongSignal ? SignalGlass.amber.opacity(0.5) : SignalGlass.hairline)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var hasRuntimeActions: Bool {
        onMarkSeen != nil || onSnooze != nil || onDismissStale != nil || performJump != nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.objectLabel)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(SignalGlass.primaryText)
                Text(request.kindLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SignalGlass.secondaryText)
            }
            Spacer()
            Text(request.statusLabel)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(request.usesStrongSignal ? SignalGlass.amber : SignalGlass.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(request.usesStrongSignal ? SignalGlass.amberSoft : SignalGlass.softFill))
        }
        .padding(14)
    }

    private func cardSection(label: String, value: String, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(highlighted ? SignalGlass.amber : SignalGlass.secondaryText)
            Text(value)
                .font(.system(size: 12.5, weight: highlighted ? .semibold : .regular))
                .foregroundStyle(SignalGlass.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlighted ? SignalGlass.amberSoft.opacity(0.58) : Color.clear)
    }

    private var evidenceActions: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    evidenceExpanded.toggle()
                }
            } label: {
                Label(
                    evidenceExpanded ? "Hide evidence" : "Evidence · \(request.evidence.count)",
                    systemImage: evidenceExpanded ? "chevron.up" : "chevron.down"
                )
            }
            .buttonStyle(SignalGlassButtonStyle())
            Spacer()
            Text(request.summarySourceLabel)
                .font(.system(size: 9))
                .foregroundStyle(SignalGlass.secondaryText)
                .lineLimit(1)
        }
        .padding(12)
    }
}

struct SignalGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(SignalGlass.primaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? SignalGlass.amberSoft : SignalGlass.softFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(SignalGlass.hairline)
            )
    }
}
