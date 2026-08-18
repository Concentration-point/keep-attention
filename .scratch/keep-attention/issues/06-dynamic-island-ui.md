## Question

灵动岛式浮层 UI 的具体形态如何设计？

- 收起态（药丸小条）显示什么最小信息，展开态显示什么（当前任务/已到哪步/下一步/需要什么输入四段式）？
- 窗口行为：贴刘海/顶部定位、常驻置顶、non-activating（点击不抢焦点，避免打断你正在看的终端）、圆角与展开/收起动画。
- 技术栈：**已定 SwiftUI 原生 app**（2026-08-18 复核性能/动效/轻便后确定，放弃 Rust/Tauri）。窗口用 `NSPanel`（`.nonactivatingPanel` + `.floating`/statusBar level，贴刘海定位），视觉用 SwiftUI，展开/收起用 `matchedGeometryEffect` + spring 动画。后台逻辑：`Process` 调 `orca` CLI、`URLSession` 调 DeepSeek。此票只剩「UI 形态设计」，技术取舍已不再是问题。

依赖前置决策：数据获取路径已锁定（#5）。产出：灵动岛 UI 形态设计（收起/展开态信息布局 + 窗口/动画方案）。
