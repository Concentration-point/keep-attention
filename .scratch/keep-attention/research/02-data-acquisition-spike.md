# 票 #3 探针实测：Orca 数据获取最小链路（list / read / focus）

- 环境：Orca app v1.4.183，可执行文件 `/usr/local/bin/orca`（→ `/Applications/Orca.app/.../bin/orca`）。
- 时间：2026-08-18。运行者：main worktree（keep-attention）内的终端。
- 结论一句话：**数据获取「部分可行」。三要素都能从公共 CLI 拿到，且都用真实命令跑通了；唯一的硬约束是「结构化对话/agent 状态」依赖 status-hook 覆盖，非全量，其余走 `terminal read` 的渲染文本降级。**

---

## 1. 列出终端 / agent（可行 ✅）

命令：

```bash
orca worktree ps --json        # 以 worktree 为单位，带 status/agents/isActive
orca terminal list --json      # 以终端为单位，带 handle/worktreeId/title/lastOutputAt
```

`worktree ps` 真实返回（脱敏，节选一个 worktree）：

```json
{
  "repo": "keep-attention",
  "worktreeId": "…::/Users/…/orca/keep-attention",
  "isActive": false,
  "liveTerminalCount": 2,
  "status": "working",
  "lastOutputAt": 1786990019208,
  "agents": []
}
```

- 本次快照共 **11 个 worktree、23 个终端**（`totalCount:23, truncated:false`）。
- 每个终端项含：`handle`、`ptyId`、`worktreeId`、`worktreePath`、`branch`、`tabId`、`leafId`、`title`、`connected`、`writable`、`lastOutputAt`、`preview`。
- **忙闲近似**：worktree 级 `status` 取值实测见到 `working` / `active`；终端级 `terminal read` 的 `status` 见到 `running`。没有专门的 `cardStatus` 忙/等待输入字段（见第 4 节）。

## 2. 读取终端内容（可行 ✅，有渲染化与滚动上限）

命令：

```bash
orca terminal read --terminal <handle> --json
orca terminal read --terminal <handle> --cursor 0 --limit 1000 --json
```

对一个正在跑 agent 的终端（context 仓 Claude 会话）实测：

- 返回结构：`{status, tail:[…行…], truncated, limited, oldestCursor, nextCursor, latestCursor, returnedLineCount}`。
- `tail` 是**渲染后的逐行明文**（含中文、含框线字符），**不是** PTY 原始字节、**也不是** agent 的结构化对话对象。
- **滚动上限实测**：即便 `--cursor 0 --limit 1000`，`returnedLineCount` 也只有 **119**，`oldestCursor:"0" latestCursor:"119"`，`truncated:false`。→ 缓冲区只保留约一屏多（~119 行）的渲染历史，更早的内容已被丢弃，**无法**靠加大 limit 找回。
- 含义：能拿到「最近对话/最近输出」，拿不到完整历史。对灵动岛「它现在在干什么/问我什么」够用；对「完整任务回放」不够。

脱敏样例（context 仓某会话尾部，说明能读到真实语义）：

```
下一个问题：这个 skill 的核心输出，你希望定义成什么？
A. 结构化风险报告对象（推荐）…
B. 只返回自然语言分析…
C. 同时返回结构化结果和一份 Markdown 文本…
※ recap: 目标是设计合码阶段识别新旧版本混部兼容风险的 Skill…
```

## 3. 焦点判定（可行 ✅，两级推导；仅 Orca 应用内选中态）

CLI **不直接**给「当前聚焦终端」单字段。实测可行的两级旁路（与票 #2 的推断一致，并已真正跑通）：

**第一级** — 哪个 worktree 被选中：`orca worktree ps --json` 里 `isActive: true` 的 worktree。
- 实测结果：`isActive:true` 命中 `permission`（`/Users/…/GolandProjects/permission`），且全局唯一一个。

**第二级** — 该 worktree 里哪个 tab/pane 在前台：`orca terminal list --include-visual-layouts --json` 的 `visualLayouts[该worktree].root.activeTabId`，再在该 tab 的 `panes` 里取 `active:true` 的 `handle`。
- 实测结果：`activeTabId = 727b80b7-…`，对应 tab 标题 `Reviewing Group Policy Control Design… - grok`，`pane.active:true` → `handle = term_b3d92c31-…`。

**闭环验证**：对推导出的 focused handle 直接 `terminal read`，读到的正是该 Grok 会话的最新提问（"你选 A 还是 B？…普通管理端点命中 hidden 策略时…"），证明「焦点推导 → 内容读取」这条链路端到端打通。

⚠️ 边界：`isActive/activeTabId` 是 **Orca 应用内部的选中态**，不是 macOS 前台窗口。用户若切到 Orca 之外（浏览器/IDE），此信号仍指向 Orca 上次选中的终端。这与本效应「只管 Orca 内部焦点」的锁定约束一致。

## 4. 结构化 agent 状态 / cardStatus（部分可行 ⚠️，依赖 hook 覆盖）

- `worktree ps` 的 `agents[]` **只有被 status-hook 覆盖的会话才有值**：
  - 本快照里只有 **context** 仓返回了 `agents`（2 个：claude/codex，含 `state:"done"`、`agentType`、`prompt`、`lastAssistantMessage`）——这是最理想的结构化数据源。
  - **keep-attention 自身 `status:"working"` 但 `agents:[]`**（无 hook 覆盖）；permission 等同样为空。
- `orca terminal show --terminal <handle> --json` 无忙闲/cardStatus 字段，只回 `handle/ptyId/worktreeId/tabId/leafId/title/connected/writable/lastOutputAt/paneRuntimeId/rendererGraphEpoch`。
- 忙/闲的可用近似：worktree 级 `status`（working/active）、终端级 `status`（running）、`lastOutputAt` 时间戳新鲜度，以及 `orca terminal wait --for tui-idle --timeout-ms …` 这个**主动**探测。

---

## 数据路径建议（供票 #4 落锤）

- **焦点来源**：两级推导（`worktree ps.isActive` → `terminal list --include-visual-layouts` 的 `activeTabId`+`pane.active`）。无单字段，但稳定可跑通。降级：拿不到时回落到"最近 `lastOutputAt` 最新的终端"。
- **上下文来源**：
  - 首选 `worktree ps.agents[].lastAssistantMessage/state/prompt`（结构化，最干净）——**但仅 hook 覆盖的会话有**。
  - 兜底 `terminal read` 的渲染 `tail`（约 119 行上限，够"最近在干嘛"，不够完整回放）。
- **忙闲**：无 `cardStatus`；用 `status` + `lastOutputAt` 新鲜度近似，必要时 `terminal wait --for tui-idle` 主动判定。
- **总结后端**：DeepSeek（见票 #4/#3-deepseek）。
- **无法拿到 / 降级点**：① 完整对话历史（超 ~119 行丢弃）；② 全量结构化 agent 状态（无 hook 的会话拿不到，只能退化为渲染文本 + 关键词/spinner 启发式）；③ OS 级前台窗口焦点（本效应不做，明确 out of scope）。
