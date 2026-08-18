import Foundation
import Darwin
import KeepAttentionCore

/// TraeX project hook helper：stdin JSON → bounded JSONL 日志 → unix socket 转发。
/// 任何失败都必须 fail-open（exit 0），绝不阻塞 agent 流程。
enum HookMain {
    static let maxStdinBytes = 10 << 20

    static func run() {
        guard let input = readStdin(limit: maxStdinBytes),
              !input.isEmpty,
              let line = String(data: input, encoding: .utf8),
              let event = TraeXEvent.decodeLine(line),
              event.isSupported
        else { exit(0) }

        let env = ProcessInfo.processInfo.environment
        let cwd = event.cwd ?? FileManager.default.currentDirectoryPath

        // 1) 先落 bounded 日志（.scratch/keep-attention/traex-hook-events.jsonl）。
        if let logLine = envelopeLine(event: event, env: env) {
            try? TraeXHookLog.append(
                line: logLine,
                to: URL(fileURLWithPath: cwd).appendingPathComponent(".scratch/keep-attention")
            )
        }

        // 2) 再尝试 socket 转发；连不上即放弃（app 未启动/已退出均为正常情况）。
        if let payload = try? event.encodeLine() {
            SocketBridge.send(line: payload, path: env["KEEP_ATTENTION_SOCKET"] ?? TraeXEventServer.defaultSocketPath)
        }
        exit(0)
    }

    static func readStdin(limit: Int) -> Data? {
        var data = Data()
        let standardInput = FileHandle.standardInput
        while let chunk = try? standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > limit { return nil }
        }
        return data
    }

    /// 日志外层信封：时间戳 + 事件 + env 诊断信息。
    static func envelopeLine(event: TraeXEvent, env: [String: String]) -> String? {
        guard let eventData = try? JSONEncoder().encode(event),
              let eventObject = (try? JSONSerialization.jsonObject(with: eventData)) as? [String: Any]
        else { return nil }
        var object: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "event": eventObject,
        ]
        if let app = env["KEEP_ATTENTION_APP"] { object["app"] = app }
        if let socket = env["KEEP_ATTENTION_SOCKET"] { object["socket"] = socket }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 非阻塞 connect + poll 超时的 unix socket 发送，防止 app 卡死时挂住 hook。
enum SocketBridge {
    static func send(line: String, path: String, timeoutMs: Int32 = 2000) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard Array(path.utf8).count < MemoryLayout<sockaddr_un>.size - 2 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            guard errno == EINPROGRESS else { return }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, timeoutMs) > 0 else { return }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            guard soError == 0 else { return }
        }

        // 非阻塞写循环（payload 可远大于 socket 缓冲），总预算 3×timeout。
        let payload = Array((line + "\n").utf8)
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) * 3 / 1000)
        var sent = 0
        while sent < payload.count {
            if Date() > deadline { return }
            let n = payload.withUnsafeBufferPointer { buffer in
                Darwin.send(fd, buffer.baseAddress! + sent, payload.count - sent, 0)
            }
            if n > 0 {
                sent += n
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&pollFD, 1, timeoutMs) > 0 else { return }
                continue
            }
            return
        }
    }
}

HookMain.run()
