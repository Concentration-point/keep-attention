## Destination

锁定**一个**关键决策：**「技术可行性 + 数据获取路径」**。即证明并拍板——我们能否、以及用什么方式拿到两样东西：①Orca 内“当前聚焦的终端/agent”这个焦点信号；②各终端/agent 正在运行的对话上下文。据此确定本工具的数据来源方案。决策必须靠**可跑通的最小探针**背书，而非纸面推演。本次到“决策落锤”为止，不写实现代码。

## Notes

- **产品形态**：一个常驻的 mac「灵动岛」样式小浮层，切到某个 Orca 终端时立刻显示“它在干什么 / 做到哪一步 / 下一步 / 需要我提供什么输入”。
- **已锁定的约束（勿再动摇）**：
  - UI/技术栈：mac 灵动岛样式，**SwiftUI 原生 app**（2026-08-18 复核性能/动效/轻便后由 Rust/Tauri 改定）。灵动岛为 Apple 用 SwiftUI 实现，原生在轻便（无 WebView 运行时）、性能（AppKit 直绘）、动效（`matchedGeometryEffect`/spring）、手感（`NSPanel` non-activating + 贴刘海）四项全面占优。后台逻辑与 UI 语言无关：用 `Process` 调 `orca` CLI、`URLSession` 调 DeepSeek。代价：放弃 Rust。
  - 总结智能体：**纯云端 DeepSeek API**（接受内部上下文外发风险，spec 阶段补数据出境/合规注意事项）。
  - 焦点范围：**只管 Orca 内部**的终端/agent 切换，不做系统级任意窗口。
  - 验收方式：**探针背书**——数据获取路径靠跑通的 spike 证明。
- **关键事实（勿重复调研）**：Orca 自带公共 CLI（`orca-cli` skill），已知能 `terminal list`、`read/wait` 终端内容、`worktree ps`、`status --json`。“当前聚焦终端”是否也由 CLI 暴露，仍需实测。加载完整指南：`ORCA skills get orca-cli`。
- **应查阅的技能**：`orca-cli`、`grilling`、`domain-modeling`、`research`、`prototype`。

## Decisions so far

<!-- 索引：每条一行，指向对应票 -->

- [Orca CLI 能力核查（#2）](https://github.com/Concentration-point/keep-attention/issues/2) — 灵动岛所需「焦点 + 忙闲 + 最近对话」三要素**都能从公共 CLI 拿到，但都有代价**：①焦点无现成字段，需两级推导（`worktree ps --json` 的 `isActive:true` ＋ `terminal list --include-visual-layouts` 的 `activeTabId/activeLeafId/pane.active`），且只是 Orca 应用内选中态、非 OS 前台窗口；②内容读取 `terminal read --json` 只给渲染后逐行文本（非 PTY 字节、非结构化对话），有滚动丢弃上限（实测约 119 行）；③结构化对话/agent 状态依赖 status hook 覆盖，**非全量**（`worktree ps` 的 `agents[].state/lastAssistantMessage`，或 orchestration worker-read 仅限被监督 worker）；无 `cardStatus` 忙闲字段。可执行文件 `/usr/local/bin/orca`（指南 v1.4.183）。详见 `.scratch/keep-attention/research/01-orca-cli-capability.md`。
- [DeepSeek API 核查（#4）](https://github.com/Concentration-point/keep-attention/issues/4) — 走 OpenAI 兼容 Chat Completions（base `https://api.deepseek.com`，`Bearer` 鉴权，Rust 用 reqwest 直连即可）；当前模型仅 `deepseek-v4-flash`/`deepseek-v4-pro`（旧 `deepseek-chat`/`deepseek-reasoner` 已于 2026-07-24 停用），均支持 JSON Output + function calling，可用四字段 schema 稳定产出四段式摘要；单次总结成本约 $0.0013（flash，可忽略），延迟无 SLA 需实测、建议防抖去重；**合规风险高**：DeepSeek 服务器在中国境内，终端上下文（可能含字节内部代码/日志）外发属数据出境，仅记录待 spec 评估脱敏。详见 `.scratch/keep-attention/research/03-deepseek-api.md`。
- [Orca 数据获取探针 spike（#3）](https://github.com/Concentration-point/keep-attention/issues/3) — **数据获取「部分可行」，三要素均用真实命令跑通并背书 #2 的推断**（Orca v1.4.183，快照 11 worktree/23 终端）：①**列举**=`worktree ps --json`+`terminal list --json`（含 handle/tabId/leafId/title/status/isActive/lastOutputAt）；②**读取**=`terminal read --json` 的 `tail[]` 是渲染后逐行明文（非 PTY 字节、非结构化对话），**滚动上限实测约 119 行**（`--cursor 0 --limit 1000` 仍只回 119 行且 `truncated:false`），够"最近在干嘛"、不够完整回放；③**焦点**=无单字段，两级推导跑通（`worktree ps.isActive:true` → `terminal list --include-visual-layouts` 的 `root.activeTabId`+`pane.active`），并**闭环验证**（推导出的 focused handle→read 读到该会话最新提问），但仅 Orca 应用内选中态、非 OS 前台窗口；④**结构化 agent 状态**=`worktree ps.agents[].state/prompt/lastAssistantMessage` 仅 status-hook 覆盖的会话才有（本快照只有 context 仓返回，keep-attention 自身 `status:working` 但 `agents:[]`），`terminal show` 无 `cardStatus`，忙闲只能用 `status`+`lastOutputAt` 近似或 `terminal wait --for tui-idle` 主动探。**降级/拿不到**：完整历史、无 hook 会话的结构化状态、OS 级前台窗口。详见 `.scratch/keep-attention/research/02-data-acquisition-spike.md`。
- [数据获取路径落锤（#5）· 终点决策](https://github.com/Concentration-point/keep-attention/issues/5) — **可做（部分可行），数据路径锁定**：上下文=双通道（优先 `agents[].lastAssistantMessage`，兜底 `terminal read` tail）；焦点=两级推导为主 + `lastOutputAt` 最新兜底（永不空白）；触发=固定轮询**所有终端**、间隔**可配置**（默认建议 5s）、焦点切换即时重算；后端=DeepSeek `deepseek-v4-flash`（JSON schema 出四段式）。**采集/总结分层**：orca CLI 为本地请求/应答式采集层（无事件订阅，故轮询）——每 tick 恒定 2 次全量调用（`worktree ps` + `terminal list --include-visual-layouts` 覆盖枚举/焦点/忙闲，与窗口数无关），`terminal read` 按需 per-terminal；每个 orca 调用是短命进程，不驻留、不占 N 条常驻连接。**DeepSeek 层去重**：CLI 层照常全量轮，但 DeepSeek 仅对「内容较上次变化」的终端重新总结，未变用缓存（去重键=终端内容指纹），以此把「轮询所有终端」的联网成本从 O(窗口数×每 tick) 压到 O(变化的终端数）。**拿不到**：>119 行历史、无 hook 会话的结构化状态、OS 前台窗口焦点。**合规**：终端上下文外发 DeepSeek（境内服务器）属数据出境高风险，脱敏方案留待 spec（#7）。**至此地图抵达终点。**

## Route complete

数据获取路径决策已锁定（#5）。地图抵达终点。以下为 graduate 出的规划票（进入下一阶段/新效应，本地图不再推进）：#6 灵动岛 UI 形态、#7 DeepSeek 上下文脱敏方案、#8 忙闲状态呈现、#9 四段式 prompt+JSON schema（#9 blocked_by #7）。

### 规划阶段进展（decisions）

- [灵动岛 UI 形态（#6）](https://github.com/Concentration-point/keep-attention/issues/6) — **SwiftUI 原生**。收起态=贴刘海药丸，默认显焦点终端（绿=忙/琥珀脉冲=等待/灰=空闲），**任意终端进入等待输入时抢显琥珀**，多个等待时单显最紧急+计数角标。展开态=悬停预览+点击钉住，`NSPanel` non-activating 不抢焦点；四段式（当前任务/已到哪步/下一步/**需要你提供**高亮），顶部带状态徽章+新鲜度，信息不足显「未知」不编造。窗口 statusBar level + `matchedGeometryEffect` spring 动画。原型 `.scratch/keep-attention/prototypes/dynamic-island-mockup.html`。

## Not yet specified

<!-- 已 graduate 为 #6~#9 规划票，进入下一阶段 -->
（空——原雾区已全部 graduate 成 #6 灵动岛 UI / #7 脱敏 / #8 忙闲呈现 / #9 prompt+schema）

## Out of scope

<!-- 已明确排除、不会 graduate 的工作 -->
- 系统级任意终端/窗口的焦点检测（走 macOS Accessibility 嗅探前台窗口）——本效应只做 Orca 内部。
- 纯本地 LLM 总结方案（Ollama 等）——已选定云端 DeepSeek。
