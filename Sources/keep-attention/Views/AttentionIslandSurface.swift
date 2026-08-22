import SwiftUI
import KeepAttentionCore

private enum SurfaceLayout {
    static let collapsedWidth: CGFloat = 382
    static let expandedWidth: CGFloat = 404
    /// 展开态主体高度（头部行自然高度 + 490 ≈ 原面板 540）。
    static let expandedBodyHeight: CGFloat = 490
    static let corner: CGFloat = 24
}

/// 单视图生长表面（playground 选型 C）：不做视图交换——药丸头常驻，
/// 展开时同一表面向下生长，内容自上而下裁剪揭示 + 快速淡入；收起反向。
/// 高度与宽度由同一个 spring 驱动（单一时钟，无频闪）；
/// 窗口本身固定为展开态大小，因此无 AppKit resize 参与。
struct AttentionIslandSurface<Expanded: View>: View {

    let projection: AttentionQueueProjection
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let expandedContent: () -> Expanded

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            AttentionQueuePillRow(
                projection: projection,
                showsCollapseChevron: isExpanded,
                onTap: onToggle
            )
            expandedContent()
                .frame(width: SurfaceLayout.expandedWidth,
                       height: isExpanded ? SurfaceLayout.expandedBodyHeight : 0,
                       alignment: .top)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                .animation(.easeOut(duration: 0.16), value: isExpanded)
        }
        .frame(width: isExpanded ? SurfaceLayout.expandedWidth : SurfaceLayout.collapsedWidth, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: SurfaceLayout.corner, style: .continuous)
                .fill(SignalGlass.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: SurfaceLayout.corner, style: .continuous)
                        .strokeBorder(SignalGlass.hairline)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: SurfaceLayout.corner, style: .continuous))
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9), value: isExpanded)
        .contentShape(RoundedRectangle(cornerRadius: SurfaceLayout.corner, style: .continuous))
        .accessibilityIdentifier(AttentionAccessibilityID.surface)
    }
}
