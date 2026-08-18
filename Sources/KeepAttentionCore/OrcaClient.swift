import Foundation

// MARK: - CLI 输出线格式（wire models）

/// 所有 orca --json 输出的统一外层信封。
struct CLIEnvelope<Result: Decodable & Sendable>: Decodable, Sendable {
    let ok: Bool
    let result: Result
}

// worktree ps

public struct WorktreePSResult: Decodable, Equatable, Sendable {
    var worktrees: [WorktreeInfo]
}

public struct WorktreeInfo: Decodable, Equatable, Sendable {
    var worktreeId: String
    var repo: String
    var path: String?
    var branch: String?
    var status: String?
    var isActive: Bool
    var lastOutputAt: Double?
    var agents: [AgentInfo]?

    var lastOutputDate: Date? {
        lastOutputAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// 分支短名："refs/heads/main" → "main"。
    var shortBranch: String? {
        guard let branch else { return nil }
        return branch.replacingOccurrences(of: "refs/heads/", with: "")
    }
}

public struct AgentInfo: Decodable, Equatable, Sendable {
    var paneKey: String?
    var state: String?
    var agentType: String?
    var prompt: String?
    var taskTitle: String?
    var lastAssistantMessage: String?
    var toolName: String?
    var toolInput: String?
    var updatedAt: Double?
}

// terminal list

public struct TerminalListResult: Decodable, Equatable, Sendable {
    var terminals: [TerminalInfo]
    var visualLayouts: [VisualLayout]
    var totalCount: Int?
    var truncated: Bool?
}

public struct TerminalInfo: Decodable, Equatable, Sendable, Identifiable {
    var handle: String
    var worktreeId: String?
    var worktreePath: String?
    var branch: String?
    var tabId: String?
    var leafId: String?
    var title: String?
    var connected: Bool?
    var lastOutputAt: Double?
    var preview: String?

    public var id: String { handle }
    var lastOutputDate: Date? {
        lastOutputAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
    var shortBranch: String? {
        guard let branch else { return nil }
        return branch.replacingOccurrences(of: "refs/heads/", with: "")
    }
}

public struct VisualLayout: Decodable, Equatable, Sendable {
    var worktreeId: String?
    var worktreePath: String?
    var root: PaneGroup
}

/// 布局根节点：group（含 tabs 与 activeTabId）。
public struct PaneGroup: Decodable, Equatable, Sendable {
    var type: String?
    var groupId: String?
    var activeTabId: String?
    var tabs: [LayoutTab]
}

public struct LayoutTab: Decodable, Equatable, Sendable {
    var tabId: String?
    var title: String?
    var activeLeafId: String?
    var panes: PaneNode
}

/// 面板树节点：terminal 叶子 / pane-split 分屏 / 未来类型。
public indirect enum PaneNode: Decodable, Equatable, Sendable {
    case terminal(PaneTerminal)
    case split(PaneSplit)
    case unknown

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "terminal":
            self = .terminal(try PaneTerminal(from: decoder))
        case "pane-split":
            self = .split(try PaneSplit(from: decoder))
        default:
            self = .unknown
        }
    }
}

public struct PaneTerminal: Decodable, Equatable, Sendable {
    var handle: String?
    var tabId: String?
    var leafId: String?
    var title: String?
    var connected: Bool?
    var active: Bool?
}

public struct PaneSplit: Decodable, Equatable, Sendable {
    var direction: String?
    var first: PaneNode
    var second: PaneNode
}

// terminal read

public struct TerminalReadResult: Decodable, Equatable, Sendable {
    var terminal: TerminalRead
}

public struct TerminalRead: Decodable, Equatable, Sendable {
    var handle: String?
    var status: String?
    var tail: [String]
    var truncated: Bool?
    var limited: Bool?
    var returnedLineCount: Int?
}

// MARK: - 错误

public enum OrcaError: Error, Equatable {
    case missingBinary(String)
    case exit(Int32)
    case emptyOutput
    /// 进程 exit 0 但信封 ok=false 的业务失败（如 terminal switch 的 terminal_handle_stale）。
    case commandFailed(String?)
}

// MARK: - 客户端

/// 通过短命 `Process` 调 orca CLI，解析 --json 输出。
/// `runCLI` 可注入，测试喂固定 JSON 样例。
public struct OrcaClient: Sendable {
    public static let defaultBinaryPath = "/usr/local/bin/orca"

    var runCLI: @Sendable ([String]) async throws -> Data

    public init(_ runCLI: @escaping @Sendable ([String]) async throws -> Data) {
        self.runCLI = runCLI
    }

    /// 真实实现：`Process` 调 orca 可执行文件。
    public static func live(binaryPath: String = defaultBinaryPath) -> OrcaClient {
        OrcaClient { args in
            guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
                throw OrcaError.missingBinary(binaryPath)
            }
            return try await Self.runProcess(binaryPath, args)
        }
    }

    /// 同步执行子进程并取 stdout（在 detached task 上跑，避免阻塞协作线程池）。
    static func runProcess(_ path: String, _ args: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                throw OrcaError.missingBinary(path)
            }
            // 先读后等：读阻塞到 EOF（进程退出），再收割退出码，避免管道写满死锁。
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw OrcaError.exit(process.terminationStatus)
            }
            return data
        }.value
    }

    // MARK: 三个数据入口（每 tick 恒定前 2 个 + 按需 read）

    public func worktreePS() async throws -> WorktreePSResult {
        try Self.decode(await runCLI(["worktree", "ps", "--json"]))
    }

    public func terminalList() async throws -> TerminalListResult {
        try Self.decode(await runCLI(["terminal", "list", "--include-visual-layouts", "--json"]))
    }

    public func terminalRead(handle: String) async throws -> TerminalRead {
        let result: TerminalReadResult = try Self.decode(
            await runCLI(["terminal", "read", "--terminal", handle, "--json"])
        )
        return result.terminal
    }

    /// 跳转到指定终端（issue #15）：`terminal switch --terminal <handle> --json`。
    /// 该命令业务失败时进程仍 exit 0，成败只看信封 ok 字段（见 decodeStatus）。
    public func terminalSwitch(handle: String) async throws {
        try Self.decodeStatus(await runCLI(["terminal", "switch", "--terminal", handle, "--json"]))
    }

    /// switch 类命令的结果信封：不消费 result 内容，只区分 ok / error。
    private struct CLIStatusEnvelope: Decodable {
        let ok: Bool
        let error: CLIErrorInfo?
    }

    private struct CLIErrorInfo: Decodable {
        let code: String?
        let message: String?
    }

    /// 解析 ok/error 信封：ok=false → commandFailed；结构非法 → emptyOutput。
    static func decodeStatus(_ data: Data) throws {
        do {
            let envelope = try JSONDecoder().decode(CLIStatusEnvelope.self, from: data)
            guard envelope.ok else {
                throw OrcaError.commandFailed(envelope.error?.message)
            }
        } catch let error as OrcaError {
            throw error
        } catch {
            throw OrcaError.emptyOutput
        }
    }

    /// 信封解包（也供测试直接喂样例 Data）。
    public static func decode<T: Decodable & Sendable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(CLIEnvelope<T>.self, from: data).result
        } catch {
            throw OrcaError.emptyOutput
        }
    }
}
