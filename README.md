# keep-attention

原生 SwiftUI macOS 菜单栏/浮层工具，用 Orca 终端状态和 DeepSeek 四段式摘要帮助快速了解各终端进度。

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

内部 M1 Attention Queue UI preview（使用演示投影，不接入真实事件主循环）：

```sh
M1_PREVIEW=1 swift run keep-attention
```

不设置 `M1_PREVIEW=1` 时仍使用原 terminal-centric UI；preview 仅用于人工验证 request card、Evidence drawer、Snoozed / Ambient 折叠和 Reduce Motion。

## 三种启动方式

### 1. 开发期启动

```sh
DEEPSEEK_API_KEY=sk-... swift run keep-attention
```

不配置 API Key 时应用仍会启动，摘要区域显示“未配置 API Key”。如果 Orca 尚未运行，浮层显示 Orca 不可用或暂无终端，不会崩溃。

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

- 轮询间隔默认 5 秒，可在展开面板设置中调整并持久化到 `UserDefaults`。
- DeepSeek 模型固定为 `deepseek-v4-flash`，请求使用 JSON Output。
- DeepSeek 外发是显式 opt-in：未设置 `DEEPSEEK_API_KEY` 时不会调用云端总结，只显示“未配置 API Key”。

## 通知与控制（issue #34）

设置面板（展开浮层右上角齿轮）提供以下控制，状态持久化到 `UserDefaults`（键 `notificationControls.v1`）：

- 全局：启用通知、通知声音、动效偏好（跟随系统 / 始终降低 / 完整）、清除本地历史（清空已关闭历史，保留进行中的义务）。
- Workspace 级：按 repo 静音（mute）；AI 摘要增强需“配置 `DEEPSEEK_API_KEY` 且该 workspace 显式 opt-in”双重满足。
- Request 操作：Seen / Snooze（5 分钟、15 分钟、1 小时）/ Dismiss stale / Jump。Jump 复用 #33 SessionAwareJump，只连接状态文案，不改其 fail-closed 逻辑。

中断升级判定是纯逻辑（`KeepAttentionCore.EscalationPolicy`），不接入 Poller 主循环：

- 只有高置信来源（structuredHook / supervisedWorkflow）的强阻塞义务（permission / question）才会升级；仅 Unseen，Seen、未到期 Snooze、被 mute 的 workspace 一律抑制。
- 同一义务至多升级一次（复用 #29 的 `escalationCount` / `lastEscalatedAt` 字段语义）；全局 60 秒短窗节流。
- Stale 默认低调；只有原本强阻塞的 stale 才可发一次低频 uncertain 通知（15 分钟节流窗）。
- AI 摘要只外发白名单最小片段（repo/branch 脱敏、kind 标签、确定性文案、安全事件标签，总长截断 1200 字符），不携带 session id、路径、标题或原始 hook payload；AI 失败时 fail-open 回退本地确定性文案。

注意：macOS 通知权限/真实投递、声音播放、系统 Reduce Motion 联动、workspace mute/AI opt-in 对真实终端的效果，需在真实运行环境中人工验证；单元测试仅覆盖判定逻辑。

## DeepSeek 上下文脱敏与裁剪

发送给 DeepSeek 前，应用会做本地脱敏和裁剪：

- 当前 hook-only 路径只发送结构化 agent 完整回复，不发送 terminal tail。
- 若未来使用 tail fallback，也只取最近 `40` 行，并限制外发字符数。
- 常见敏感内容会在本地替换：`api_key` / `access_token` / `password` 类键值、Bearer token、`sk-*` / GitHub token、邮箱、本机 `/Users/<name>/` 路径、私钥块。

这只是基础防线，不等于合规审批；内部代码、日志或隐私数据是否允许外发仍应由使用者自行确认。

## TraeX hook 集成

项目内置 `keep-attention-hook` helper，可通过 `.trae/hooks.json` 接收 TraeX `UserPromptSubmit` / `Stop` 事件，让当前 TraeX 请求在浮层里显示“处理中”并在完整回复后触发摘要。

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

- 收起态 pill 显示当前最需要注意的终端，并用徽标表达终端总数或等待输入数量。
- 展开态显示所有 Orca live terminals，按 attention 排序：等待输入、有结构化结果、运行中、空闲/无 hook。
- 点击列表行可查看对应终端详情；点击“跳转到终端”会调用 `orca terminal switch --terminal <handle> --json` 切回 Orca 对应终端。

## 验收

M1 验收模板与候选报告见 [`docs/acceptance/m1/`](docs/acceptance/m1/)。
