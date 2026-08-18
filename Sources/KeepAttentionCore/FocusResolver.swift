import Foundation

/// 两级焦点推导 + lastOutputAt 兜底（spec §2）：
/// 一级：worktree ps 里 isActive == true 的 worktree；
/// 二级：该 worktree 布局的 root.activeTabId → tab 里 active == true 的 pane；
/// 推导链断裂时取所有终端里 lastOutputAt 最新的作为兜底（永不空白）。
public struct FocusResolver: Sendable {
    public struct Snapshot: Sendable {
        var worktrees: [WorktreeInfo]
        var terminals: [TerminalInfo]
        var layouts: [VisualLayout]

        public init(worktrees: [WorktreeInfo], terminals: [TerminalInfo], layouts: [VisualLayout]) {
            self.worktrees = worktrees
            self.terminals = terminals
            self.layouts = layouts
        }
    }

    public let snapshot: Snapshot

    public func focusedHandle() -> String? {
        guard let active = snapshot.worktrees.first(where: { $0.isActive }) else {
            return fallbackHandle()
        }
        if let layout = snapshot.layouts.first(where: { $0.worktreeId == active.worktreeId }),
           let activeTabId = layout.root.activeTabId,
           let tab = layout.root.tabs.first(where: { $0.tabId == activeTabId }),
           let handle = Self.activeHandle(in: tab.panes),
           snapshot.terminals.contains(where: { $0.handle == handle }) {
            return handle
        }
        return fallbackHandle()
    }

    /// 在 pane 树里找 active == true 的终端 handle（分屏递归）。
    static func activeHandle(in node: PaneNode) -> String? {
        switch node {
        case .terminal(let t):
            return (t.active == true) ? t.handle : nil
        case .split(let s):
            return activeHandle(in: s.first) ?? activeHandle(in: s.second)
        case .unknown:
            return nil
        }
    }

    /// 兜底：lastOutputAt 最新的终端。
    private func fallbackHandle() -> String? {
        snapshot.terminals
            .max { ($0.lastOutputAt ?? -1) < ($1.lastOutputAt ?? -1) }?
            .handle
    }
}
