import Testing
import Foundation
import Darwin
@testable import KeepAttentionCore

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
