import Testing
import Foundation
import Darwin
@testable import KeepAttentionCore

/// TraeX hook bridge：helper → unix socket → AppModel 合成结构化 summary source。
@MainActor
@Suite struct TraeXHookBridgeTests {
    private let repoA = "/Users/dev/orca/repoA"

    /// agents=[] 的 ps 快照：所有 terminal 均无 orca 结构化源，TraeX 事件接管显示。
    private static let psWithNoAgents = """
    {
      "id": "cmd-no-agents",
      "ok": true,
      "result": {
        "worktrees": [
          {
            "worktreeId": "111::/Users/dev/orca/repoA",
            "repo": "repoA",
            "path": "/Users/dev/orca/repoA",
            "branch": "refs/heads/main",
            "isActive": true,
            "status": "working",
            "lastOutputAt": 1786993627799,
            "agents": []
          },
          {
            "worktreeId": "222::/Users/dev/orca/repoB",
            "repo": "repoB",
            "path": "/Users/dev/orca/repoB",
            "branch": "refs/heads/feat-y",
            "isActive": false,
            "status": "active",
            "lastOutputAt": 1786990000000,
            "agents": []
          }
        ]
      }
    }
    """

    private func makeOrca(ps: String) -> OrcaClient {
        OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return Fixtures.data(ps) }
            return Fixtures.data(Fixtures.terminalList)
        }
    }

    private func makeModel(ps: String = psWithNoAgents, summarizer: SummaryProviding) -> AppModel {
        AppModel(orca: makeOrca(ps: ps), summarizer: summarizer)
    }

    private func promptEvent(cwd: String) -> TraeXEvent {
        TraeXEvent(hookEventName: "UserPromptSubmit", sessionId: "s1", turnId: "t1",
                   cwd: cwd, prompt: "修复登录 bug", lastAssistantMessage: nil)
    }

    private func stopEvent(cwd: String, message: String?) -> TraeXEvent {
        TraeXEvent(hookEventName: "Stop", sessionId: "s1", turnId: "t1",
                   cwd: cwd, prompt: nil, lastAssistantMessage: message)
    }

    @Test func userPromptSubmitShowsWorkingInsteadOfNoStructuredOutput() async throws {
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(summarizer: summarizer)

        await model.tick()
        let display = try #require(model.displays.first { $0.handle == "term_A2" })
        #expect(display.summary == .unavailable("未检测到结构化 agent 输出"))

        await model.applyTraeXEvent(promptEvent(cwd: repoA))
        let after = try #require(model.displays.first { $0.handle == "term_A2" })
        #expect(after.summary == .unavailable("TraeX 正在处理当前请求…"))
        #expect(calls.with { $0 } == 0)
    }

    @Test func stopMessageSummarizesTraeXTerminalOnceAndDedupes() async throws {
        let calls = LockedBox<[SummaryContext]>([])
        let summarizer = MockSummarizer { context in
            calls.with { $0.append(context) }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(summarizer: summarizer)
        await model.tick()

        await model.applyTraeXEvent(promptEvent(cwd: repoA))
        await model.applyTraeXEvent(stopEvent(cwd: repoA, message: "修复完成，全部测试通过"))
        #expect(calls.with { $0.count } == 1)
        let expectedMessage = """
        用户请求：修复登录 bug

        Agent 回复：
        修复完成，全部测试通过
        """
        #expect(calls.with { $0.first?.agentMessage } == expectedMessage)
        let display = try #require(model.displays.first { $0.handle == "term_A2" })
        guard case .ready(let s) = display.summary else {
            Issue.record("应为 ready，实际 \(display.summary)")
            return
        }
        #expect(s.currentTask == "t")

        // 相同 Stop 消息重复到达（多 hook 触发）→ 指纹去重，不再调用 DeepSeek。
        await model.applyTraeXEvent(stopEvent(cwd: repoA, message: "修复完成，全部测试通过"))
        #expect(calls.with { $0.count } == 1)
        let after = try #require(model.displays.first { $0.handle == "term_A2" })
        #expect(after.summary == .ready(TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")))
    }

    @Test func stopWithoutMessageKeepsNoStructuredOutputCopy() async throws {
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(summarizer: summarizer)
        await model.tick()

        await model.applyTraeXEvent(stopEvent(cwd: repoA, message: nil))
        #expect(calls.with { $0 } == 0)
        let display = try #require(model.displays.first { $0.handle == "term_A2" })
        #expect(display.summary == .unavailable("未检测到结构化 agent 输出"))
    }

    /// 现有 hook-only Orca agents[] 行为优先：焦点 terminal 已有 orca agent 时 TraeX 事件不改写显示。
    @Test func traexEventDoesNotOverrideOrcaAgentTerminal() async throws {
        let calls = LockedBox(0)
        let summarizer = MockSummarizer { _ in
            calls.with { $0 += 1 }
            return TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        // 默认 fixture：term_A2（repoA 焦点）有 orca working agent。
        let model = makeModel(ps: Fixtures.worktreePS, summarizer: summarizer)
        await model.tick()
        #expect(model.focusedHandle == "term_A2")

        await model.applyTraeXEvent(promptEvent(cwd: repoA))
        let termA2 = try #require(model.displays.first { $0.handle == "term_A2" })
        #expect(termA2.summary == .unavailable("Agent 正在执行，等待下一条完整回复"))
        // TraeX 状态也不落到同 worktree 的其它 terminal 上。
        let termA1 = try #require(model.displays.first { $0.handle == "term_A1" })
        #expect(termA1.summary != .unavailable("TraeX 正在处理当前请求…"))
        // 仅首次 tick 的 repoB done message（现有 Orca 行为）；TraeX 事件不追加调用。
        #expect(calls.with { $0 } == 1)
    }

    /// 未匹配任何 worktree 的 cwd 事件被安全忽略，不影响现有显示。
    @Test func unknownCwdEventIsIgnored() async throws {
        let summarizer = MockSummarizer { _ in
            TerminalSummary(currentTask: "t", progress: "p", nextStep: "n", needsInput: "无")
        }
        let model = makeModel(summarizer: summarizer)
        await model.tick()

        await model.applyTraeXEvent(promptEvent(cwd: "/not/a/worktree"))
        let display = try #require(model.displays.first { $0.handle == "term_A2" })
        #expect(display.summary == .unavailable("未检测到结构化 agent 输出"))
    }
}

@Suite struct TraeXAttentionAdapterTests {
    private let observedAt = Date(timeIntervalSince1970: 1_786_000_000)

    @Test func permissionRequestMapsWithExactCorrelationIdentity() throws {
        let event = try #require(TraeXEvent.decodeLine(Fixtures.traeXPermissionRequest))
        let result = TraeXAttentionAdapter.adapt(
            event,
            observedAt: observedAt,
            sessionIsKnown: true
        )

        #expect(result.events == [.traeXPermissionRequested(
            sessionID: "session-approve",
            turnID: "turn-approve",
            toolUseID: "tool-approve",
            toolName: "Bash",
            observedAt: observedAt
        )])
        #expect(result.discovery == nil)
    }

    @Test func planQuestionLifecycleMapsOpenAnswerAndFailure() throws {
        let opened = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXPlanQuestionOpened)),
            observedAt: observedAt,
            sessionIsKnown: true
        )
        #expect(opened.events == [.traeXQuestionOpened(
            sessionID: "session-plan",
            turnID: "turn-plan",
            toolUseID: "tool-question",
            observedAt: observedAt
        )])

        let answered = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXPlanQuestionAnswered)),
            observedAt: observedAt,
            sessionIsKnown: true
        )
        #expect(answered.events == [.traeXQuestionAnswered(
            sessionID: "session-plan",
            turnID: "turn-plan",
            toolUseID: "tool-question",
            observedAt: observedAt
        )])

        let failed = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXPlanQuestionFailed)),
            observedAt: observedAt,
            sessionIsKnown: true
        )
        #expect(failed.events == [.traeXQuestionFailed(
            sessionID: "session-plan",
            turnID: "turn-plan",
            toolUseID: "tool-question",
            observedAt: observedAt
        )])
    }

    @Test func toolResultMapsUsingExactToolIdentity() throws {
        let completed = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXPermissionApproved)),
            observedAt: observedAt,
            sessionIsKnown: true
        )
        #expect(completed.events == [.traeXToolCompleted(
            sessionID: "session-approve",
            turnID: "turn-approve",
            toolUseID: "tool-approve",
            observedAt: observedAt
        )])

        let denied = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXPermissionDenied)),
            observedAt: observedAt,
            sessionIsKnown: true
        )
        #expect(denied.events == [.traeXQuestionFailed(
            sessionID: "session-deny",
            turnID: "turn-deny",
            toolUseID: "tool-deny",
            observedAt: observedAt
        )])
    }

    @Test func sessionEndMarksOnlyMatchingSessionStale() throws {
        let result = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXSessionEnd)),
            observedAt: observedAt,
            sessionIsKnown: true
        )
        #expect(result.events == [.markStale(
            sessionKey: .traeX(sessionID: "session-end"),
            observedAt: observedAt
        )])
    }

    @Test func unknownSessionIsDiscoveredWithoutFabricatingOpenRequest() throws {
        let result = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXUnknownSessionStop)),
            observedAt: observedAt,
            sessionIsKnown: false
        )
        #expect(result.discovery == .startBoundaryMissing)
        #expect(result.events == [.unclassifiedObserved(
            sessionID: "session-resumed",
            correlationID: "turn-resumed",
            eventName: TraeXEvent.stop,
            observedAt: observedAt
        )])
    }

    @Test func sessionStartAndUnknownIsolatedEventDoNotOpenRequests() throws {
        let started = TraeXAttentionAdapter.adapt(
            try #require(TraeXEvent.decodeLine(Fixtures.traeXSessionStart)),
            observedAt: observedAt,
            sessionIsKnown: false
        )
        #expect(started.discovery == nil)
        #expect(started.events == [])

        let isolated = TraeXAttentionAdapter.adapt(
            TraeXEvent(hookEventName: "SubagentStart", sessionId: "isolated"),
            observedAt: observedAt,
            sessionIsKnown: false
        )
        #expect(isolated.discovery == nil)
        #expect(isolated.events == [])
    }

    @Test func abnormalCloseProducesRestartStaleCandidate() {
        #expect(TraeXAttentionAdapter.staleAfterRestart(observedAt: observedAt) == .markStaleAfterRestart(
            observedAt: observedAt
        ))
    }
}

/// hook 协议层：JSON line 解码、unix socket server、bounded JSONL 日志。
@Suite struct TraeXHookProtocolTests {    @Test func decodesHookPayloadLine() throws {
        let line = """
        {"hook_event_name":"Stop","session_id":"abc","turn_id":"t9","cwd":"/Users/dev/orca/repoA","prompt":"做点事","last_assistant_message":"干完了"}
        """
        let event = try #require(TraeXEvent.decodeLine(line))
        #expect(event.hookEventName == "Stop")
        #expect(event.sessionId == "abc")
        #expect(event.turnId == "t9")
        #expect(event.cwd == "/Users/dev/orca/repoA")
        #expect(event.prompt == "做点事")
        #expect(event.lastAssistantMessage == "干完了")
        #expect(event.isSupported)
    }

    @Test func decodesPermissionPayloadWithCorrelationIdentity() throws {
        let event = try #require(TraeXEvent.decodeLine(Fixtures.traeXPermissionRequest))
        #expect(event.hookEventName == TraeXEvent.permissionRequest)
        #expect(event.sessionId == "session-approve")
        #expect(event.turnId == "turn-approve")
        #expect(event.toolUseId == "tool-approve")
        #expect(event.toolName == "Bash")
        #expect(event.isSupported)
    }

    @Test func supportsM1WhitelistAndDecodesAmbientMetadata() throws {
        let expected = [
            TraeXEvent.sessionStart, TraeXEvent.sessionEnd, TraeXEvent.permissionRequest,
            TraeXEvent.preToolUse, TraeXEvent.postToolUse, TraeXEvent.postToolUseFailure,
            TraeXEvent.notification, TraeXEvent.userPromptSubmit, TraeXEvent.stop,
        ]
        for eventName in expected {
            let event = try #require(TraeXEvent.decodeLine(
                #"{"hook_event_name":"\#(eventName)","session_id":"session","turn_id":"turn"}"#
            ))
            #expect(event.isSupported)
        }
        #expect(TraeXEvent.decodeLine(#"{"hook_event_name":"SubagentStart"}"#)?.isSupported == false)

        let sessionStart = try #require(TraeXEvent.decodeLine(Fixtures.traeXSessionStart))
        #expect(sessionStart.source == "startup")
        let sessionEnd = try #require(TraeXEvent.decodeLine(Fixtures.traeXSessionEnd))
        #expect(sessionEnd.reason == "prompt_input_exit")
        let notification = try #require(TraeXEvent.decodeLine(Fixtures.traeXNotification))
        #expect(notification.notificationType == "permission_prompt")
        #expect(notification.stopHookActive == true)
    }

    @Test func decodesPartialPayloadAndRejectsGarbage() {
        let partial = TraeXEvent.decodeLine(#"{"hook_event_name":"UserPromptSubmit","cwd":"/x"}"#)
        #expect(partial?.hookEventName == "UserPromptSubmit")
        #expect(partial?.prompt == nil)
        #expect(TraeXEvent.decodeLine("not json at all") == nil)
        #expect(TraeXEvent.decodeLine("{}")?.isSupported == false)
    }

    @Test func serverReceivesLineOverUnixSocket() async throws {
        let path = "/tmp/keep-attention-tests-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let received = LockedBox<[TraeXEvent]>([])
        let server = TraeXEventServer(socketPath: path) { event in received.with { $0.append(event) } }
        try server.start()
        defer { server.stop() }

        let line = """
        {"hook_event_name":"Stop","session_id":"abc","turn_id":"t9","cwd":"/w","last_assistant_message":"done"}
        """
        try await Self.retrySend(path: path, line: line)

        let deadline = Date().addingTimeInterval(3)
        while received.with({ $0.count }) < 1 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let event = try #require(received.with { $0.first })
        #expect(event.hookEventName == "Stop")
        #expect(event.lastAssistantMessage == "done")
    }

    @Test func wireEventDecodingDoesNotRetainLifecycleBodies() throws {
        let event = try #require(TraeXEvent.decodeLine(#"{"hook_event_name":"PostToolUseFailure","session_id":"session-safe","turn_id":"turn-safe","tool_use_id":"tool-safe","tool_name":"Bash","prompt":"private-prompt","last_assistant_message":"private-assistant","tool_input":{"command":"private-command"},"tool_response":{"stdout":"private-output"},"error":"private-error","message":"private-message"}"#))

        #expect(event.prompt == nil)
        #expect(event.lastAssistantMessage == nil)
    }

    @Test func encodeLineOmitsSensitiveFieldsForLifecycleEvents() throws {
        let event = try #require(TraeXEvent.decodeLine(#"{"hook_event_name":"PostToolUseFailure","session_id":"session-safe","turn_id":"turn-safe","tool_use_id":"tool-safe","tool_name":"Bash","prompt":"private-prompt","tool_input":{"command":"private-command"},"tool_response":{"stdout":"private-output"},"error":"private-error","message":"private-message"}"#))
        let line = try event.encodeLine()

        #expect(line.contains("session-safe"))
        #expect(line.contains("tool-safe"))
        for sensitive in [
            "private-prompt", "private-command", "private-output",
            "private-error", "private-message", "tool_input", "tool_response",
        ] {
            #expect(!line.contains(sensitive))
        }
    }

    @Test func sanitizedDiagnosticExcludesSensitiveBodiesAndRawIdentifiers() throws {
        let event = try #require(TraeXEvent.decodeLine(#"{"hook_event_name":"PostToolUseFailure","session_id":"session-secret","turn_id":"turn-secret","tool_use_id":"tool-secret","tool_name":"request_user_input","prompt":"private-prompt","tool_input":{"question":"private-question"},"tool_response":{"answer":"private-answer"},"error":"private-error","message":"private-message"}"#))
        let line = try #require(event.diagnosticLine(
            observedAt: Date(timeIntervalSince1970: 1_786_000_000),
            transitions: ["question_open->failed"]
        ))

        #expect(line.contains("PostToolUseFailure"))
        #expect(line.contains("question_open->failed"))
        #expect(line.contains("session_id_hash"))
        #expect(line.contains("turn_id_hash"))
        #expect(line.contains("tool_use_id_hash"))
        #expect(!line.contains("session-secret"))
        #expect(!line.contains("turn-secret"))
        #expect(!line.contains("tool-secret"))
        for sensitive in [
            "private-prompt", "private-question", "private-answer",
            "private-error", "private-message", "tool_input", "tool_response",
        ] {
            #expect(!line.contains(sensitive))
        }
    }

    @Test func helperEnvelopeContainsOnlySanitizedDiagnostic() throws {
        let event = try #require(TraeXEvent.decodeLine(#"{"hook_event_name":"PostToolUseFailure","session_id":"session-secret","turn_id":"turn-secret","tool_use_id":"tool-secret","tool_name":"Bash","error":"private-error"}"#))
        let line = try #require(TraeXHookLog.envelopeLine(
            event: event,
            observedAt: Date(timeIntervalSince1970: 1_786_000_000)
        ))

        #expect(line.contains("session_id_hash"))
        #expect(!line.contains("session-secret"))
        #expect(!line.contains("private-error"))
        #expect(!line.contains(#""event""#))
    }

    @Test func hookLogAppendsAndTruncatesWhenOverLimit() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-attention-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let long = String(repeating: "x", count: 120)
        try TraeXHookLog.append(line: long, to: dir, maxBytes: 256)
        try TraeXHookLog.append(line: long, to: dir, maxBytes: 256)
        try TraeXHookLog.append(line: long, to: dir, maxBytes: 256)

        let url = dir.appendingPathComponent(TraeXHookLog.fileName)
        let content = try String(contentsOf: url, encoding: .utf8)
        // 前两次累计 242B < 256B 追加；第三次触发上限截断，仅保留第三行。
        #expect(content == long + "\n")
    }

    /// socket 未就绪时短暂重试（server bind 异步完成）。
    private nonisolated static func retrySend(path: String, line: String) async throws {
        var lastError: Error = NSError(domain: "traex-send", code: -1)
        for _ in 0..<40 {
            do {
                try sendUnixLine(path: path, line: line)
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw lastError
    }

    private nonisolated static func sendUnixLine(path: String, line: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout<sockaddr_un>.size - 1 else {
            throw NSError(domain: "path-too-long", code: -2)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw NSError(domain: "connect", code: Int(errno)) }
        let payload = Array((line + "\n").utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBufferPointer { buf in
                Darwin.write(fd, buf.baseAddress! + sent, payload.count - sent)
            }
            if n <= 0 { throw NSError(domain: "write", code: Int(errno)) }
            sent += n
        }
    }
}

/// .trae/keep-attention.env 解析与 socket 路径优先级（env var > env 文件 > default）。
@Suite struct TraeXHookEnvTests {
    @Test func parsesEnvFileLines() {
        let text = """
        # 注释行
        KEEP_ATTENTION_APP=/Users/dev/orca/keep-attention/keep-attention.app

        KEEP_ATTENTION_SOCKET="/tmp/keep-attention-orca-keep-attention.sock"
        BROKEN_LINE_NO_EQUALS
        =empty_key
        """
        let env = TraeXHookEnv.parse(text)
        #expect(env["KEEP_ATTENTION_APP"] == "/Users/dev/orca/keep-attention/keep-attention.app")
        #expect(env["KEEP_ATTENTION_SOCKET"] == "/tmp/keep-attention-orca-keep-attention.sock")
        #expect(env.count == 2)
    }

    @Test func socketPathPriorityEnvVarOverFileOverDefault() {
        let fileContents = "KEEP_ATTENTION_SOCKET=/tmp/from-file.sock"
        // 1) 环境变量最高
        #expect(TraeXHookEnv.resolveSocketPath(
            environment: ["KEEP_ATTENTION_SOCKET": "/tmp/from-env.sock"],
            envFileContents: fileContents,
            fallback: "/tmp/default.sock"
        ) == "/tmp/from-env.sock")
        // 2) 其次 env 文件
        #expect(TraeXHookEnv.resolveSocketPath(
            environment: [:],
            envFileContents: fileContents,
            fallback: "/tmp/default.sock"
        ) == "/tmp/from-file.sock")
        // 3) 文件缺失/无该键 → default
        #expect(TraeXHookEnv.resolveSocketPath(
            environment: [:],
            envFileContents: nil,
            fallback: "/tmp/default.sock"
        ) == "/tmp/default.sock")
        // 4) 环境变量为空串不生效，落到文件
        #expect(TraeXHookEnv.resolveSocketPath(
            environment: ["KEEP_ATTENTION_SOCKET": "  "],
            envFileContents: fileContents,
            fallback: "/tmp/default.sock"
        ) == "/tmp/from-file.sock")
    }

    @Test func loadsEnvFileAdjacentToAppBundle() throws {
        // 模拟 <项目根>/keep-attention.app + <项目根>/.trae/keep-attention.env
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keep-attention-env-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("keep-attention.app")
        let envDir = root.appendingPathComponent(".trae")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        try "KEEP_ATTENTION_SOCKET=/tmp/adjacent.sock".write(
            to: envDir.appendingPathComponent("keep-attention.env"),
            atomically: true, encoding: .utf8
        )

        #expect(TraeXHookEnv.loadSocketPath(
            environment: [:],
            bundleURL: bundleURL,
            fallback: TraeXEventServer.defaultSocketPath
        ) == "/tmp/adjacent.sock")

        // env 文件不存在 → default
        #expect(TraeXHookEnv.loadSocketPath(
            environment: [:],
            bundleURL: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).app"),
            fallback: TraeXEventServer.defaultSocketPath
        ) == TraeXEventServer.defaultSocketPath)
    }
}
