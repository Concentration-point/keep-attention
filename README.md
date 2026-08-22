# keep-attention

原生 SwiftUI macOS 注意力调度器：用 Orca / TraeX 结构化信号形成全局 Attention Queue，并在 Session Overview 中解释 3–10 个后台 agent session 的任务、进度、下一步与覆盖缺口。

## 环境要求

- macOS 14+
- Swift 6 / Swift Package Manager
- 纯 Command Line Tools 也可构建、运行和执行测试；不需要 Xcode 工程
- 运行时需要 `/usr/local/bin/orca`；DeepSeek 总结需要设置 `DEEPSEEK_API_KEY`

## 构建与测试

开发构建：

```sh
swift build
```

发布构建：

```sh
swift build -c release
```

测试必须使用独立 Swift Testing 可执行 runner（纯 CLT 下真实执行，不使用只编译 `.xctest` 的 `swift test`）：

```sh
swift run keep-attention-tests
```

该命令会逐项打印 `✔ Test ... passed`，末行打印实际执行统计，例如 `Test run with 35 tests in 6 suites passed`。

GUI / 真实 TraeX 回归分成两个可重复门禁：

```sh
# 发布前一键执行全部回归（推荐）
scripts/run-regression.sh

# 启动独立 /tmp 测试 app，用真实 hook helper 注入 permission/question，
# 再用 Orca Accessibility 自动展开、点击 Seen、闭环并拖动；
# Snooze / Jump / Restart 使用与 GUI 相同的 AttentionQueueActions 契约回归。
scripts/run-gui-regression.sh

# 必须调用命令名 traex（不是在脚本里改写为 traecli），验证项目 hooks
# 实际产生 SessionStart / UserPromptSubmit / Stop / SessionEnd 安全事件。
scripts/run-traex-hook-probe.sh
```

`run-gui-regression.sh` 需要 macOS Accessibility 与 Screen Recording 权限；`run-traex-hook-probe.sh` 需要真实 app-server 权限，在受限 agent sandbox 内会报 `Operation not permitted`，应在正常本机环境运行，不能据此误判 hook 失败。

界面由 `AttentionQueueModel` 运行时协调器驱动（request-centric，唯一界面）：真实 TraeX lifecycle hook 产生 Attention Request；Orca `agents[]` 与 TraeX `UserPromptSubmit` / `Stop` 提供 Session Overview；升级只在应用内 banner 呈现（不接 macOS 系统通知）。

### 一键启动（推荐，自动读 env）

```sh
./scripts/run-app.sh
```

该脚本会 `source` 项目级 `.trae/keep-attention.env`（其中可配置 `DEEPSEEK_API_KEY` 等，已被 `.gitignore` 忽略，不入库）启动打包后的 `keep-attention.app`。需先运行 `scripts/make-app.sh` 生成 app 产物。

> 注意：直接运行 `./keep-attention.app/Contents/MacOS/keep-attention` 不会自动读取 `.trae/keep-attention.env` 中的 `DEEPSEEK_API_KEY`（app 主进程只从进程环境变量读取该 key）；要让 AI 摘要用上 key，请用 `./scripts/run-app.sh` 启动。TraeX hook helper 会自行 `source` 该 env 文件。

## 三种启动方式

### 1. 开发期启动

```sh
DEEPSEEK_API_KEY=sk-... swift run keep-attention
```

不配置 API Key 时应用仍会启动并显示本地确定性文案（`AI disabled`）。如果 Orca 尚未运行，浮层显示 Orca 不可用，不会崩溃。

### 2. 直接启动 release 二进制

```sh
swift build -c release
DEEPSEEK_API_KEY=sk-... .build/arm64-apple-macosx/release/keep-attention
```

如果使用 Intel Mac，请将路径中的 `arm64-apple-macosx` 替换为 SwiftPM 实际生成的目标目录。

### 3. 打包为 `.app` 后启动

```sh
DEEPSEEK_API_KEY=sk-... ./scripts/make-app.sh
open ./keep-attention.app
```

脚本会先执行 `swift build -c release`，然后生成 `keep-attention.app/Contents/Info.plist` 和 `Contents/MacOS/keep-attention`；`LSUIElement=true`，因此应用只显示菜单栏/浮层，不占 Dock。该 bundle 不签名、不公证，适合本机自用；首次运行可能需要在系统设置中允许来自未签名开发者的应用。

如需开机自启，可在登录项中添加 `keep-attention.app`，或自行编写 launchd LaunchAgent，注意在 plist 的 `EnvironmentVariables` 中配置 `DEEPSEEK_API_KEY`。

## 配置

- 轮询间隔默认 5 秒；沿用 `UserDefaults` 中已有的 `pollIntervalSeconds` 配置。
- DeepSeek 模型固定为 `deepseek-v4-flash`，请求使用 JSON Output。
- DeepSeek 外发是双重显式 opt-in：未设置 `DEEPSEEK_API_KEY` 或未在 Session Overview 对该 workspace 开启时都不会调用云端总结。

## 通知与控制（issue #34）

控制状态持久化到 `UserDefaults`（键 `attentionQueue.controls.v1`）：

- 当前 GUI 可达的 workspace 控件：Session Overview 行的 AI 摘要开关，且仍需配置 `DEEPSEEK_API_KEY`。
- 运行时模型还提供应用内升级开关、workspace mute 与清除本地历史 API；完整设置面板不属于当前界面。
- Request 操作：Seen / Snooze（5 分钟、15 分钟、1 小时）/ Dismiss stale / Jump。Jump 复用 #33 SessionAwareJump，只连接状态文案，不改其 fail-closed 逻辑。

中断升级判定是纯逻辑（`KeepAttentionCore.EscalationPolicy`），不接入主轮询循环：

- 只有高置信来源（structuredHook / supervisedWorkflow）的强阻塞义务（permission / question）才会升级；仅 Unseen，Seen、未到期 Snooze、被 mute 的 workspace 一律抑制。
- 同一义务至多升级一次（复用 #29 的 `escalationCount` / `lastEscalatedAt` 字段语义）；全局 60 秒短窗节流。
- Stale 默认低调；只有原本强阻塞的 stale 才可发一次低频 uncertain 通知（15 分钟节流窗）。
- AI 摘要只外发白名单最小片段（repo/branch 脱敏、kind 标签、确定性文案、安全事件标签，总长截断 1200 字符），不携带 session id、路径、标题或原始 hook payload；AI 失败时 fail-open 回退本地确定性文案。

注意：系统 Reduce Motion、workspace mute 与真实 DeepSeek 网络调用仍需真实运行验证；自动回归已覆盖 AI opt-in action 接线与本地 provider/failure 契约。

## DeepSeek 上下文脱敏与裁剪

发送给 DeepSeek 前，应用会做本地脱敏和裁剪：

- 完整结构化回复只在本地用于 fingerprint；DeepSeek 仅接收字段标签和有硬上限的 `short_status_fragment`，不发送 terminal tail、raw IDs、路径或 tool body。
- 常见敏感内容会在本地替换：`api_key` / `access_token` / `password` 类键值、Bearer token、`sk-*` / GitHub token、邮箱、本机 `/Users/<name>/` 路径、私钥块。

这只是基础防线，不等于合规审批；内部代码、日志或隐私数据是否允许外发仍应由使用者自行确认。

## TraeX hook 集成

项目内置 `keep-attention-hook` helper，可通过 `.trae/cli/hooks.json` 接收 TraeX lifecycle 事件与 `UserPromptSubmit` / `Stop`，让当前 TraeX session 在 Session Overview 中显示处理中并在完整回复后更新。

首次使用项目级 hook：

```sh
cp .trae/keep-attention.env.example .trae/keep-attention.env
./scripts/make-app.sh
```

然后编辑 `.trae/keep-attention.env`：

```sh
KEEP_ATTENTION_APP=/absolute/path/to/keep-attention.app
KEEP_ATTENTION_SOCKET=/tmp/keep-attention-orca-keep-attention.sock
```

`.trae/keep-attention.env` 是本机路径配置，已被 `.gitignore` 忽略；不要提交。`.scratch/` 仅用于本地调试/研究资料，也不要提交。

## 当前交互能力

- 收起态有请求时显示全局队首义务；无请求时显示 Session Overview 会话数和 coverage gap 数。
- 展开态以 Attention Queue 为主舞台；Session Overview 显示后台 session 的 task / progress / next step / input uncertainty / source / updated time，并明确标记 not request 与 coverage gap。
- Request 支持 Seen、Snooze、Dismiss stale、session-aware Jump；只有结构化闭环证据才能 Resolved。

## 验收

M1 验收模板与候选报告见 [`docs/acceptance/m1/`](docs/acceptance/m1/)。
