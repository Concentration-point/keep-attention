import SwiftUI
import KeepAttentionCore

/// M1 runtime 可选操作集：live root 传 model 实现，静态 preview 不传（保持只读）。
struct AttentionQueueActions {
    var onMarkSeen: (@MainActor () -> Void)? = nil
    var onSnooze: (@MainActor (_ until: Date) -> Void)? = nil
    var onDismissStale: (@MainActor () -> Void)? = nil
    var performJump: (() async -> JumpOutcome?)? = nil
}

/// 展开态主体内容：由 AttentionIslandSurface 提供固定尺寸与背景，
/// 本视图只负责队列滚动内容（头部行即表面药丸头）。
struct AttentionQueueView: View {
    let projection: AttentionQueueProjection
    var actions: AttentionQueueActions? = nil
    @State private var evidenceExpanded = false
    @State private var snoozedExpanded = false
    @State private var ambientExpanded = false
    @State private var staleExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 11) {
                    if let head = projection.queueHead {
                        RequestCardView(
                            request: head,
                            evidenceExpanded: $evidenceExpanded,
                            onMarkSeen: actions?.onMarkSeen,
                            onSnooze: actions?.onSnooze,
                            onDismissStale: dismissStaleAction,
                            performJump: actions?.performJump
                        )
                    } else {
                        quietState
                    }

                    if !projection.queuePreviews.isEmpty {
                        queuePreview
                    }
                    disclosureSection(
                        title: "Snoozed",
                        count: projection.snoozed.count,
                        expanded: $snoozedExpanded,
                        items: projection.snoozed
                    )
                    disclosureSection(
                        title: "State confirmation",
                        count: projection.staleHistory.count,
                        expanded: $staleExpanded,
                        items: projection.staleHistory
                    )
                    AmbientSectionView(
                        entries: projection.ambient,
                        availabilityLabel: projection.ambientAvailabilityLabel,
                        expanded: $ambientExpanded
                    )
                }
                .padding(14)
                .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
    }

    /// "Dismiss stale" 只在确实存在 stale 历史时挂到队首卡片的操作区。
    private var dismissStaleAction: (@MainActor () -> Void)? {
        guard let dismiss = actions?.onDismissStale, !projection.staleHistory.isEmpty else { return nil }
        return dismiss
    }

    private var quietState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("No request needs action", systemImage: "checkmark.circle")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(SignalGlass.primaryText)
            Text("Ambient activity stays visible below without being promoted into the queue.")
                .font(.system(size: 11.5))
                .foregroundStyle(SignalGlass.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("not request")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SignalGlass.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(SignalGlass.softFill))
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SignalGlass.raised)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SignalGlass.hairline))
        )
    }

    private var queuePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT IN QUEUE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(SignalGlass.secondaryText)
            ForEach(Array(projection.queuePreviews.enumerated()), id: \.offset) { index, request in
                HStack(spacing: 9) {
                    Text("\(index + 2)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(SignalGlass.secondaryText)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.kindLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SignalGlass.primaryText)
                        Text(request.needFromYou)
                            .font(.system(size: 9.5))
                            .foregroundStyle(SignalGlass.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(request.statusLabel)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(SignalGlass.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SignalGlass.softFill.opacity(0.72))
                )
            }
        }
    }

    private func disclosureSection(
        title: String,
        count: Int,
        expanded: Binding<Bool>,
        items: [AttentionRequestCardProjection]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(SignalGlass.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                if items.isEmpty {
                    Text("Nothing here.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SignalGlass.secondaryText)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kindLabel)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(SignalGlass.primaryText)
                            Text(item.statusLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(SignalGlass.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(SignalGlass.softFill.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(SignalGlass.hairline))
        )
    }
}
