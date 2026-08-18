# keep-attention · MVP 实现规格

> 面向实现的 spec。锁定决策来自 wayfinder 地图 #1 的 #5（数据获取路径）与 #6（UI 形态）。
> 本文件是 grok 实现的唯一事实源。不确定处以此为准，不要自行改设计。

## 0. 一句话

一个常驻 mac 菜单栏/浮层小工具（SwiftUI 原生），轮询本机 Orca 的所有终端，用 DeepSeek 把每个终端"在干什么"总结成四段式，切到哪个终端就能立刻看懂它的任务/进度/下一步/需要什么输入。

## 1. 技术栈（已锁定，勿改）

- **语言/UI**：Swift 6 + SwiftUI，macOS 应用。
- **构建**：Swift Package Manager（`Package.swift`，可执行 target），不依赖 Xcode 工程文件（用 `swift build` / `swift run` 可跑）。目标 macOS 14+。
- **窗口**：`NSPanel` + `.nonactivatingPanel` + `.floating`/statusBar level，常驻置顶。MVP 阶段浮层出现在屏幕顶部中央（贴刘海位置即可，不要求像素级贴合刘海硬件）。
- **采集**：用 `Foundation.Process` 调 `/usr/local/bin/orca` CLI，解析 `--json` 输出（`Codable`）。
- **总结后端**：DeepSeek，`URLSession` 直连 `https://api.deepseek.com/chat/completions`，`Authorization: Bearer $DEEPSEEK_API_KEY`（从环境变量读，缺失时 UI 显示"未配置 API Key"而不崩）。模型 `deepseek-v4-flash`。

## 2. 数据采集层（对应地图 #5/#2/#3）

请求/应答式短命进程，不是常驻监听。一个 `Timer`，每 `pollInterval` 秒一个 tick：

1. `orca worktree ps --json` → 拿全部 worktree 的 `status` / `isActive` / `agents[]`（可能为空）。
2. `orca terminal list --include-visual-layouts --json` → 拿全部终端的 `handle`/`title`/`worktreeId`/`branch`/`lastOutputAt`，以及 visualLayouts 用于焦点推导。
   - 上两步覆盖"枚举 + 焦点 + 忙闲"，与终端数无关，每 tick 恒定 2 次调用。
3. 对需要总结的终端：`orca terminal read --terminal <handle> --json` → 取 `tail[]`（渲染后逐行文本）。per-terminal 调用。

### 焦点推导（两级）
- 一级：`worktree ps` 里 `isActive == true` 的 worktree。
- 二级：`terminal list --include-visual-layouts` 中该 worktree 的 `root.activeTabId` → 该 tab 里 `active == true` 的 pane → 得到聚焦终端 handle。
- **降级**：推导链断裂时，取所有终端里 `lastOutputAt` 最新的作为兜底焦点（永不空白）。

### 上下文来源（双通道 + 降级）
- 首选：`worktree ps` 的 `agents[].lastAssistantMessage`（存在时，质量高）。
- 兜底：`terminal read` 的 `tail[]` 渲染文本（注意上限约 119 行，够"最近在干嘛"）。

### 忙闲判定
- 有 `agents[].state` 时用它；否则用 `status` + `lastOutputAt` 新鲜度近似（如 30s 内有输出=忙，否则空闲）。
- 状态枚举：`.busy` / `.waitingForInput` / `.idle`。
  - `.waitingForInput` 的判定 MVP 简化：`agents[].state` 指示等待，或渲染文本尾部出现明显的提问/确认提示（可先用启发式：末几行包含 "?" 或 "y/n" 之类），拿不准就归 `.busy`，不要乱报等待。

## 3. 总结层（对应地图 #4/#5）

- 对"内容较上次变化"的终端才调 DeepSeek（去重键=终端内容指纹，如 tail 文本的 hash）。内容没变用缓存结果，**不重复烧 API**。
- DeepSeek 请求用 JSON Output（`response_format: {type: "json_object"}`），system prompt 要求严格输出四字段 JSON：
  ```json
  {"currentTask": "...", "progress": "...", "nextStep": "...", "needsInput": "..."}
  ```
- 关键约束：信息不足时对应字段输出中文"未知"（`needsInput` 无则输出"无"），**禁止编造**。
- 失败/超时/无 key：该终端摘要标记为不可用，UI 显示占位（"总结失败，稍后重试" / "未配置 API Key"），不崩溃。

## 4. UI 层（对应地图 #6）

### 收起态（贴刘海药丸）
- 默认显示**焦点终端**：`仓库名 · 分支` + 状态圆点（绿=忙 / 琥珀脉冲=等待输入 / 灰=空闲）。
- **抢显**：只要有任意终端处于 `.waitingForInput`，药丸切成琥珀色显示该终端（即使非焦点），并显示计数角标（如 `3` 表示 3 个在等待）。多个等待时显示最紧急（`lastOutputAt` 最久未更新者）。

### 展开态（四段式面板）
- 触发：**悬停展开预览**（移开自动收起）+ **点击钉住**（再点/点面板外才收）。non-activating 面板悬停不抢焦点。
- 内容：顶部 `● 仓库名 [分支]` + 状态徽章 + "N 秒前更新"；下面四段：当前任务 / 已到哪步 / 下一步 / **需要你提供**（琥珀高亮块）。
- 信息不足字段显示灰色斜体"未知"。
- 多个等待时，面板顶部一行"另有 N 个在等待"，点击可切到下一个等待终端（MVP 可简化为循环切换）。

### 动画
- 收起⇄展开用 SwiftUI `matchedGeometryEffect` + spring。

### 设置
- 一个极简设置入口（菜单栏 icon 的右键菜单或面板内齿轮）：**可配置轮询间隔**（`pollInterval`，秒，默认 5，允许用户改，持久化到 `UserDefaults`）。这是硬需求（用户明确要求）。

## 5. 代码结构建议（非强制，但要清晰分层）

```
Package.swift
Sources/keep-attention/
  App.swift                 // @main, NSApplication + NSPanel 装配
  OrcaClient.swift          // Process 调 orca，Codable 解析 worktree ps / terminal list / terminal read
  FocusResolver.swift       // 两级焦点推导 + lastOutputAt 兜底
  DeepSeekClient.swift      // URLSession 调 DeepSeek，四段式 JSON 解析
  TerminalState.swift       // 领域模型：Terminal / Summary / Status 枚举 / 内容指纹
  Poller.swift              // Timer 轮询编排：采集→去重→总结→发布
  Views/
    IslandPill.swift        // 收起态
    IslandPanel.swift       // 展开态四段式
    SettingsView.swift      // 轮询间隔配置
```

## 6. 验收标准（success criteria）

- `swift build` 通过（无编译错误）。
- 存在可运行入口：`swift run keep-attention` 能拉起浮层（orca 未跑或无终端时优雅显示空状态，不崩）。
- `OrcaClient` 有对 `worktree ps` / `terminal list` / `terminal read` 三个 JSON 的 Codable 模型与解析，**且有单元测试**：用固定的 JSON 样例（可从 `.scratch/keep-attention/research/02-data-acquisition-spike.md` 里的真实脱敏输出取样）验证解析与焦点推导。
- `FocusResolver` 有单元测试：给定 worktree/terminal 快照，能正确推导焦点；焦点缺失时回退到 lastOutputAt 最新。
- 去重逻辑有单元测试：相同内容指纹不触发第二次总结。
- 全量测试**在本机真跑并真出结果**（关键约束，见下）。
- DeepSeek 调用做成可注入（协议/closure），测试里用 mock，不真的打网络。

### ⚠️ 测试执行的硬约束（本机是 Command Line Tools，无完整 Xcode）
上一轮踩的坑：把测试编成 `.xctest` bundle 后，纯 CLT 环境缺 `xctest` 运行器，`swift test` 只“编译成功返回 0”、**实际执行 0 个测试**（假通过）。本机**不装 Xcode**。因此：
- 必须让测试**真正被执行并打印 ✔/✘ 结果**，而不是只编译通过。
- 推荐做法：把测试做成一个**独立可执行 target**（如 `keep-attention-tests`），用 swift-testing 的可执行入口（`swift run keep-attention-tests` 直接调用 `Testing` 的 runner），或改用 XCTest 但确保 SwiftPM 的 in-process 执行路径真跑。无论哪种，**验收标准是：一条命令能在纯 CLT 下跑出“N tests, N passed”这类真实结果**，并把该命令写进 README。
- 交付前你必须真实运行该命令、贴出真实输出（通过数/失败数），不得只凭 `swift test` 退出码 0 就声称通过。

### 打包与启动（新增，属于交付物）
- 提供 `swift build -c release` 的 release 构建说明。
- 提供把 release 二进制打包成 **`.app` bundle** 的脚本（`scripts/make-app.sh` 或等价），`Info.plist` 设 `LSUIElement=true`（只在菜单栏/浮层出现，不占 Dock），**纯 CLT 可做、不需要 Xcode、不需要签名**。
- README 写清三种启动方式：①开发期 `swift run keep-attention`；②release 二进制直接跑；③打包成 `.app` 后双击/开机自启（launchd 可选说明）。

## 7. 不做（out of scope for MVP）

- 系统级任意窗口焦点（只管 Orca 内部）。
- 上下文脱敏（#7 单独处理；MVP 直接发 tail，但代码里给一个 `redact(_:)` 钩子占位，默认透传）。
- 像素级贴合刘海硬件、多屏适配、深浅色主题切换（先跟随系统）。
- 代码签名 + 公证分发（自用不需要；`.app` 本地打包不算分发）。

## 8. 工作方式

- 用 TDD：先给 `OrcaClient` 解析、`FocusResolver`、去重写测试，再实现。
- 分阶段提交（可多次 commit 到当前分支 `main`）。
- 完成后报告：改了哪些文件、`swift build` 与 `swift test` 结果、还剩什么。
