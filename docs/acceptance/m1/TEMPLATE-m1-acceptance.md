# M1 验收报告模板（TEMPLATE-m1-acceptance）

> 票据：[#35](https://github.com/Concentration-point/keep-attention/issues/35)
> 用法：复制本文件为 `docs/acceptance/m1/<YYYY-MM-DD>-m1-acceptance.md`，逐项填写。
> 规则：没有真实候选构建与齐全证据时，**verdict 一律保持 `blocked`，禁止改判 `pass`**。
> 场景定义见同目录 [`SCENARIOS-m1.md`](./SCENARIOS-m1.md)（8 个端到端场景，含步骤与证据要求）。

## 0. Verdict 定义

| Verdict | 定义 |
| --- | --- |
| `pass` | 该项在真实候选构建（`scripts/make-app.sh` 产物或 release 二进制）上按步骤人工执行，期望结果全部满足，且证据已留存（截图 / 日志 / CLI 输出记录）。 |
| `fail` | 真实执行时期望结果不满足；必须记录偏差、复现步骤与最小修复建议。 |
| `blocked` | 缺少真实验证环境（真实 Orca runtime、真实 TraeX、真实 GUI 会话）或证据未采集，无法判定。**默认值。** |
| `preview-only` | 仅通过 `M1_PREVIEW=1` 演示投影验证（演示数据，不接真实信号）。只证明呈现层行为，不构成端到端 pass 证据。 |

## ⚠️ 不可替代声明（必须保留在本报告中）

`swift run keep-attention-tests` 只覆盖确定性纯逻辑（reducer、adapter 映射、投影、排序、escalation 判定、jump 路由决策）。以下检查**不能**被它替代，也不能被 `swift test` 替代：

- 真实 GUI / macOS：`NSPanel` 浮层渲染、窗口层级、拖拽、菜单栏行为；
- 真实 TraeX：hook 是否被真实 TraeX 进程加载、事件是否到达 socket、session 区分；
- 真实 Orca：runtime / CLI 进程存在、supervised 信号、`terminal switch` 与焦点结果；
- 通知：macOS 通知权限申请、真实投递、声音、系统 Reduce Motion 联动。

`M1_PREVIEW=1` 使用演示投影、不接入真实事件主循环，其结果最多记 `preview-only`。

---

## 1. 候选构建信息

| 项 | 值 |
| --- | --- |
| 报告日期 | `<YYYY-MM-DD>` |
| 候选构建 commit | `<commit sha>`（工作区是否干净：`<是/否，列出未提交项>`） |
| 构建产物 | `<scripts/make-app.sh 产物路径 / .build/.../release/keep-attention>` |
| 构建命令与输出摘要 | `<swift build -c release / make-app.sh 输出关键行>` |
| 运行环境 | `<macOS 版本, 机器, Orca 版本, TraeX 版本>` |
| 执行人 | `<name/agent>` |

## 2. 自动化检查（已知事实，随候选刷新）

| 检查 | 命令 | 结果 | 备注 |
| --- | --- | --- | --- |
| 单元测试 | `swift run keep-attention-tests` | `<N tests / M suites, pass/fail>` | 项目规定不用 `swift test` 作结论 |
| Debug 构建 | `swift build` | `<pass/fail>` | |
| Release 构建 / 打包 | `scripts/make-app.sh` | `<pass/fail>` | |

> 注意：自动化全绿**只是** M1 验收的必要条件，不是充分条件；真实环境栏未全部 `pass` 前，总 verdict 不得为 `pass`。

## 3. 端到端场景矩阵结果

场景定义与步骤见 [`SCENARIOS-m1.md`](./SCENARIOS-m1.md)。

| 场景 | 名称 | 覆盖票据 | 结果 | 证据 |
| --- | --- | --- | --- | --- |
| S1 | TraeX 权限请求进入队列并闭环 | #29, #31, #32 | `<pass/fail/blocked>` | `<链接>` |
| S2 | TraeX 问题生命周期 | #29, #31, #32 | `<...>` | `<链接>` |
| S3 | TraeX 重启/边界缺失降级 stale | #29, #31, #32 | `<...>` | `<链接>` |
| S4 | Orca supervised blocked/needsReview | #29, #30, #32 | `<...>` | `<链接>` |
| S5 | Orca question/decisionGate 闭环 | #29, #30, #32 | `<...>` | `<链接>` |
| S6 | 全局排序与收起/展开呈现 + Ambient | #29, #32 | `<...>`（呈现子项可 `preview-only`） | `<链接>` |
| S7 | 中断升级与通知控制 | #34 | `<...>` | `<链接>` |
| S8 | Session-aware Jump 与 fail-closed | #33, #32 | `<...>` | `<链接>` |

## 4. 分类 Checklist

### 4.1 自动化检查

- [ ] `swift run keep-attention-tests` 全绿（记录 `<N tests / M suites>`）
- [ ] `swift build` 通过
- [ ] `scripts/make-app.sh` 打包成功且 `LSUIElement=true`

### 4.2 真实 TraeX

- [ ] `.trae/hooks.json` 被真实 TraeX 加载（日志证据）
- [ ] `UserPromptSubmit` / `Stop` / permission 类事件真实到达 socket
- [ ] 同目录多会话 / 重启可区分（session/turn 键生效，S3）

### 4.3 真实 Orca

- [ ] Orca runtime 在线时 `agents[]` / supervised 信号可观察（S4, S5）
- [ ] Orca 离线时 UI 不崩溃、显示不可用态
- [ ] `orca terminal switch` 真实执行与焦点结果符合 S8 预期

### 4.4 GUI / macOS

- [ ] 菜单栏 pill、展开浮层、request card、Evidence drawer、Ambient 区真实渲染（S6）
- [ ] 收起/展开、Snoozed / Ambient 折叠交互真实可用
- [ ] 未配置 `DEEPSEEK_API_KEY` 时显示"未配置 API Key"，不外发

### 4.5 通知

- [ ] macOS 通知权限申请与真实投递（S7 步骤 1）
- [ ] 通知声音开关生效
- [ ] 升级节流（60s 短窗 / 每义务至多一次 / stale 15 分钟窗）真实行为符合判定逻辑
- [ ] mute workspace 与 AI opt-in 双满足规则生效（S7 步骤 4, 7）

### 4.6 Reduce Motion

- [ ] 动效偏好（跟随系统 / 始终降低 / 完整）设置持久化并真实影响动画
- [ ] 状态变化在无动画时仍可读（不依赖动画区分 request / ambient / stale / coverage gap / escalation）

### 4.7 Release verdict

- [ ] 候选构建信息（第 1 节）完整
- [ ] 8 个场景结果均已填写且证据链接有效
- [ ] 总 verdict 按"最保守原则"汇总：任一场景非 `pass`（且非纯 `preview-only` 子项）→ 总 verdict 不得为 `pass`

## 5. 总 Verdict

**Verdict: `<pass / fail / blocked>`**

理由（≤5 句）：`<...>`

## 6. 遗留风险与下一步

- `<风险 / 缺口 / 建议后续票据>`

## 7. Sign-off

| 角色 | 名称 | 日期 | 结论 |
| --- | --- | --- | --- |
| 执行者 | `<...>` | `<YYYY-MM-DD>` | `<...>` |
| 审核（主 agent / 维护者） | `<...>` | `<YYYY-MM-DD>` | `<...>` |
