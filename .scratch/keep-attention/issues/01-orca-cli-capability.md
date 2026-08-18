## Question

Orca 的公共 CLI（`orca-cli` skill，通过 `ORCA skills get orca-cli` 加载完整指南）到底暴露了哪些与本工具相关的能力？必须查清并给出确切的子命令/字段：

1. **终端枚举**：能否列出当前所有 Orca 管理的终端/agent 会话？（如 `terminal list`、`worktree ps`）返回哪些字段（id、标题、所属 worktree、运行的 agent 类型、状态）？
2. **当前聚焦终端**：CLI 是否直接暴露“用户此刻聚焦在哪个终端/agent”这个信号？（`status --json`？某个 focused/active 字段？）如果没有，还有什么旁路可判断焦点？
3. **终端内容读取**：能否读取某个终端的输出/对话内容？（`terminal read`/`wait`）能读到多完整——是原始 PTY 缓冲，还是 agent 的结构化对话？有无长度/历史限制？
4. **cardStatus / 元信息**：是否有表达“agent 在忙/等待输入/已完成”的结构化状态字段？

本票为纯文档/CLI 核查（AFK），不做实际探针跑通（那是票 02）。产出：一份能力清单（子命令 + 关键字段 + 限制），作为票 04 落锤的证据之一。
