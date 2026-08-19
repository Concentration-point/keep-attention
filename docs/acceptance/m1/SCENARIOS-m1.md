# M1 端到端场景矩阵（Scenario Matrix）

> 所属票据：[#35](https://github.com/Concentration-point/keep-attention/issues/35)
> 适用范围：M1（Orca + TraeX）验收。本文件定义 8 个端到端场景，是
> `TEMPLATE-m1-acceptance.md` 与候选报告的共用场景来源。
> 维护规则：场景增删须回溯到 M1 loop 与 PRODUCT.md 的数据边界，不接受"实现方便"驱动的场景裁剪。

## M1 loop 参考

PRODUCT.md 定义的 M1 循环：

```
identify Attention Request → sort globally → explain reason and needed action
→ jump back to Orca → auto-leave queue from structured resolved evidence
```

五个环节缩写：**发现**（identify）/ **排序**（sort）/ **解释**（explain）/ **返回**（jump back）/ **闭环**（auto-leave）。

## 状态标记定义

| 标记 | 含义 |
| --- | --- |
| `pass` | 在真实候选构建（`scripts/make-app.sh` 产物或 release 二进制）上按步骤人工执行，期望结果全部满足，且已留存证据（截图 / 日志 / CLI 输出记录）。 |
| `fail` | 在真实候选构建上执行时期望结果不满足；必须记录偏差、复现步骤与最小修复建议。 |
| `blocked` | 缺少真实验证环境（真实 Orca runtime、真实 TraeX、真实 GUI 会话）或证据未采集，无法判定 pass / fail。**这是当前所有真实环境场景的默认状态。** |
| `preview-only` | 仅通过 `M1_PREVIEW=1` 演示投影验证了 UI 呈现逻辑（演示数据，不接真实信号）。只能证明呈现层行为，**不能**作为端到端 pass 证据。 |

## ⚠️ 不可替代声明

`swift run keep-attention-tests`（当前 173 tests / 18 suites）只覆盖确定性纯逻辑：reducer、adapter 映射、投影文案、排序、escalation 判定、jump 路由决策等。它**不能**替代真实 GUI / Orca / TraeX 检查，因为单测环境里：

- 没有真实 `NSPanel` 浮层渲染、窗口层级与拖拽行为；
- 没有真实 macOS 通知权限申请、投递与声音播放；
- 没有真实 Orca runtime / CLI 进程（`orca status`、supervised orchestration、`terminal switch`）；
- 没有真实 TraeX hook 进程加载 `.trae/hooks.json` 并触发事件；
- 没有真实操作系统焦点切换，无法验证 jump 后的可见结果。

`M1_PREVIEW=1` 同样不接入真实事件主循环（README 已注明），preview 结果只能记 `preview-only`。

## 场景总表

| ID | 场景 | 覆盖票据 | M1 loop 环节 | 主要信号源 | 当前状态 |
| --- | --- | --- | --- | --- | --- |
| S1 | TraeX 权限请求进入队列并闭环 | #29, #31, #32 | 发现→排序→解释→闭环 | TraeX structuredHook `PermissionRequest` / tool result | blocked |
| S2 | TraeX 问题（question）生命周期 | #29, #31, #32 | 发现→解释→闭环 | TraeX structuredHook question opened / answered / failed | blocked |
| S3 | TraeX 会话重启 / 起始边界缺失降级 stale | #29, #31, #32 | 发现→闭环 | `SessionStart` 边界缺失、restart 检测 | blocked |
| S4 | Orca supervised workflow 阻塞 / 需审查 | #29, #30, #32 | 发现→排序→解释→闭环 | Orca `blocked` / `needsReview` 及 resolve 信号 | blocked |
| S5 | Orca question / decisionGate 请求闭环 | #29, #30, #32 | 发现→解释→闭环 | Orca `question` / `decisionGate` / `reply` / `gate-resolved` | blocked |
| S6 | 全局排序、收起/展开呈现与 Ambient 兜底 | #29, #32 | 排序→解释 | 混合信号源 + Ambient 概览 | blocked（呈现层可 preview-only） |
| S7 | 中断升级与通知控制 | #34 | 发现→排序 | EscalationPolicy + WorkspaceControls | blocked |
| S8 | Session-aware Jump 返回与 fail-closed | #33, #32 | 解释→返回 | Orca 快照复验 + `terminal switch` | blocked |

---

## S1 TraeX 权限请求进入队列并闭环

**覆盖**：#29（域内核）、#31（TraeX adapter）、#32（投影呈现）。

**前置条件**：

- 候选构建（`scripts/make-app.sh` 产物）已启动，Orca 正在运行。
- 项目级 `.trae/hooks.json` 已按 README 配置（`keep-attention-hook` + `.trae/keep-attention.env` 指向本机 app 与 socket）。
- 一个真实 TraeX 会话即将触发需要权限确认的工具调用（如 Bash 执行）。

**步骤**：

1. 在 TraeX 中触发一次需要 permission 的工具调用。
2. 观察 keep-attention 浮层：收起 pill 与展开队列应出现 `permissionRequired` 请求，状态 `unseen`。
3. 展开该 request card：原因、所需动作、来源（structuredHook）与时间应可读，无原始 hook payload 泄露。
4. 在 TraeX 侧批准 / 拒绝该工具调用，让工具产生结果事件。
5. 回到浮层：该请求应凭结构化 resolve 证据自动出队列（`Seen` 不等于 resolved）。

**期望结果**：步骤 2/3/5 全部满足；请求只能由结构化 tool 结果闭环，不因阅读或切换焦点而消失。

**自动化覆盖（已知事实）**：`AttentionRequestCoreTests`、`TraeXAttentionAdapter` 相关测试覆盖 reducer 与事件映射纯逻辑；真实 hook 进程加载与 GUI 呈现不在其中。

**真实环境状态**：blocked —— 真实 TraeX hook 是否被加载、事件是否到达、GUI 是否呈现，均待真机验证。

**证据要求**：hook 日志片段（脱敏）、浮层截图（请求在场与出队列各一张）。

---

## S2 TraeX 问题（question）生命周期

**覆盖**：#29、#31、#32。

**前置条件**：同 S1；TraeX 会话进入需要用户回答的轮次（Plan-mode question 类）。

**步骤**：

1. 触发 TraeX question 事件。
2. 浮层出现 `userAnswerRequired` 请求，card 解释"需要回答什么"。
3. 用户回答后（question answered），请求凭结构化证据闭环。
4. 若该轮失败（question failed），请求按失败语义处理（不静默消失，状态可追溯）。

**期望结果**：question 开启 / 回答 / 失败三种生命周期事件都正确驱动队列，无悬挂请求。

**自动化覆盖（已知事实）**：`traeXQuestionOpened` / `traeXQuestionAnswered` / `traeXQuestionFailed` 的 reducer 路径已有单测。

**真实环境状态**：blocked。

**证据要求**：事件日志 + 队列状态截图。

---

## S3 TraeX 会话重启 / 起始边界缺失降级 stale

**覆盖**：#29、#31、#32。

**前置条件**：同 S1；存在一个有未闭环请求的 TraeX 会话。

**步骤**：

1. 制造会话重启或缺失 `SessionStart` 边界（新会话 ID 复用同一目录）。
2. 浮层中该会话的历史请求应降级为 `stale`，进入低频 stale 历史，不参与抢占排序。
3. stale 请求不应再触发新的强升级通知（配合 S7）。
4. 用户可对 stale 项执行 Dismiss stale（见 #34 操作）。

**期望结果**：stale 降级及时、低调、可追溯；不冒充活跃请求。

**自动化覆盖（已知事实）**：`markStale` / `markStaleAfterRestart` / `startBoundaryMissing` 发现语义已有单测。

**真实环境状态**：blocked。

**证据要求**：重启前后队列对比截图 + 日志。

---

## S4 Orca supervised workflow 阻塞 / 需审查

**覆盖**：#29、#30、#32。

**前置条件**：候选构建运行中；Orca 内有一个 supervised orchestration worker 会进入 `blocked`（如 permission）或 `needsReview` 状态。

**步骤**：

1. 让 Orca dispatch 的 worker 进入 blocked / needs-review。
2. 浮层出现 `userActionRequired` / `reviewRequired` 请求（supervisedWorkflow 置信度）。
3. 在 Orca 侧解除阻塞（reply / continue / worker_done）。
4. 请求凭结构化 resolve 证据自动出队列。

**期望结果**：Orca 侧阻塞与解除均同步反映；无人工手动清理。

**自动化覆盖（已知事实）**：`OrcaAttentionAdapterTests` 覆盖 `blocked` / `needsReview` / `continued` / `workerDone` 信号映射；真实 Orca runtime 轮询链路未接入。

**真实环境状态**：blocked —— adapter 未接入 Poller 主循环，真实 Orca 事件→UI 链路待验证。

**证据要求**：`orca orchestration` 相关 CLI 输出（脱敏）+ 浮层截图。

---

## S5 Orca question / decisionGate 请求闭环

**覆盖**：#29、#30、#32。

**前置条件**：同 S4；Orca dispatch 流程会产生 `question` 或 `decision_gate`。

**步骤**：

1. 触发 Orca question / decisionGate。
2. 浮层出现 `userAnswerRequired` 请求并解释来源。
3. 通过 `reply` / `gate-resolve` 回答。
4. 请求自动闭环。

**期望结果**：question 与 decisionGate 两种入口行为一致，回复即闭环。

**自动化覆盖（已知事实）**：`question` / `decisionGate` / `reply` / `gateResolved` 信号映射已有单测。

**真实环境状态**：blocked。

**证据要求**：同 S4。

---

## S6 全局排序、收起/展开呈现与 Ambient 兜底

**覆盖**：#29、#32（含 AmbientOverview）。

**前置条件**：候选构建运行中；可同时制造多个不同来源 / 类型 / 状态的请求（复用 S1–S5 手段），以及一个无请求的安静时段。

**步骤**：

1. 同时存在多个请求时，收起 pill 只显示排序后的队首请求 + 数量徽标。
2. 展开态按全局排序呈现队列（kind 优先级：`permissionRequired` > `userAnswerRequired` > `userActionRequired` / `reviewRequired` > `stateNeedsConfirmation`；同 kind 内 unseen/snoozed 优先于 seen，再按时间），顺序稳定不跳动。
3. 已 Snooze 请求进入 snoozed 折叠区，到期后回队。
4. 无任何请求时，浮层呈现 Ambient 概览（活跃会话、workspace、coverage gap），不索取注意。
5. 检查收起/展开、snoozed/stale 折叠动画在 Reduce Motion 偏好下可读（配合通知与动效场景）。

**期望结果**：排序、折叠、Ambient 兜底全部符合 PRODUCT.md 的"常驻但克制"要求；状态变化不依赖动画也可读。

**自动化覆盖（已知事实）**：`GlobalAttentionQueueSorter`、`AttentionQueueProjectionTests`、`AmbientOverviewTests` 覆盖排序与投影纯逻辑；`M1_PREVIEW=1` 可用演示投影人工检查呈现层（记 `preview-only`）。

**真实环境状态**：blocked（真实多源信号驱动版本待验证）；呈现子项可先记 `preview-only`。

**证据要求**：多请求并发截图、安静态 Ambient 截图、preview 运行说明。

---

## S7 中断升级与通知控制

**覆盖**：#34（承接 #20）。

**前置条件**：候选构建运行中；macOS 通知权限可交互；设置面板（齿轮）可打开。

**步骤**：

1. 制造高置信来源（structuredHook / supervisedWorkflow）的强阻塞 unseen 请求（permission / question）：应触发一次升级通知；同一义务重复出现不得二次升级（`escalationCount` / `lastEscalatedAt`）。
2. 对请求执行 Seen：不再升级。
3. 对请求执行 Snooze（5 分钟 / 15 分钟 / 1 小时）：到期前不升级、不抢占。
4. 将某 workspace 设为 mute：该 repo 的请求一律不升级。
5. 验证全局 60 秒短窗节流；stale 请求默认低调，仅原强阻塞 stale 可发一次低频 uncertain 通知（15 分钟节流窗）。
6. 验证通知声音开关、动效偏好（跟随系统 / 始终降低 / 完整）、清除本地历史（清空已关闭历史、保留进行中义务）、AI 摘要 opt-in（需 `DEEPSEEK_API_KEY` + workspace 显式 opt-in 双满足）设置项持久化（`notificationControls.v1`）。
7. 开启 AI 摘要 opt-in 后核对白名单最小外发片段：repo/branch 脱敏、kind 标签、确定性文案、安全事件标签、总长 ≤1200 字符；不含 session id、路径、标题或原始 hook payload。

**期望结果**：升级判定低误报、可抑制、可审计；设置持久化重启后保留；AI 外发严格遵守白名单。

**自动化覆盖（已知事实）**：`EscalationPolicyTests`、`WorkspaceControlsTests` 覆盖判定与白名单纯逻辑；macOS 通知权限 / 真实投递 / 声音 / Reduce Motion 系统联动不在其中。

**真实环境状态**：blocked —— README 已注明需真实运行环境人工验证。

**证据要求**：通知中心截图、设置面板截图、（若测 AI）外发 payload 脱敏记录。

---

## S8 Session-aware Jump 返回与 fail-closed

**覆盖**：#33（SessionAwareJump）+ #32（RequestActionsView 接线）。

**前置条件**：候选构建运行中；队列中存在可 Jump 的请求；目标 Orca terminal 仍在当前 runtime 承载下。

**步骤**：

1. 点击 request card 的 Jump。
2. 应用应即时重拉 Orca 快照、按 pane 选择器（worktree / tab / leaf）复验路由，而非盲信缓存 handle。
3. 复验一致才调用 `orca terminal switch --terminal <handle> --json`；切换后用最新 layout 验证目标 tab / pane 是否 active。
4. 正常路径：用户被带回正确 Orca 终端，浮层给出成功 / 不确定状态文案。
5. 故障路径 A：目标 terminal 已重启 / handle 失效 —— 应拒绝跳转（fail-closed），给出可恢复文案，不声称成功。
6. 故障路径 B：切换后验证不匹配 —— 报告失败并可重试（至多 1 次重试），frontmost 层级固定 `.unsupported`，永不声称取得操作系统前台焦点。

**期望结果**：成功路径可验证；所有失败路径 fail-closed 且文案不惊吓、可恢复。

**自动化覆盖（已知事实）**：`SessionAwareJumpTests` 覆盖路由解析与验证决策纯逻辑；真实 `orca terminal switch` 执行、焦点切换与 macOS frontmost 行为不在其中（源码注释已声明该缺口）。

**真实环境状态**：blocked。

**证据要求**：跳转前后终端状态截图 / CLI 输出、故障注入说明。

---

## 场景与票据覆盖核对

| 票据 | 交付物（纯 core/adapter/UI，未接 runtime） | 覆盖场景 |
| --- | --- | --- |
| #29 | `AttentionRequestCore`（reducer、`GlobalAttentionQueueSorter`、持久化、escalation 字段） | S1–S6 |
| #30 | `OrcaAttentionAdapter`（supervised 信号 → 事件 + Ambient） | S4, S5, S6 |
| #31 | `TraeXAttentionAdapter`（hook 事件映射、session 发现、restart 降级） | S1–S3 |
| #32 | `AttentionQueueProjection` + request-centric UI（`M1_PREVIEW=1` 演示投影） | S1–S6, S8 |
| #33 | `SessionAwareJump`（fail-closed 导航 + 验证） | S8 |
| #34 | `EscalationPolicy` + `WorkspaceControls` + 通知控制 UI / request 操作 | S3, S6, S7 |
