# DeepSeek API 核查：接入方式与四段式摘要能力

- Issue: #4「DeepSeek API 核查：接入方式与四段式摘要能力」
- 抓取日期: 2026-08-18（Asia/Shanghai）
- 一手来源: DeepSeek 官方 API 文档 `api-docs.deepseek.com` / `platform.deepseek.com`
- 说明: 价格、上下文窗口、模型名易漂移，均以文档抓取当日为准；合规相关部分区分「官方文档 Fact」与「二手来源 Inference」。

---

## 一、接入方式（Fact）

### 1.1 Base URL

| 用途 | Base URL |
| --- | --- |
| OpenAI 兼容格式 | `https://api.deepseek.com` |
| Anthropic 兼容格式 | `https://api.deepseek.com/anthropic` |
| Beta 特性（如 strict tool calls / prefix completion） | `https://api.deepseek.com/beta` |

- 结论: 官方明确「The DeepSeek API uses an API format compatible with OpenAI/Anthropic」，可直接把 base_url 换成上表地址复用 OpenAI/Anthropic SDK 或任意 OpenAI 兼容软件。
- 来源: https://api-docs.deepseek.com/ ；https://api-docs.deepseek.com/guides/tool_calls

### 1.2 鉴权（API key 放 header）

- 方式: HTTP 请求头 `Authorization: Bearer ${DEEPSEEK_API_KEY}`。
- API key 申请入口: `https://platform.deepseek.com/api_keys`。
- 官方 curl 示例（非流式）:
  ```bash
  curl https://api.deepseek.com/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${DEEPSEEK_API_KEY}" \
    -d '{
          "model": "deepseek-v4-pro",
          "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Hello!"}
          ],
          "stream": false
        }'
  ```
- 来源: https://api-docs.deepseek.com/

### 1.3 是否兼容 OpenAI Chat Completions 格式

- 结论: 是。核心端点为 `POST https://api.deepseek.com/chat/completions`，请求体字段（`model` / `messages` / `stream` / `response_format` / `tools` 等）与 OpenAI Chat Completions 一致。文档还提供 OpenAI Python SDK / Node SDK 的直接示例（仅改 `base_url`）。
- 补充: 现也支持 OpenAI Responses API 格式与 Anthropic Messages 格式（针对 Codex 适配），但对本工具用最基础的 Chat Completions 即可。
- 来源: https://api-docs.deepseek.com/ ；https://api-docs.deepseek.com/guides/responses_api

### 1.4 Rust 侧调用（reqwest 直连，无需专用 SDK）

- 结论: 可行。DeepSeek 无官方 Rust SDK，但因为是标准 OpenAI 兼容 REST + JSON，Rust 侧用 `reqwest`（配合 `serde`/`serde_json`）直接向 `https://api.deepseek.com/chat/completions` 发 POST 即可，请求头带 `Authorization: Bearer <key>` 和 `Content-Type: application/json`。
- 生态可选项: 也可用第三方 `async-openai` 这类 OpenAI 兼容 crate 并覆盖 base_url；但从依赖最小化角度，`reqwest` 手写请求体已足够支撑四段式摘要这一单一调用。
- 注意（Fact）: 官方有 keep-alive 机制——非流式请求在推理开始前会持续返回空行，流式请求会持续返回 SSE `: keep-alive` 注释；Rust 解析响应时需容忍这些空行/注释。若 10 分钟内仍未开始推理，服务端会关闭连接。
- 来源: https://api-docs.deepseek.com/quick_start/rate_limit （keep-alive 与 429 说明）

---

## 二、能力匹配：模型选型与结构化输出

### 2.1 当前可用模型（Fact）

| model 参数 | 实际版本 | 定位 | 上下文 | 最大输出 |
| --- | --- | --- | --- | --- |
| `deepseek-v4-flash` | DeepSeek-V4-Flash-0731 | 便宜、快、日常任务 | 1M tokens | 384K |
| `deepseek-v4-pro` | DeepSeek-V4-Pro-0813（GA） | 最强推理 / Agent 能力 | 1M tokens | 384K |

- 两个模型都支持「thinking / non-thinking」双模式（默认 thinking），思考强度可选 low / high / max。
- 来源: https://api-docs.deepseek.com/quick_start/pricing ；https://api-docs.deepseek.com/updates

### 2.2 关于 `deepseek-chat` / `deepseek-reasoner`（重要：已下线）

- 结论: 任务背景里提到的 `deepseek-chat` / `deepseek-reasoner` 这两个旧模型名 **已于 2026-07-24 停用**，不能再作为选型依据。
- 历史映射（供理解）: 停用前它们分别指向 `deepseek-v4-flash` 的 non-thinking / thinking 模式（更早期曾指向 V3.1 / V3.2 系列）。
- 现在正确选型只有 `deepseek-v4-flash` 与 `deepseek-v4-pro`。
- 来源: https://api-docs.deepseek.com/updates （2026-04-24 条目：「The two legacy API model names, `deepseek-chat` and `deepseek-reasoner`, will be discontinued in three months (2026-07-24)」）

### 2.3 结构化 JSON 输出（Fact）

- 支持。开启方式:
  1. 请求设 `response_format = {"type": "json_object"}`；
  2. 在 system/user prompt 里包含单词 "json" 并给出目标 JSON 示例；
  3. 合理设 `max_tokens` 防止 JSON 被截断。
- 已知限制（官方注记）: 使用 JSON Output 时 API 偶发返回空 content，官方仍在优化，建议靠调 prompt 缓解。
- `deepseek-v4-flash` 与 `deepseek-v4-pro` 均支持 Json Output。
- 来源: https://api-docs.deepseek.com/guides/json_mode ；https://api-docs.deepseek.com/quick_start/pricing

### 2.4 Function Calling / strict 结构化（Fact）

- 支持 OpenAI 兼容 `tools`（`type: function` + JSON Schema `parameters`）格式，两个模型都支持 Tool Calls。
- **strict 模式（Beta）**: 用 `base_url="https://api.deepseek.com/beta"`，并对每个 function 设 `strict: true`，服务端会按 JSON Schema 强校验输出格式，保证严格贴合定义（支持 object/string/number/integer/boolean/array/enum/anyOf，object 需全字段 required 且 `additionalProperties:false`）。
- 对四段式摘要的意义: 想稳定拿到「当前任务 / 已到哪步 / 下一步 / 需要我提供什么输入」四个固定字段，有两条稳妥路径——(a) `response_format: json_object` + prompt 约束四字段；(b) 更强约束用 beta 的 strict tool call，定义一个含四个 required 字段的 JSON Schema。推荐 (b) 用于稳定门禁式产出。
- 来源: https://api-docs.deepseek.com/guides/tool_calls

---

## 三、成本与频率

### 3.1 最新价格（Fact，单位 USD / 每 1M tokens）

价格自 **2026-08-16 16:00 UTC** 起生效，采用高峰/平峰计价（平峰价为高峰价一半）。高峰时段为 **UTC 01:00–04:00 与 06:00–10:00**，其余为平峰。

| 计费项 | deepseek-v4-flash（平峰 / 高峰） | deepseek-v4-pro（平峰 / 高峰） |
| --- | --- | --- |
| 输入·缓存命中 | $0.007 / $0.014 | $0.022 / $0.044 |
| 输入·缓存未命中 | $0.22 / $0.44 | $0.66 / $1.32 |
| 输出 | $0.66 / $1.32 | $1.98 / $3.96 |

- 来源: https://api-docs.deepseek.com/quick_start/pricing

### 3.2 并发与限流（Fact）

- 账号级并发上限: `deepseek-v4-pro` = 500，`deepseek-v4-flash` = 2500；超限返回 HTTP 429。可免费申请扩容。
- 一次请求从发出到响应完成算一个并发连接；限流按账号计算（与用哪个 API Key 无关）。
- 来源: https://api-docs.deepseek.com/quick_start/rate_limit

### 3.3 针对本工具的成本量级估算（Inference）

场景假设: 每次焦点切换 / 轮询触发一次总结，选用最便宜的 `deepseek-v4-flash`，输入约 3K–8K tokens（终端上下文），输出约 200–400 tokens（四段短文）。

- 单次成本（平峰、缓存未命中，取 5K 输入 / 300 输出）: 约 5000/1e6 × $0.22 + 300/1e6 × $0.66 ≈ **$0.0011 + $0.0002 ≈ $0.0013**（约 0.01 元人民币量级）。高峰翻倍约 $0.0026。
- 若复用固定 prompt 前缀命中缓存，输入价降到 $0.007/1M，单次成本可再降一个量级。
- 频率放大: 即便每分钟触发 1 次、每天活跃 8 小时 ≈ 480 次/天，平峰下约 $0.6/天量级，成本极低。真正需要控制的是「触发频率」而非「单价」——建议加防抖/去重（相同上下文不重复调用），避免焦点频繁切换刷爆调用。
- 延迟（Open question / 需实测）: 官方未给出明确延迟 SLA。thinking 模式会显著增加首字/完成延迟；对灵动岛这种「秒级要出结果」的浮层，建议默认走 **non-thinking 模式 + 低 max_tokens**，必要时用 streaming 先出前几段。实际延迟需接入后实测。
- 依据来源: https://api-docs.deepseek.com/quick_start/pricing ；https://api-docs.deepseek.com/quick_start/rate_limit

---

## 四、合规注记（数据出境风险，仅事实记录，不做决策）

- **服务器位置（Inference，二手来源）**: DeepSeek 隐私政策称其服务器位于中华人民共和国，数据控制方为杭州深度求索（Hangzhou DeepSeek Artificial Intelligence Co., Ltd.），Open Platform 服务条款受中国大陆法律管辖。
  - 来源: https://meetily.ai/llm-privacy/deepseek ；https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html
- **是否用于训练（Inference，需以官方条款原文为准）**: 有二手调查称 DeepSeek「开放平台服务协议」不含训练授权条款（即 API 数据不用于训练）；但同一隐私政策又描述了「为改进/训练模型使用个人数据」及对应的 opt-out 权利。二者存在口径差异，落 spec 前应逐字核对官方 Open Platform ToS 与 Privacy Policy 原文。
  - 来源: https://cdn.deepseek.com/policies/en-US/deepseek-open-platform-terms-of-service.html ；https://meetily.ai/llm-privacy/deepseek
- **本工具的具体风险点（Fact / 供 spec 记录）**:
  1. Orca 终端上下文可能含字节内部代码、日志、路径、内部服务名、凭据片段等敏感信息，直接发往 DeepSeek 公网 API = 数据出境到境外第三方 SaaS。
  2. 该行为很可能触及字节内部数据合规红线（源码外发、内部信息外泄），本票不做决策，但需在 spec 明确标注为高风险，并考虑：脱敏/裁剪上下文、白名单字段、或改用内部合规的模型端点。
  3. 官方 `user_id` 参数可做内容安全隔离与 KVCache 隔离，但不改变「数据仍出境到 DeepSeek」这一事实。
  - 来源: https://api-docs.deepseek.com/quick_start/rate_limit （user_id 隔离说明）

---

## 一句话总结

DeepSeek API 走标准 OpenAI 兼容 Chat Completions（`https://api.deepseek.com/chat/completions` + `Authorization: Bearer` 头），Rust 侧用 `reqwest` 直连即可、无需专用 SDK；用 `deepseek-v4-flash`（1M 上下文、支持 JSON Output 与 strict function calling）配合固定四字段 JSON Schema **能稳定支撑四段式摘要**，单次总结成本约 $0.001–0.003 量级、成本几乎可忽略（需控制触发频率与实测延迟）；**唯一实质障碍是合规**——把可能含字节内部代码/日志的终端上下文外发到位于中国境内的 DeepSeek 公网 API 属数据出境高风险，需在后续 spec 中显式记录并做脱敏/端点评估。
