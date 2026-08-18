## Question

终端"忙/等待输入/已完成"状态如何判定与呈现？

- 判定来源：`worktree ps.agents[].state`（仅 hook 覆盖会话有）、`status`+`lastOutputAt` 新鲜度近似、`terminal wait --for tui-idle` 主动探测——三者如何组合、优先级如何。
- 呈现：灵动岛上用什么视觉表达"它在忙 / 在等你输入 / 已完成"，尤其"需要我提供什么输入"这个最关键的提醒如何突出。

依赖：#5。产出：忙闲判定策略 + 灵动岛状态呈现规则。
