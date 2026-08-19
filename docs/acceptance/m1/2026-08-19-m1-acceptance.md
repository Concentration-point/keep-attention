# M1 验收候选报告（2026-08-19）

> 由模板 [`TEMPLATE-m1-acceptance.md`](./TEMPLATE-m1-acceptance.md) 生成；场景见 [`SCENARIOS-m1.md`](./SCENARIOS-m1.md)。
> 票据：[#35](https://github.com/Concentration-point/keep-attention/issues/35)
> **当前 verdict：`blocked` —— 尚无真实候选构建证据，真实 GUI / Orca / TraeX 验证全部未做。**

## ⚠️ 不可替代声明

`swift run keep-attention-tests`（本报告记录的 173 tests / 18 suites）只覆盖确定性纯逻辑（reducer、adapter 映射、投影、排序、escalation 判定、jump 路由决策）。真实 GUI / 真实 Orca runtime / 真实 TraeX hook 检查**不能**被它（也不能被 `swift test`）替代。`M1_PREVIEW=1` 使用演示投影、不接真实事件主循环，其结果最多记 `preview-only`。详见模板与场景矩阵中的声明。

## 0. Verdict 定义

| Verdict | 定义 |
| --- | --- |
| `pass` | 在真实候选构建上按步骤人工执行，期望结果全部满足，且证据已留存。 |
| `fail` | 真实执行时期望结果不满足；记录偏差与复现。 |
| `blocked` | 缺少真实验证环境或证据未采集，无法判定。**本报告默认且当前生效。** |
| `preview-only` | 仅 `M1_PREVIEW=1` 演示投影验证；不构成端到端 pass 证据。 |

## 1. 候选构建信息

| 项 | 值 |
| --- | --- |
| 报告日期 | 2026-08-19 |
| 候选构建 commit | 待填 —— 工作区基于 `e76d328`，但 #29~#34 大部分实现仍在未提交文件中；尚无正式候选构建 |
| 构建产物 | 待填 |
| 构建命令与输出摘要 | 待填 |
| 运行环境 | 待填（需记录 macOS / Orca / TraeX 版本） |
| 执行人 | 待填 |

## 2. 自动化检查（已知事实）

| 检查 | 命令 | 结果 | 备注 |
| --- | --- | --- | --- |
| 单元测试 | `swift run keep-attention-tests` | **173 tests / 18 suites，全部通过**（2026-08-19；主 agent 复核，本 worker 复跑确认末行 `Test run with 173 tests in 18 suites passed`） | 项目规定不用 `swift test` 作结论 |
| Debug 构建 | `swift build` | 待填（候选构建时刷新） | |
| Release 构建 / 打包 | `scripts/make-app.sh` | 待填 | |

> 已知事实的范围：#29~#34 均为纯 core / adapter / UI 实现，**未接入真实 runtime 主循环**。单测覆盖 `AttentionRequestCore`、`OrcaAttentionAdapter`、`TraeXAttentionAdapter`、`AttentionQueueProjection`、`AmbientOverview`、`SessionAwareJump`、`EscalationPolicy`、`WorkspaceControls` 等确定性逻辑。自动化全绿是 M1 验收的必要条件而非充分条件。

## 3. 端到端场景矩阵结果

场景定义与步骤见 [`SCENARIOS-m1.md`](./SCENARIOS-m1.md)。

| 场景 | 名称 | 覆盖票据 | 结果 | 证据 |
| --- | --- | --- | --- | --- |
| S1 | TraeX 权限请求进入队列并闭环 | #29, #31, #32 | blocked（待填） | 待填 |
| S2 | TraeX 问题生命周期 | #29, #31, #32 | blocked（待填） | 待填 |
| S3 | TraeX 重启/边界缺失降级 stale | #29, #31, #32 | blocked（待填） | 待填 |
| S4 | Orca supervised blocked/needsReview | #29, #30, #32 | blocked（待填，adapter 未接 Poller） | 待填 |
| S5 | Orca question/decisionGate 闭环 | #29, #30, #32 | blocked（待填，同上） | 待填 |
| S6 | 全局排序与收起/展开呈现 + Ambient | #29, #32 | blocked；呈现子项待真实验证（`M1_PREVIEW=1` 人工检查可先记 `preview-only`，不构成 pass） | 待填 |
| S7 | 中断升级与通知控制 | #34 | blocked（待填；通知权限/投递/声音/Reduce Motion 联动需真机） | 待填 |
| S8 | Session-aware Jump 与 fail-closed | #33, #32 | blocked（待填；真实 `terminal switch` 与焦点结果未验证） | 待填 |

## 4. 分类 Checklist

### 4.1 自动化检查

- [x] `swift run keep-attention-tests` 全绿（173 tests / 18 suites，2026-08-19）
- [ ] `swift build` 通过（候选构建时刷新）
- [ ] `scripts/make-app.sh` 打包成功且 `LSUIElement=true`

### 4.2 真实 TraeX

- [ ] `.trae/hooks.json` 被真实 TraeX 加载（日志证据）
- [ ] `UserPromptSubmit` / `Stop` / permission 类事件真实到达 socket
- [ ] 同目录多会话 / 重启可区分（S3）

### 4.3 真实 Orca

- [ ] Orca runtime 在线时 `agents[]` / supervised 信号可观察（S4, S5）
- [ ] Orca 离线时 UI 不崩溃、显示不可用态
- [ ] `orca terminal switch` 真实执行与焦点结果符合 S8 预期

### 4.4 GUI / macOS

- [ ] 菜单栏 pill、展开浮层、request card、Evidence drawer、Ambient 区真实渲染（S6）
- [ ] 收起/展开、Snoozed / Ambient 折叠交互真实可用
- [ ] 未配置 `DEEPSEEK_API_KEY` 时显示"未配置 API Key"，不外发

### 4.5 通知

- [ ] macOS 通知权限申请与真实投递（S7）
- [ ] 通知声音开关生效
- [ ] 升级节流（60s 短窗 / 每义务至多一次 / stale 15 分钟窗）真实行为符合判定逻辑
- [ ] mute workspace 与 AI opt-in 双满足规则生效（含白名单最小外发片段 ≤1200 字符、fail-open 回退）

### 4.6 Reduce Motion

- [ ] 动效偏好（跟随系统 / 始终降低 / 完整）设置持久化并真实影响动画
- [ ] 状态变化在无动画时仍可读

### 4.7 Release verdict

- [ ] 候选构建信息（第 1 节）完整
- [ ] 8 个场景结果均已填写且证据链接有效
- [ ] 总 verdict 按最保守原则汇总

## 5. 总 Verdict

**Verdict: `blocked`**

理由：#29~#34 的自动化检查全绿（173 tests / 18 suites），但均为纯 core / adapter / UI 且未接入真实 runtime；8 个端到端场景所需的真实 GUI、真实 Orca、真实 TraeX 验证与证据采集均未执行，候选构建信息亦未填。在上述证据补齐之前，M1 不得判为 `pass`。

## 6. 遗留风险与下一步

1. 生成正式候选构建（提交 #29~#34 实现 → `scripts/make-app.sh`），填写第 1 节。
2. 按场景矩阵 S1–S8 在真机采集证据（hook 日志、通知截图、Orca CLI 输出、跳转前后状态）。
3. S6 呈现层可先用 `M1_PREVIEW=1` 做 preview-only 人工检查，但不得计入 pass。
4. S8 的 frontmost 层级当前实现固定 `.unsupported`（源码声明缺口）；若验收要求真实焦点确认，需另行票据。
5. `TraeXAttentionAdapter` / `OrcaAttentionAdapter` 接入 Poller 主循环属于后续票据，不在本验收包范围内。

## 7. Sign-off

| 角色 | 名称 | 日期 | 结论 |
| --- | --- | --- | --- |
| 执行者 | keep-attention #35 worker（模板与骨架生成） | 2026-08-19 | 产出模板 + 候选骨架；真实验证待做 |
| 审核（主 agent / 维护者） | 待填 | 待填 | 待填 |
