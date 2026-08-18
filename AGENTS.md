# keep-attention Agent 工作规则

本文是本项目的项目级 agent 指南。用户指定“主 agent”时，主 agent 必须先读取本文，再按本文的主从协作方式工作。

## 核心原则

- 默认中文沟通；代码符号、命令、路径保持原文。
- 一个任务只能有一个主 agent 负责规划、取舍、对用户沟通和最终审核。
- 从 agent 只执行被明确派发的局部任务，不自行扩大范围、不直接替主 agent 做产品决策。
- 主 agent 通过 Orca CLI 派发、跟踪、回收从 agent 的工作；不要用临时口头约定替代可审计的 Orca 通信。
- 先定义成功标准，再执行；每个结论都要能回到代码、测试、日志或明确的人工验证步骤。
- 保持改动外科手术式：只改和当前任务直接相关的文件；不要顺手重构、格式化或回滚他人未提交改动。

## 主 agent 职责

主 agent 是唯一的协调者和 reviewer，必须负责：

1. 读取本文件、用户最新指令、README、相关 handoff / spec / plan，再开始分工。
2. 明确任务目标、非目标、约束、验收标准和风险；存在多种解释时先说清取舍。
3. 将任务拆成边界清晰的子任务，给每个从 agent 指定：
   - 目标与背景；
   - 可写文件范围；
   - 禁止触碰的文件或行为；
   - 必须运行或说明无法运行的验证；
   - 交付格式。
4. 维护主线决策：产品体验、架构边界、测试策略、是否接受 worker 方案，最终都由主 agent 判定。
5. 审核所有从 agent 的产物：阅读 diff、确认没有越界修改、补跑必要验证、要求返工直到满足验收标准。
6. 面向用户输出最终结论，清楚区分：
   - 已实际修改的文件；
   - 已实际运行并通过/失败的验证；
   - 仍需人工 GUI 或真实运行环境验证的部分；
   - 未解决风险和下一步建议。

## 从 agent 职责

从 agent 是执行者，不是最终决策者。默认要求：

- 只处理主 agent 派发的局部任务和指定写入范围。
- 不擅自重构无关代码、不扩大需求、不删除 `.scratch/`、不回滚其他未提交改动。
- 遇到需求冲突、权限问题、测试环境问题或需要产品取舍时，回报主 agent，不直接问用户。
- 长任务约每 5 分钟通过 Orca 通信发送一次 heartbeat，说明当前进度和阻塞点。
- 完成时只发送一次 `worker_done`，包含：
  - `verdict`：done / blocked / needs-review；
  - `files-modified`：修改过的文件列表；
  - `tests`：运行过的验证命令和结果；未运行要说明原因；
  - `summary`：最多 3 句话说明做了什么、为什么、剩余风险。

## Orca CLI 派工规范

当需要外部 agent、Grok CLI、子 worktree、Orca terminal 或 handoff 时，主 agent 必须使用 Orca CLI，而不是临时 PTY 或裸 shell 代替。

1. 先按当前环境解析 Orca 命令：
   - 若设置了 `ORCA_CLI_COMMAND`，使用它；
   - 若处于 Orca dev checkout 且有 `ORCA_DEV_REPO_ROOT`，使用 `orca-dev`；
   - Linux 非 Orca terminal 使用 `orca-ide`；
   - 其他 macOS / Orca terminal 场景使用 `orca`。
2. 第一次执行前读取版本匹配指南：
   - `ORCA skills get orca-cli`
   - 不要凭旧记忆猜 Orca 子命令或 flags。
3. 优先使用 `--json` 输出，便于审计和恢复。
4. 派工 prompt 必须包含：
   - 本项目路径：`/Users/bytedance/orca/keep-attention`；
   - worker 身份与边界；
   - 明确的可写文件范围；
   - 验证命令；
   - `worker_done` 交付格式；
   - “不要直接问用户，问题回给主 agent”的约束。
5. 主 agent 不把最终判断外包给 worker；worker 返回后必须做独立 review。

## 本项目特定规则

### 产品方向

- keep-attention 的目标是让用户快速理解 Orca / TraeX 中活跃终端或 agent “现在在做什么、下一步是什么、上下文是什么”。
- 优先采集结构化信号：Orca `agents[]`、TraeX hooks、明确的 agent 输出事件。
- 不要把 terminal tail / 滚动文本猜测作为默认方案；除非用户明确接受 fallback，并且 UI 文案要标明置信度。
- 参考外部项目（例如 `open-vibe-island`）时，只参考产品思路和架构模式；不要复制 GPL 代码实现。

### 构建与验证

- 这是 Swift / SwiftUI macOS 项目，测试必须使用：

```sh
swift run keep-attention-tests
```

- 不要用 `swift test` 作为本项目测试结论。
- 常用静态/构建验证：

```sh
swift build
scripts/make-app.sh
```

- 若 SwiftPM 在沙箱内出现 `sandbox-exec: sandbox_apply: Operation not permitted`，需要按当前环境的审批规则用 escalated command 重跑，并在最终报告里说明这是本地验证。
- GUI 行为、菜单栏浮层、真实 TraeX hook 是否被加载，必须明确标为人工或真实运行验证；不能只凭单元测试宣称完成。

### 文件与敏感数据

- `.scratch/` 是本地调试资料，默认不要提交；其中可能包含 hook 事件和对话内容。
- `.trae/keep-attention.env`、`.trae/hooks.json` 影响项目级 TraeX hook，修改前后要说明运行影响。
- 现有未提交改动可能来自用户或其他 agent；修改前先看 `git status --short`，不要回滚无关文件。
- 发布、提交、打 tag、推 GitHub 前，主 agent 需要先给 staging / commit / push 计划，除非用户已经明确要求立即执行。

## 推荐执行流程

1. 主 agent 建立计划：目标、范围、验收、可能要派发的 worker。
2. 主 agent 通过 Orca CLI 派发局部任务。
3. Worker 修改并回报 `worker_done`。
4. 主 agent 审核 diff，必要时返工。
5. 主 agent 运行或说明验证：
   - 单元测试：`swift run keep-attention-tests`；
   - 构建：`swift build`；
   - 打包：`scripts/make-app.sh`；
   - GUI / hook：真实 app 重启 + TraeX prompt 验证。
6. 主 agent 向用户汇报最终状态、证据、剩余风险和下一步。
