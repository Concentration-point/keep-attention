import SwiftUI
import KeepAttentionCore

/// 展开态：四段式面板（spec §4 展开态）+ 全部 live terminals 列表（issue #11）。
/// 点击列表行选中终端，详情区切换为该终端（issue #13）。
struct IslandPanel: View {
    let display: AppModel.TerminalDisplay?
    let terminals: [AppModel.TerminalDisplay]
    let focusedHandle: String?
    var selectedHandle: String?
    var otherWaitingCount: Int
    var namespace: Namespace.ID
    let onTogglePin: () -> Void
    let onCycleWaiting: () -> Void
    var onSelectTerminal: (String) -> Void = { _ in }
    var onJumpToTerminal: (String) -> Void = { _ in }
    var jumpError: String?

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
                jumpRow(d)
                if !terminals.isEmpty {
                    Divider().opacity(0.5)
                    terminalList
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                    Text("暂无 Orca live terminal")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("启动或切换到 Orca 终端后，这里会显示当前状态。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
        case .unavailable(let message):
            messageRow(icon: "info.circle", message: message)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在总结新结果…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
        case .failed(let message):
            messageRow(icon: "exclamationmark.circle", message: message)
        case .ready(let s):
            VStack(alignment: .leading, spacing: 8) {
                SectionRow(label: "当前任务", value: s.currentTask, highlight: false)
                SectionRow(label: "已到哪步", value: s.progress, highlight: false)
                SectionRow(label: "下一步", value: s.nextStep, highlight: false)
                SectionRow(label: "需要你提供", value: s.needsInput, highlight: true)
            }
        }
    }


    // MARK: 全部终端列表（issue #11）

    /// 所有 live terminals，包括无 agents[] 匹配的终端；纯展示，不触发总结。
    private var terminalList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live 终端 · \(terminals.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if terminals.count > 8 {
                    Text("可滚动")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(terminals) { t in
                        Button {
                            onSelectTerminal(t.handle)
                        } label: {
                            TerminalListRow(
                                display: t,
                                isFocused: t.handle == focusedHandle,
                                isSelected: t.handle == selectedHandle
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 192)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: 跳转到终端（issue #15）

    /// 详情区"跳转"操作。TerminalDisplay 无 connected 字段，terminal list 的输出即 live
    /// terminals，这里对展示中的终端一律显示；点击列表行仍只选中，跳转必须走本按钮。
    private func jumpRow(_ d: AppModel.TerminalDisplay) -> some View {
        HStack(spacing: 8) {
            Button {
                onJumpToTerminal(d.handle)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle")
                    Text("跳转到终端")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("切换 Orca 到该终端")
            if let jumpError {
                Text(jumpError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    private func messageRow(icon: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
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

/// 终端列表中的单行（issue #11）：状态点 + repo/branch + 焦点标记 + 摘要可用状态。
/// 仅展示 TerminalDisplay 现有字段，不引入任何总结调用。
/// isSelected 为详情区当前展示终端（issue #13 点击选中），与 focused（终端焦点）是两个概念。
struct TerminalListRow: View {
    let display: AppModel.TerminalDisplay
    let isFocused: Bool
    var isSelected: Bool = false

    private var visualState: TerminalListVisualState {
        TerminalListVisualState.resolve(status: display.status, summary: display.summary)
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(stateColor)
                .frame(width: 3, height: 28)
            StatusDot(status: display.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(titleText)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isFocused {
                        Text("当前")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(stateLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(stateColor.opacity(0.14)))
                        .foregroundStyle(stateColor)
                }
                Text(summaryText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear)
        )
    }

    /// 选中（详情区展示中）用 accent 填充+描边；焦点（终端在前台）保持原有浅填充。
    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isFocused { return Color.primary.opacity(0.08) }
        return stateColor.opacity(0.04)
    }

    /// branch 优先，缺失时退到 title（issue #11 行内容要求）。
    private var titleText: String {
        if let branch = display.branch?.trimmingCharacters(in: .whitespaces), !branch.isEmpty {
            return "\(display.repo) · \(branch)"
        }
        if let title = display.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            return "\(display.repo) · \(title)"
        }
        return display.repo
    }

    /// 摘要可用状态；unavailable 直接复用 SummaryState 携带的 UI 文案。
    private var summaryText: String {
        switch display.summary {
        case .ready:
            return "有结构化输出"
        case .loading:
            return "正在总结…"
        case .failed:
            return "总结失败"
        case .unavailable(let message):
            return message
        }
    }

    private var stateLabel: String {
        switch visualState {
        case .waiting: return "等待"
        case .newResult: return "新结果"
        case .running: return "运行中"
        case .idle: return "空闲"
        case .unavailable: return "无 hook"
        }
    }

    private var stateColor: Color {
        switch visualState {
        case .waiting: return .orange
        case .newResult: return .blue
        case .running: return .green
        case .idle: return Color(white: 0.58)
        case .unavailable: return Color(white: 0.45)
        }
    }
}
