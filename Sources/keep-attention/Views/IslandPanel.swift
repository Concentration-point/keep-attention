import SwiftUI
import KeepAttentionCore

/// 展开态：四段式面板（spec §4 展开态）。
struct IslandPanel: View {
    let display: AppModel.TerminalDisplay?
    let otherWaitingCount: Int
    var namespace: Namespace.ID
    let onTogglePin: () -> Void
    let onCycleWaiting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let d = display {
                header(d)
                if otherWaitingCount > 0 {
                    Button(action: onCycleWaiting) {
                        Text("另有 \(otherWaitingCount) 个在等待 · 点击切换")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
                Divider().opacity(0.5)
                summaryBody(d)
            } else {
                HStack {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    Text("暂无终端")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))
                )
                .matchedGeometryEffect(id: "islandBackground", in: namespace)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    // MARK: 头部

    @ViewBuilder private func header(_ d: AppModel.TerminalDisplay) -> some View {
        HStack(spacing: 6) {
            StatusDot(status: d.status)
            Text(d.repo).font(.system(size: 13, weight: .semibold))
            Text("[\(d.branch ?? "—")]")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            statusBadge(d.status)
            Spacer()
            updatedAt(d)
            Button(action: onTogglePin) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("收起")
        }
    }

    private func statusBadge(_ status: TerminalActivityStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .busy: return ("忙碌", .green)
            case .waitingForInput: return ("等待输入", .orange)
            case .idle: return ("空闲", Color(white: 0.62))
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    @ViewBuilder private func updatedAt(_ d: AppModel.TerminalDisplay) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(relativeTime(d.updatedAt, now: context.date))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 四段式

    @ViewBuilder private func summaryBody(_ d: AppModel.TerminalDisplay) -> some View {
        switch d.summary {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在总结…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
        case .ready(let s):
            VStack(alignment: .leading, spacing: 8) {
                SectionRow(label: "当前任务", value: s.currentTask, highlight: false)
                SectionRow(label: "已到哪步", value: s.progress, highlight: false)
                SectionRow(label: "下一步", value: s.nextStep, highlight: false)
                SectionRow(label: "需要你提供", value: s.needsInput, highlight: true)
            }
        }
    }

    private func relativeTime(_ date: Date?, now: Date) -> String {
        guard let date else { return "未更新" }
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 5 { return "刚刚更新" }
        if seconds < 60 { return "\(seconds) 秒前更新" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前更新" }
        return "\(seconds / 3600) 小时前更新"
    }
}

/// 四段式中的一段；"未知"灰斜体，"需要你提供"为琥珀高亮块（spec §4）。
struct SectionRow: View {
    let label: String
    let value: String
    let highlight: Bool

    private var isUnknown: Bool { value.trimmingCharacters(in: .whitespaces) == "未知" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Group {
                if isUnknown {
                    Text("未知").italic().foregroundStyle(Color(white: 0.55))
                } else {
                    Text(value)
                        .foregroundStyle(highlight && value != "无"
                                         ? Color.primary
                                         : Color.primary.opacity(0.85))
                }
            }
            .font(.system(size: 12.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(highlight && value != "无" && !isUnknown
                          ? Color.orange.opacity(0.18)
                          : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        highlight && value != "无" && !isUnknown
                            ? Color.orange.opacity(0.5)
                            : .clear
                    )
            )
        }
    }
}
