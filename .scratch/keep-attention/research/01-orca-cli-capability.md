# Orca CLI 能力核查：焦点信号与终端内容可读性（Issue #2）

- 核查对象：本机 Orca 公共 CLI，可执行文件 `/usr/local/bin/orca`（`ORCA_CLI_COMMAND` / `ORCA_DEV_REPO_ROOT` 均未设置，非 dev checkout，macOS）
- 一手来源：`orca skills get orca-cli`（版本匹配指南）、`orca --help` / 各子命令 `--help`、`orca agent-context --json`（机读命令 schema）、以及只读探针 `orca status/worktree ps/terminal list/show/read` 的真实 JSON 输出
- Orca 版本：`appVersion` 1.4.183（来自 `orca status --json`）
- 说明：所有 `orca` 调用都会先打印一行 `codesign_util.cc ... task_name_for_pid` stderr 噪声，不影响 JSON 结果

---

## 能力清单

### 1. 终端枚举：能列出所有 Orca 管理的终端/agent 会话

**结论：能，完整可用。** 两条互补命令：

- `orca terminal list --json`（可加 `--worktree <selector>` 限定，不加则跨所有 worktree）
  - 来源：`orca --help` Terminals 段 + 实测输出（本机返回 22 个终端，`truncated:false`）
  - 每个终端字段：`handle`（如 `term_039727ce-...`，后续操作用的稳定句柄）、`ptyId`、`incarnationId`、`orphaned`、`worktreeId`、`worktreePath`、`branch`、`tabId`、`leafId`、`title`、`connected`、`writable`、`lastOutputAt`（epoch ms）、`preview`（一段渲染后的屏幕文本快照）
  - 顶层还返回 `topologyRevisions`、`totalCount`、`truncated`
  - 注意：`terminal list` 本身**不含** per-terminal 的 agent 类型/agent 状态字段；`title` 常常间接反映（如 "grok"、"✳ 理解小流量发布兼容性问题"），但不是结构化 agentType
  - 加 `--include-visual-layouts` 会额外返回 `visualLayouts`（tab/pane 拓扑，见 Q2）

- `orca worktree ps --json`（"compact orchestration summary across worktrees"，来源 `orca --help` Worktrees 段）
  - 这是唯一把 **agent 会话结构化**列出的只读命令。每个 worktree 带一个 `agents[]` 数组，元素字段：`paneKey`（形如 `<tabId>:<leafId>`，与 terminal list 的 tabId/leafId 对应）、`parentPaneKey`、`state`、`agentType`（实测见 `claude`、`codex`）、`prompt`（用户最近一次输入）、`taskTitle`、`displayName`、`lastAssistantMessage`（agent 最近一条完整回复）、`toolName`、`toolInput`、`interrupted`（bool）、`stateStartedAt`、`updatedAt`
  - 每个 worktree 还带：`worktreeId`、`repo`、`path`、`branch`、`displayName`、`workspaceStatus`、`isActive`、`unread`、`hasHostSidebarActivity`、`liveTerminalCount`、`hasAttachedPty`、`lastOutputAt`、`lastActivityAt`、`preview`、`status`、`parentWorktreeId`/`childWorktreeIds`（lineage）
  - **限制**：`agents[]` 只对已安装 Orca 状态 hook 的 agent 才有内容；本机 11 个 worktree 里只有 `context` 那个 worktree 返回了 2 个 agent 对象，其余 worktree 的 `agents` 都是空数组 `[]`（即使终端里明显跑着 TUI agent）。原因见 Q4：结构化 agent 状态来自 per-agent 的 status hook，未被 hook 覆盖/未上报的会话不出现在 `agents[]` 里。

**小结**：终端级枚举（handle/title/worktree/连通性/最近输出时间）用 `terminal list` 完整可得；agent 级枚举（agentType/state/最近对话）用 `worktree ps`，但覆盖度取决于 hook 上报，非全量。

---

### 2. 当前聚焦终端：CLI 是否直接暴露"用户此刻聚焦在哪个终端/agent"

**结论：没有单一的顶层"focused terminal handle"字段；但可由两级信号推导出来。**

- `orca status --json` **不含**任何 focused/active 终端信息。它只返回 app（running/pid/`desktopWindowStatus`）、runtime（state/capabilities/version）、graph。来源：实测输出。`grep isActive|focused|hasFocus|foreground|attention` 在 status 与 `agent-context` schema 中均无命中。
- 推导路径（两级组合）：
  1. **哪个 worktree 是当前活跃的**：`orca worktree ps --json` 里每个 worktree 有 `isActive`（bool）。实测只有 `keep-attention` 那条为 `isActive:true`，其余为 `false`。另有 `unread`、`hasHostSidebarActivity` 作旁路信号。
  2. **该 worktree 内哪个 tab/pane 是活跃的**：`orca terminal list --include-visual-layouts --json` 的 `visualLayouts[].root` 里有 `activeTabId`，每个 tab 里有 `activeLeafId`，pane 节点上有 `"active": true`。实测 keep-attention 的 layout 给出 `activeTabId` + pane `handle=term_039727ce-... , active:true`。
  - 组合"`isActive:true` 的 worktree" + "其 layout 里 `active:true` 的 pane 的 handle" = 当前聚焦的终端 handle。
- **重要限制/告警**：
  - 这反映的是 **Orca 应用内部的选中状态**（哪个 worktree 被选中、每个 tab group 内最后聚焦的 pane），不是操作系统级窗口焦点。`status.app.desktopWindowStatus`（本机为 `available`）只说明桌面窗口可用，不代表 Orca 窗口此刻在最前台、用户真的盯着它。
  - `worktree current --json` 返回的是"当前 shell cwd 所在的 worktree"，其 `isActive` 字段实测为 `null`（该命令不填充 isActive）——所以判活跃 worktree 要用 `worktree ps` 的 `isActive`，不要用 `worktree current`。
  - 没有"用户在多个 worktree 间的全局唯一焦点"的直接布尔；`isActive` 单看语义是"活跃 worktree"，实测同一时刻只有一个为 true，可近似当作全局焦点 worktree。

**小结**：焦点信号"可得但需推导"，且是应用内选中态而非 OS 焦点。没有现成 `focused` 字段。

---

### 3. 终端内容读取：能读多完整

**结论：能读，但读到的是"渲染后的屏幕文本行缓冲"（bounded/retained lines），不是原始 PTY 字节流，也不是 agent 结构化对话。**

- 命令：`orca terminal read [--terminal <handle>] [--cursor <n>] [--limit <n>] --json`（来源 `orca terminal read --help`）
- 返回结构（实测）：`result.terminal` 含 `handle`、`status`（如 `running`）、`tail`（**字符串数组，逐行**）、`truncated`、`limited`、`oldestCursor`、`nextCursor`、`latestCursor`、`returnedLineCount`
- 内容形态：`tail` 里是 agent TUI/shell **渲染后的可见文本行**（含中文正文、`❯` 提示符、`auto mode on` 状态条等），已经是行级文本，不是带 ANSI 转义的原始 PTY 缓冲。因此能读到 agent 打印出来的对话正文，但读法是"看屏幕当前保留的若干行"，不是结构化的 message 列表。
- 长度/历史限制：
  - 默认调用只回最近可见窗口（本机实测 `returnedLineCount:39`）。
  - `--limit 1000 --cursor 0` 可回更多保留行（本机拿到 `returnedLineCount:119`，`latestCursor:119`，`limited:false`）——说明该终端总保留缓冲约 119 行。
  - `oldestCursor` 报告最老可用行；帮助文档明确"当更老的行被丢弃时会通过 oldestCursor 体现"，即**存在滚动丢弃上限**，不是无限历史。
  - 分页协议：先 `read` 拿 `nextCursor`，之后 `read --cursor <nextCursor>` 只取增量；长输出配合 `--limit` + `oldestCursor`/`nextCursor` 翻页。
- **结构化 agent 对话的另两条路（更"干净"但覆盖有限）**：
  1. `orca worktree ps --json` 的 `agents[].lastAssistantMessage` + `prompt` —— 直接拿到 agent 最近一条完整回复与用户最近输入，是结构化的（非屏幕文本）。**限制**：只有 hook 覆盖的 agent 有，且只有最近一条，不是完整历史。
  2. `orca orchestration worker-read --dispatch <id> [--source auto|transcript|terminal]` —— `--source transcript` 时返回"精确的 hook 上报 transcript"。**限制**：仅适用于被 orchestration 监督派发（dispatch）的 worker，不能对任意终端用；需要先有 Run/Dispatch。来源：`orchestration worker-read --help`。

**小结**：任意终端可读到"渲染后的可见文本行"（bounded、可游标翻页、有丢弃上限）；要拿"结构化 agent 对话"，只能靠 hook 覆盖的 `worktree ps` 最近一条消息，或 orchestration transcript（仅限被监督的 worker）。原始 PTY 字节缓冲 CLI 不暴露。

---

### 4. cardStatus / 元信息：是否有"忙 / 等待输入 / 已完成"的结构化状态

**结论：没有叫 `cardStatus` 的字段；但有两类结构化状态字段，分别表达"人工工作区状态"与"agent 生命周期状态"。**

- **工作区卡片状态（人工/流程语义，非 agent 忙闲）**：`workspaceStatus`，取值 `todo` / `in-progress` / `in-review` / `completed`（来源：orca-cli 指南 "Card status uses `--workspace-status <id>`; defaults are todo, in-progress, in-review, completed"）。这是人给 worktree 卡片打的进度标签，**不代表 agent 是否在跑**。
- **agent 生命周期状态（忙/等待/完成，结构化）**：`orca worktree ps --json` 的 `agents[].state` + `interrupted` + `stateStartedAt` + `updatedAt`。实测观察到 `state:"done"`；语义上还包含运行中/等待等（由 agent status hook 上报）。这是最接近"agent 在忙 / 等待输入 / 已完成"的字段，但**依赖 hook 覆盖**（见下）。
- **hook 来源可验证**：`orca agent hooks status --json` 显示状态 hook `enabled:true`，并列出 claude/codex/gemini/grok/cursor/copilot 等 `state:"installed"`, `managedHooksPresent:true`。即 agent 忙闲信号来自 Orca 往各 agent 配置里装的 status hook；未安装/未上报则 `worktree ps` 里不出现该 agent（解释了 Q1 里覆盖不全）。开关命令：`orca agent hooks on|off|status`。
- **终端级轻量状态**：`orca terminal read` 返回 `status`（实测 `running`）；`orca terminal wait --for tui-idle|exit --timeout-ms <ms>` 可用于"等到 TUI agent 空闲/终端退出"，即能主动探测 agent 由忙转闲。来源：`terminal wait --help` / 指南 Terminals 段。
- **orchestration 监督态（仅限被派发 worker）**：`worker-list` / `worker-show` 给出 `workerState`（如 `stopped`）、`dispatchStatus`（如 `failed`）、`terminalState`（`active|reclaimable|retained|release_pending|release_unknown|released`）；`task-list/update` 有 task `status`（`pending|ready|dispatched|completed|failed|blocked`）。这是最完整的忙/完成/失败结构化状态，但**只覆盖 orchestration Run 里被 dispatch 的 worker**，且很多命令需先 `orchestration run-create/run-use` 绑定 Run（实测裸跑 `task-list` 报 `run_required`）。

**小结**：结构化"agent 忙/等待/完成"存在于 `worktree ps` 的 `agents[].state`（hook 驱动，覆盖不全），完整版在 orchestration worker/task 状态（仅监督场景）；`workspaceStatus` 是人工卡片标签不等于 agent 忙闲；没有名为 `cardStatus` 的字段。

---

## 总结：焦点信号是否可得、上下文可读性如何

- **焦点信号：可得但需推导，且是"应用内选中态"而非 OS 窗口焦点。** 没有现成 `focused` 字段；组合 `worktree ps` 的 `isActive`（活跃 worktree）+ `terminal list --include-visual-layouts` 的 `activeTabId`/`activeLeafId`/pane `active:true`（worktree 内活跃 pane）可得到"当前聚焦终端 handle"。`status --json` 对焦点完全无信息。
- **上下文可读性：中等偏好。** 任意终端可通过 `terminal read` 读到"渲染后的可见文本行缓冲"（游标翻页、有保留行上限、非原始 PTY 字节、非结构化对话）；"结构化 agent 对话"仅能拿 hook 覆盖会话的最近一条（`worktree ps` 的 `lastAssistantMessage`/`prompt`），或 orchestration 监督 worker 的精确 transcript。要做"灵动岛式 Orca 状态感知"，焦点+忙闲+最近对话三要素都能拿到，但都有覆盖/精度限制，需要 hook 已安装（本机已 enabled）并接受"屏幕文本级"而非"完整对话历史"的读取粒度。
