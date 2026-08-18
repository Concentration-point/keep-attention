import Testing
import Foundation
@testable import keep_attention

/// DeepSeek 客户端：请求构造 + 响应解析 + 错误路径（全部 mock，不打网络）。
@Suite struct DeepSeekClientTests {
    private let sampleContext = SummaryContext(
        repo: "repoA",
        branch: "main",
        title: "repoA · grok",
        agentMessage: "正在写测试",
        tail: ["第 1 行", "下一个问题：选 A 还是 B？"]
    )

    private func okBody(content: String) -> Data {
        Fixtures.data("""
        {"id":"r1","object":"chat.completion","model":"deepseek-v4-flash",
        "choices":[{"index":0,"message":{"role":"assistant","content":\(rawJSON(content))},"finish_reason":"stop"}],
        "usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}
        """)
    }

    /// 把任意文本安全包成 JSON 字符串字面量
    private func rawJSON(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    @Test func buildsCorrectRequest() async throws {
        let recorder = LockedBox<(URLRequest?, Data?)>((nil, nil))
        let client = DeepSeekClient(apiKey: "sk-test") { request in
            let (data, response) = (self.okBody(content: #"{"currentTask":"t","progress":"p","nextStep":"n","needsInput":"无"}"#),
                                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            recorder.with { $0 = (request, data) }
            return (data, response)
        }
        _ = try await client.summarize(context: sampleContext)

        let (captured, _) = recorder.with { $0 }
        let req = try #require(captured)
        #expect(req.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        let bodyMap = try #require(body)
        #expect(bodyMap["model"] as? String == "deepseek-v4-flash")
        #expect((bodyMap["response_format"] as? [String: String])?["type"] == "json_object")
        #expect(bodyMap["stream"] as? Bool == false)
        let messages = try #require(bodyMap["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        // prompt 里必须出现 "json" 一词并给出目标示例（JSON Output 要求）
        let systemText = try #require(messages[0]["content"] as? String)
        #expect(systemText.contains("json"))
        #expect(systemText.contains("currentTask"))
        let userText = try #require(messages[1]["content"] as? String)
        #expect(userText.contains("repoA"))
        #expect(userText.contains("选 A 还是 B"))
        #expect(userText.contains("正在写测试"))
    }

    @Test func parsesFourFieldSummary() async throws {
        let content = #"{"currentTask":"实现 MVP","progress":"已完成数据层","nextStep":"写 UI","needsInput":"无"}"#
        let client = DeepSeekClient(apiKey: "k") { _ in
            (self.okBody(content: content),
             HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let summary = try await client.summarize(context: sampleContext)
        #expect(summary == TerminalSummary(currentTask: "实现 MVP", progress: "已完成数据层", nextStep: "写 UI", needsInput: "无"))
    }

    @Test func toleratesMarkdownFencedContent() async throws {
        let content = """
        ```json
        {"currentTask":"t","progress":"p","nextStep":"n","needsInput":"需要确认方案"}
        ```
        """
        let client = DeepSeekClient(apiKey: "k") { _ in
            (self.okBody(content: content),
             HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let summary = try await client.summarize(context: sampleContext)
        #expect(summary.needsInput == "需要确认方案")
    }

    @Test func missingAPIKeyThrows() async {
        let client = DeepSeekClient(apiKey: nil) { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: DeepSeekError.missingAPIKey) {
            _ = try await client.summarize(context: sampleContext)
        }
    }

    @Test func httpErrorThrows() async {
        let client = DeepSeekClient(apiKey: "k") { _ in
            (Fixtures.data(#"{"error":{"message":"bad key"}}"#),
             HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: DeepSeekError.http(401)) {
            _ = try await client.summarize(context: sampleContext)
        }
    }

    @Test func emptyContentThrows() async {
        let client = DeepSeekClient(apiKey: "k") { _ in
            (self.okBody(content: ""),
             HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: DeepSeekError.emptyContent) {
            _ = try await client.summarize(context: sampleContext)
        }
    }

    @Test func redactHookPassthroughByDefault() {
        #expect(redact("abc 123") == "abc 123")
    }
}
