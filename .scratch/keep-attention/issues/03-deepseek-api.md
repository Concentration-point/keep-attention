## Question

核查 DeepSeek API 作为“总结智能体”后端的接入事实：

1. **接入方式**：base URL、鉴权（API key）、是否兼容 OpenAI Chat Completions 格式、Rust 侧调用方式（reqwest 直连即可，无需特殊 SDK）？
2. **能力匹配**：能否稳定产出结构化的“当前任务 / 已到哪步 / 下一步 / 需要什么输入”四段式摘要？（模型选型、是否支持 JSON 输出/function calling、上下文窗口大小）
3. **成本与频率**：按 token 计费，若每次焦点切换/轮询触发一次总结，量级与延迟是否可接受？
4. **合规注记**：把 Orca 终端上下文外发到 DeepSeek 公网 API 的数据出境风险点（供 spec 记录，本票只做事实核查，不做决策）。

纯文档核查（AFK）。产出：接入事实清单，作为票 04 落锤的证据之一。
