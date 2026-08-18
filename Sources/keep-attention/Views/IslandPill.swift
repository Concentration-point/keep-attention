import SwiftUI
import KeepAttentionCore

/// 状态圆点：绿=忙 / 琥珀脉冲=等待输入 / 灰=空闲（spec §4）。
struct StatusDot: View {
    let status: TerminalActivityStatus
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(status == .waitingForInput && pulsing ? 1.4 : 1.0)
            .opacity(status == .waitingForInput && pulsing ? 0.55 : 1.0)
            .animation(
                status == .waitingForInput
                    ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { pulsing = true }
    }

    private var color: Color {
        switch status {
        case .busy: .green
        case .waitingForInput: .orange
        case .idle: Color(white: 0.62)
        }
    }
}

/// 收起态：贴顶药丸（spec §4 收起态）。徽标聚合多终端信号（issue #12）：
/// 有等待时橙色显示"等待数/总数"，否则灰色显示总 terminal 数。
struct IslandPill: View {
    let display: AppModel.TerminalDisplay?
    let waitingCount: Int
    let totalTerminalCount: Int
    let hasError: Bool
    let errorMessage: String?
    var namespace: Namespace.ID
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                .matchedGeometryEffect(id: "islandBackground", in: namespace)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
    }

    @ViewBuilder private var content: some View {
        if let d = display {
            StatusDot(status: d.status)
            Text(pillTitle(d))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if waitingCount > 0 {
                Text("\(waitingCount)/\(totalTerminalCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                    .help("\(waitingCount) 个终端等待输入，共 \(totalTerminalCount) 个")
            } else if totalTerminalCount > 0 {
                Text("\(totalTerminalCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .help("共 \(totalTerminalCount) 个终端")
            }
        } else if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text("orca 不可用")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .help(errorMessage ?? "")
        } else {
            Circle().fill(Color(white: 0.62)).frame(width: 8, height: 8)
            Text("暂无终端")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private func pillTitle(_ d: AppModel.TerminalDisplay) -> String {
        let branch = d.branch.map { " · \($0)" } ?? ""
        return "\(d.repo)\(branch)"
    }
}
