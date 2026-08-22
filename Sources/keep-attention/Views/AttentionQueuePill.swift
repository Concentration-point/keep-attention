import SwiftUI
import KeepAttentionCore

/// 药丸行内容：信号点 + 标题/副标题 + 计数徽标（+ 展开态收起箭头）。
/// 独立药丸（AttentionQueuePill）与单视图生长表面（AttentionIslandSurface）共用。
struct AttentionQueuePillRow: View {
    let projection: AttentionQueueProjection
    var showsCollapseChevron: Bool = false
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var signalExpanded = false

    var body: some View {
        HStack(spacing: 10) {
            signal
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(SignalGlass.primaryText)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SignalGlass.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isRequest ? SignalGlass.inkOnSignal : SignalGlass.secondaryText)
                .frame(minWidth: 20, minHeight: 20)
                .background(Circle().fill(isRequest ? SignalGlass.amber : SignalGlass.softFill))
            if showsCollapseChevron {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SignalGlass.secondaryText)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AttentionAccessibilityID.pill)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .onAppear { signalExpanded = true }
    }

    private var signal: some View {
        ZStack {
            Circle()
                .fill((isRequest ? SignalGlass.amber : SignalGlass.quiet).opacity(0.15))
                .frame(width: 24, height: 24)
                .scaleEffect(shouldPulse && signalExpanded && !reduceMotion ? 1.28 : 0.92)
                .opacity(shouldPulse && signalExpanded && !reduceMotion ? 0.2 : 0.75)
                .animation(
                    shouldPulse && !reduceMotion
                        ? .easeInOut(duration: 2.4).repeatForever(autoreverses: true)
                        : nil,
                    value: signalExpanded
                )
            Circle()
                .fill(isRequest ? SignalGlass.amber : SignalGlass.quiet)
                .frame(width: 8, height: 8)
        }
        .frame(width: 24, height: 24)
    }

    private var shouldPulse: Bool {
        projection.queueHead?.usesStrongSignal == true
    }

    private var isRequest: Bool {
        if case .request = projection.collapsed { return true }
        return false
    }

    private var title: String {
        switch projection.collapsed {
        case .request(let title, _, _), .ambient(let title, _, _): title
        }
    }

    private var detail: String {
        switch projection.collapsed {
        case .request(_, let detail, _), .ambient(_, let detail, _): detail
        }
    }

    private var count: Int {
        switch projection.collapsed {
        case .request(_, _, let count), .ambient(_, _, let count): count
        }
    }
}

/// 独立药丸形态（胶囊背景 + matchedGeometry）。M1 运行时已改用
/// AttentionIslandSurface 单视图生长表面；此视图保留独立胶囊用法。
struct AttentionQueuePill: View {
    let projection: AttentionQueueProjection
    var namespace: Namespace.ID
    let onTap: () -> Void

    var body: some View {
        AttentionQueuePillRow(projection: projection, onTap: onTap)
            .frame(width: 382, alignment: .leading)
            .background {
                Capsule()
                    .fill(SignalGlass.panel)
                    .overlay(Capsule().strokeBorder(SignalGlass.hairline))
                    .matchedGeometryEffect(id: "requestSurface", in: namespace)
            }
            .contentShape(Capsule())
    }
}

enum SignalGlass {
    static let panel = Color(red: 0.055, green: 0.059, blue: 0.066).opacity(0.97)
    static let raised = Color(red: 0.09, green: 0.095, blue: 0.105)
    static let softFill = Color.white.opacity(0.065)
    static let hairline = Color.white.opacity(0.12)
    static let primaryText = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.58)
    static let amber = Color(red: 0.98, green: 0.64, blue: 0.18)
    static let amberSoft = amber.opacity(0.14)
    static let quiet = Color(red: 0.48, green: 0.55, blue: 0.62)
    static let blue = Color(red: 0.39, green: 0.68, blue: 0.95)
    static let inkOnSignal = Color(red: 0.09, green: 0.065, blue: 0.025)
}
