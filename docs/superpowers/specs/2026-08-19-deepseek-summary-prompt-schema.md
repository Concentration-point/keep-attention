# DeepSeek 四段式摘要 Prompt 与 JSON Schema

## 目标

将一个 Orca / TraeX terminal 的结构化 agent 输出总结成四段式状态，供灵动岛详情区展示：

- 当前任务：`currentTask`
- 已到哪步：`progress`
- 下一步：`nextStep`
- 需要你提供：`needsInput`

## 模型与接口

- Endpoint：`https://api.deepseek.com/chat/completions`
- Model：`deepseek-v4-flash`
- Response format：`{"type":"json_object"}`
- Stream：`false`
- Max tokens：`2000`

## System prompt

```text
你是终端状态摘要器。根据用户提供的终端上下文（agent 消息与/或终端渲染文本），
严格输出一个 json 对象，且只包含这四个字段：
{"currentTask": "当前任务", "progress": "已到哪步", "nextStep": "下一步", "needsInput": "需要用户提供什么输入"}
规则：
- 全部用简体中文，每字段一句话以内。
- 信息不足的字段输出"未知"；没有待用户输入时 needsInput 输出"无"。
- 禁止编造上下文中不存在的信息。
```

实现位置：`Sources/KeepAttentionCore/DeepSeekClient.swift` 的 `DeepSeekClient.systemPrompt`。

## JSON schema（逻辑契约）

DeepSeek 当前使用 JSON Output 而不是 strict schema API；本项目在本地用 `TerminalSummary` 解码，逻辑 schema 如下：

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["currentTask", "progress", "nextStep", "needsInput"],
  "properties": {
    "currentTask": {
      "type": "string",
      "description": "用户或 agent 当前正在处理的任务；信息不足时为“未知”。"
    },
    "progress": {
      "type": "string",
      "description": "任务已经推进到哪一步；信息不足时为“未知”。"
    },
    "nextStep": {
      "type": "string",
      "description": "下一步最可能要做什么；信息不足时为“未知”。"
    },
    "needsInput": {
      "type": "string",
      "description": "需要用户提供的输入；没有需要输入时为“无”。"
    }
  }
}
```

本地容错：

- 缺少 `progress` / `nextStep` 时解码为 `未知`。
- 缺少 `needsInput` 时解码为 `无`。
- `needsInput: false` 解码为 `无`。
- `needsInput: true` 解码为 `需要输入`。
- 数值字段会转成字符串，避免模型偶发输出数字导致 UI 崩溃。
- 模型把 JSON 包在 Markdown code fence 时，本地会剥离围栏后解析。

实现位置：`Sources/KeepAttentionCore/TerminalState.swift` 的 `TerminalSummary`。

## User message 组织

User message 由 `SummaryContext` 构造：

```text
终端上下文：
仓库: <repo> 分支: <branch>
终端标题: <title>

[agent 最近消息]
<redacted and truncated agentMessage>

[终端最近输出]
<redacted and truncated tail>
```

当前 hook-only 路径只填充 `[agent 最近消息]`，`tail` 为空；不会从 terminal tail 猜测摘要。

如果未来启用 tail fallback：

- 只取最近 `ContextExportPolicy.maxTailLines` 行（当前 40 行）。
- agent message 和 tail 都会先脱敏再按字符数裁剪。

实现位置：

- `Sources/KeepAttentionCore/DeepSeekClient.swift`：`requestBody(context:)`
- `Sources/KeepAttentionCore/TerminalState.swift`：`redactAndTruncate` / `ContextExportPolicy`

## 去重键

Orca agent hook：

```text
contentFingerprint([worktreeId, paneKey, lastAssistantMessage])
```

TraeX hook：

```text
contentFingerprint(["traex", handle, lastAssistantMessage])
```

缓存按 terminal `handle` 保存：

- 指纹相同：复用已有 `TerminalSummary`，不再调用 DeepSeek。
- 指纹变化：该 terminal 进入 `loading`，只重算该 terminal。
- working/running 中间输出：不总结。

实现位置：`Sources/KeepAttentionCore/Poller.swift`。

## 失败/降级文案

- 未配置 API key：`未配置 API Key`
- 其他总结失败：`总结失败，稍后重试`
- 无结构化 agent 输出：`未检测到结构化 agent 输出`
- agent 正在执行：`Agent 正在执行，等待下一条完整回复`
- TraeX 正在执行：`TraeX 正在处理当前请求…`

## 验证

覆盖测试：

- `DeepSeekClientTests.buildsCorrectRequest`
- `DeepSeekClientTests.parsesFourFieldSummary`
- `DeepSeekClientTests.toleratesMarkdownFencedContent`
- `DeepSeekClientTests.missingFieldsUseFallbackLabels`
- `DeepSeekClientTests.booleanNeedsInputFalseMeansNoInput`
- `DeepSeekClientTests.booleanNeedsInputTrueMeansInputRequired`
- `DeepSeekClientTests.numericProgressIsStringified`
- `PollerTests.finalAgentMessageSummarizesMappedTerminalOnceAndDedupes`
- `PollerTests.allHookCoveredTerminalsSummarizeIndependentlyAndDedupPerHandle`

验证命令：

```sh
swift run keep-attention-tests
swift build
scripts/make-app.sh
```
