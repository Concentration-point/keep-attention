import Foundation

// MARK: - 总结器协议（可注入，测试用 mock）

protocol SummaryProviding: Sendable {
    func summarize(context: SummaryContext) async throws -> TerminalSummary
}

// MARK: - 错误

enum DeepSeekError: Error, Equatable {
    case missingAPIKey
    case http(Int)
    case emptyContent
    case badResponse(String)
}

// MARK: - DeepSeek 实现

/// URLSession 直连 DeepSeek chat/completions，JSON Output 四段式（spec §3）。
/// `send` 可注入，测试不打网络。
struct DeepSeekClient: SummaryProviding {
    static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    static let model = "deepseek-v4-flash"

    let apiKey: String?
    let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        apiKey: String?,
        timeout: TimeInterval = 30,
        send: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.apiKey = apiKey
        self.send = send ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            let session = URLSession(configuration: config)
            do {
                let (data, response) = try await session.data(for: $0)
                guard let http = response as? HTTPURLResponse else {
                    throw DeepSeekError.badResponse("非 HTTP 响应")
                }
                return (data, http)
            }
        }
    }

    /// 从环境变量读 key（spec §1）。
    static func apiKeyFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard let key = env["DEEPSEEK_API_KEY"], !key.isEmpty else { return nil }
        return key
    }

    func summarize(context: SummaryContext) async throws -> TerminalSummary {
        guard let apiKey, !apiKey.isEmpty else {
            throw DeepSeekError.missingAPIKey
        }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(context: context)

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DeepSeekError.http(response.statusCode)
        }
        return try Self.parseSummary(data)
    }

    // MARK: 请求构造

    static let systemPrompt = """
    你是终端状态摘要器。根据用户提供的终端上下文（agent 消息与/或终端渲染文本），
    严格输出一个 json 对象，且只包含这四个字段：
    {"currentTask": "当前任务", "progress": "已到哪步", "nextStep": "下一步", "needsInput": "需要用户提供什么输入"}
    规则：
    - 全部用简体中文，每字段一句话以内。
    - 信息不足的字段输出"未知"；没有待用户输入时 needsInput 输出"无"。
    - 禁止编造上下文中不存在的信息。
    """

    static func requestBody(context: SummaryContext) throws -> Data {
        var user = "终端上下文：\n"
        user += "仓库: \(context.repo)"
        if let branch = context.branch, !branch.isEmpty { user += " 分支: \(branch)" }
        if let title = context.title, !title.isEmpty { user += "\n终端标题: \(title)" }
        if let message = context.agentMessage, !message.isEmpty {
            user += "\n\n[agent 最近消息]\n\(redact(message))"
        }
        if !context.tail.isEmpty {
            let recent = context.tail.suffix(60).joined(separator: "\n")
            user += "\n\n[终端最近输出]\n\(redact(recent))"
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "stream": false,
            "max_tokens": 500,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    // MARK: 响应解析

    private struct APIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    static func parseSummary(_ data: Data) throws -> TerminalSummary {
        let api = try JSONDecoder().decode(APIResponse.self, from: data)
        guard let content = api.choices.first?.message.content, !content.isEmpty else {
            throw DeepSeekError.emptyContent
        }
        let stripped = stripCodeFences(content)
        guard let jsonData = stripped.data(using: .utf8) else {
            throw DeepSeekError.badResponse("content 无法转 UTF-8")
        }
        do {
            return try JSONDecoder().decode(TerminalSummary.self, from: jsonData)
        } catch {
            throw DeepSeekError.badResponse("content 不是合法四字段 JSON")
        }
    }

    /// 容忍模型偶发把 JSON 包进 ```json … ``` 代码围栏。
    static func stripCodeFences(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let closing = text.range(of: "```", options: .backwards) {
                text = String(text[..<closing.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
