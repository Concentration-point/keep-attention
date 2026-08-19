import Foundation
import Darwin

// MARK: - TraeX hook 事件

/// TraeX 项目 hook 经 unix socket 送入 app 的一行 JSON 事件。
/// 字段全部可选：helper 端与 hook payload 版本解耦，未知字段忽略。
public struct TraeXEvent: Codable, Equatable, Sendable {
    public var hookEventName: String?
    public var sessionId: String?
    public var turnId: String?
    public var cwd: String?
    public var prompt: String?
    public var lastAssistantMessage: String?
    public var toolUseId: String?
    public var toolName: String?
    public var source: String?
    public var reason: String?
    public var notificationType: String?
    public var stopHookActive: Bool?

    public init(
        hookEventName: String?,
        sessionId: String? = nil,
        turnId: String? = nil,
        cwd: String? = nil,
        prompt: String? = nil,
        lastAssistantMessage: String? = nil,
        toolUseId: String? = nil,
        toolName: String? = nil,
        source: String? = nil,
        reason: String? = nil,
        notificationType: String? = nil,
        stopHookActive: Bool? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.turnId = turnId
        self.cwd = cwd
        self.prompt = prompt
        self.lastAssistantMessage = lastAssistantMessage
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.source = source
        self.reason = reason
        self.notificationType = notificationType
        self.stopHookActive = stopHookActive
    }

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case turnId = "turn_id"
        case cwd
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case toolUseId = "tool_use_id"
        case toolName = "tool_name"
        case source
        case reason
        case notificationType = "notification_type"
        case stopHookActive = "stop_hook_active"
    }

    public var isSupported: Bool {
        switch hookEventName {
        case Self.sessionStart, Self.sessionEnd, Self.permissionRequest,
             Self.preToolUse, Self.postToolUse, Self.postToolUseFailure,
             Self.notification, Self.userPromptSubmit, Self.stop:
            true
        default:
            false
        }
    }

    public static let sessionStart = "SessionStart"
    public static let sessionEnd = "SessionEnd"
    public static let permissionRequest = "PermissionRequest"
    public static let preToolUse = "PreToolUse"
    public static let postToolUse = "PostToolUse"
    public static let postToolUseFailure = "PostToolUseFailure"
    public static let notification = "Notification"
    public static let userPromptSubmit = "UserPromptSubmit"
    public static let stop = "Stop"

    public static func decodeLine(_ line: String) -> TraeXEvent? {
        guard let data = line.data(using: .utf8),
              var event = try? JSONDecoder().decode(TraeXEvent.self, from: data)
        else { return nil }
        if event.hookEventName != Self.userPromptSubmit && event.hookEventName != Self.stop {
            event.prompt = nil
            event.lastAssistantMessage = nil
        }
        return event
    }

    /// 规范化为单行 JSON（helper 转发与日志落盘共用）。
    public func encodeLine() throws -> String {
        var encoded = self
        if hookEventName != Self.userPromptSubmit && hookEventName != Self.stop {
            encoded.prompt = nil
            encoded.lastAssistantMessage = nil
        }
        let data = try JSONEncoder().encode(encoded)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return line
    }

    /// 仅记录字段形状、关联 ID 哈希和状态迁移；不持久化任何正文或原始 payload。
    public func diagnosticLine(observedAt: Date, transitions: [String] = []) -> String? {
        var object: [String: Any] = [
            "ts": observedAt.timeIntervalSince1970,
            "event_name": hookEventName ?? "unknown",
            "field_shape": diagnosticFieldShape,
            "transitions": transitions,
        ]
        if let sessionId { object["session_id_hash"] = Self.stableHash(sessionId) }
        if let turnId { object["turn_id_hash"] = Self.stableHash(turnId) }
        if let toolUseId { object["tool_use_id_hash"] = Self.stableHash(toolUseId) }
        if let toolName { object["tool_name"] = toolName }
        if let source { object["source"] = source }
        if let reason { object["reason"] = reason }
        if let notificationType { object["notification_type"] = notificationType }
        if let stopHookActive { object["stop_hook_active"] = stopHookActive }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private var diagnosticFieldShape: [String] {
        var fields = ["hook_event_name"]
        if sessionId != nil { fields.append("session_id") }
        if turnId != nil { fields.append("turn_id") }
        if cwd != nil { fields.append("cwd") }
        if prompt != nil { fields.append("prompt") }
        if lastAssistantMessage != nil { fields.append("last_assistant_message") }
        if toolUseId != nil { fields.append("tool_use_id") }
        if toolName != nil { fields.append("tool_name") }
        if source != nil { fields.append("source") }
        if reason != nil { fields.append("reason") }
        if notificationType != nil { fields.append("notification_type") }
        if stopHookActive != nil { fields.append("stop_hook_active") }
        return fields.sorted()
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Unix socket server（app 进程内）

/// 接收 hook helper 的 JSON line 事件。
/// POSIX socket + DispatchSource 实现（NWListener 对 unix endpoint 的连接回调不可靠）；
/// 所有状态只在串行 queue 上访问。
public final class TraeXEventServer: @unchecked Sendable {
    /// .trae/keep-attention.env 与 helper 默认值三处保持一致。
    public static let defaultSocketPath = "/tmp/keep-attention-orca-keep-attention.sock"

    public let socketPath: String
    private let onEvent: @Sendable (TraeXEvent) -> Void
    private let queue = DispatchQueue(label: "keep-attention.traex.server")
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]

    public init(socketPath: String, onEvent: @escaping @Sendable (TraeXEvent) -> Void) {
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    public func start() throws {
        guard Array(socketPath.utf8).count < MemoryLayout<sockaddr_un>.size - 2 else {
            throw TraeXEventServerError.pathTooLong(socketPath)
        }
        // 上一实例残留的 socket 文件会让 bind 失败，先清理。
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TraeXEventServerError.listenFailed("socket: \(errno)")
        }
        // 非阻塞：acceptPending 在串行 queue 上排空积压连接后靠 EAGAIN 退出。
        let listenFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, listenFlags | O_NONBLOCK)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw TraeXEventServerError.listenFailed("bind: \(errno)")
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw TraeXEventServerError.listenFailed("listen: \(code)")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(fd)
            if self.listenFD == fd { self.listenFD = -1 }
        }
        queue.sync {
            self.listenFD = fd
            self.listenSource = source
        }
        source.resume()
    }

    public func stop() {
        queue.sync {
            listenSource?.cancel()
            listenSource = nil
            for fd in clientSources.keys {
                closeClient(fd)
            }
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    // MARK: - 连接处理（queue 上）

    private func acceptPending() {
        while listenFD >= 0 {
            var client = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let accepted = withUnsafeMutablePointer(to: &client) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &len)
                }
            }
            if accepted >= 0 {
                setupClient(accepted)
                continue
            }
            // EINTR/连接夭折：继续排空剩余积压，避免漏掉已 pending 的连接。
            if errno == EINTR || errno == ECONNABORTED { continue }
            return
        }
    }

    private func setupClient(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        buffers[fd] = Data()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(fd) }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(fd)
            self.clientSources[fd] = nil
            self.buffers[fd] = nil
        }
        clientSources[fd] = source
        source.resume()
    }

    private func readAvailable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffers[fd, default: Data()].append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 {
                // 对端关闭：把无换行结尾的残余行也处理掉。
                drainLines(fd, flush: true)
                closeClient(fd)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN { break }
            closeClient(fd)
            return
        }
        drainLines(fd, flush: false)
    }

    private func drainLines(_ fd: Int32, flush: Bool) {
        guard var buffer = buffers[fd] else { return }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            handleLine(Data(lineData))
        }
        if flush, !buffer.isEmpty {
            handleLine(Data(buffer))
            buffer.removeAll()
        }
        buffers[fd] = buffer
    }

    private func handleLine(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8),
              let event = TraeXEvent.decodeLine(line)
        else { return }
        onEvent(event)
    }

    private func closeClient(_ fd: Int32) {
        clientSources[fd]?.cancel()
    }
}

public enum TraeXEventServerError: Error, Equatable {
    case pathTooLong(String)
    case listenFailed(String)
}

// MARK: - .trae/keep-attention.env 解析

/// 项目级 env 文件解析：KEY=VALUE 行，忽略空行/# 注释，剥除成对引号。
/// socket 路径优先级：ProcessInfo 环境变量 > env 文件 > default。
public enum TraeXHookEnv {
    public static let socketKey = "KEEP_ATTENTION_SOCKET"
    public static let appKey = "KEEP_ATTENTION_APP"
    /// app bundle 相邻项目根下的 env 文件相对路径。
    public static let envFileRelativePath = ".trae/keep-attention.env"

    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
               || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// 纯函数版：environment > envFileContents > fallback。
    public static func resolveSocketPath(
        environment: [String: String],
        envFileContents: String?,
        fallback: String
    ) -> String {
        if let fromEnv = environment[socketKey]?.trimmingCharacters(in: .whitespaces), !fromEnv.isEmpty {
            return fromEnv
        }
        if let contents = envFileContents,
           let fromFile = parse(contents)[socketKey]?.trimmingCharacters(in: .whitespaces), !fromFile.isEmpty {
            return fromFile
        }
        return fallback
    }

    /// app 进程用：读 <bundle 相邻项目根>/.trae/keep-attention.env。
    public static func loadSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL,
        fallback: String = TraeXEventServer.defaultSocketPath
    ) -> String {
        let envFileURL = bundleURL.deletingLastPathComponent()
            .appendingPathComponent(envFileRelativePath)
        let contents = try? String(contentsOf: envFileURL, encoding: .utf8)
        return resolveSocketPath(environment: environment, envFileContents: contents, fallback: fallback)
    }
}

// MARK: - Bounded JSONL 日志（helper 复用）

/// helper 的 fail-open 本地日志：<cwd>/.scratch/keep-attention/traex-hook-events.jsonl。
/// 追加前检查大小，超过上限整文件重置（保留最新一条之后的行为），任何失败由调用方吞掉。
public enum TraeXHookLog {
    public static let fileName = "traex-hook-events.jsonl"
    public static let defaultMaxBytes = 512 * 1024

    public static func envelopeLine(event: TraeXEvent, observedAt: Date = Date()) -> String? {
        event.diagnosticLine(observedAt: observedAt)
    }

    public static func append(line: String, to directory: URL, maxBytes: Int = defaultMaxBytes) throws {
        let url = directory.appendingPathComponent(fileName)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        // 累计会超上限时整文件重置（bounded），只保留本次写入。
        let existing = (try? Data(contentsOf: url)) ?? Data()
        if existing.count + data.count > maxBytes {
            try? fm.removeItem(at: url)
        }
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
