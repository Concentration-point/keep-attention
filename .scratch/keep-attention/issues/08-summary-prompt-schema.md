## Question

四段式摘要的 prompt 与 JSON schema 如何设计？

- 四字段：当前任务 / 已到哪步 / 下一步 / 需要我提供什么输入。用 DeepSeek 的 response_format JSON Output（或 beta strict JSON schema）稳定产出。
- 输入组织：双通道原料（结构化 `lastAssistantMessage` 或渲染 tail）如何拼进 prompt；如何提示模型在信息不足时输出"未知"而非编造。
- 边界：内容没变化时的去重键如何设计（避免重复调用），失败/超时的降级文案。

依赖：#5、#7（脱敏后的输入形态）。产出：可直接实现的 prompt 模板 + JSON schema。
