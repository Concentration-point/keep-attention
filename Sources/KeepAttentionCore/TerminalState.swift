import Foundation
import CryptoKit

// MARK: - 忙闲状态

/// 终端忙闲枚举（spec §2）：绿=忙 / 琥珀=等待输入 / 灰=空闲。
public enum TerminalActivityStatus: String, Equatable, Sendable {
    case busy
    case waitingForInput
    case idle
}

// MARK: - 四段式摘要

/// DeepSeek 输出的四段式摘要（spec §3）。
public struct TerminalSummary: Codable, Equatable, Sendable {
    public var currentTask: String
    public var progress: String
    public var nextStep: String
    public var needsInput: String

    public init(currentTask: String, progress: String, nextStep: String, needsInput: String) {
        self.currentTask = currentTask
        self.progress = progress
        self.nextStep = nextStep
        self.needsInput = needsInput
    }

    private enum CodingKeys: String, CodingKey {
        case currentTask
        case progress
        case nextStep
        case needsInput
    }

    /// Accepts the string values requested by the prompt as well as primitive model output.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentTask = try Self.decodeText(forKey: .currentTask, in: container, fallback: "未知")
        progress = try Self.decodeText(forKey: .progress, in: container, fallback: "未知")
        nextStep = try Self.decodeText(forKey: .nextStep, in: container, fallback: "未知")
        needsInput = try Self.decodeText(forKey: .needsInput, in: container, fallback: "无", boolean: true)
    }

    private static func decodeText(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        fallback: String,
        boolean: Bool = false
    ) throws -> String {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return fallback }
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Bool.self, forKey: key) {
            if boolean { return value ? "需要输入" : "无" }
            return String(value)
        }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(value) }
        return fallback
    }
}

/// 单个终端摘要的可用状态；failed/unavailable 携带 UI 直接显示的文案。
public enum SummaryState: Equatable, Sendable {
    case unavailable(String)
    case loading
    case ready(TerminalSummary)
    case failed(String)
}

public extension SummaryState {
    var hasStructuredResult: Bool {
        switch self {
        case .loading, .ready, .failed:
            return true
        case .unavailable:
            return false
        }
    }
}

/// 展开列表行的稳定视觉状态（issue #16）。
public enum TerminalListVisualState: String, Equatable, Sendable {
    case waiting
    case newResult
    case running
    case idle
    case unavailable

    public static func resolve(status: TerminalActivityStatus, summary: SummaryState) -> TerminalListVisualState {
        if status == .waitingForInput { return .waiting }
        if summary.hasStructuredResult { return .newResult }
        if status == .busy { return .running }
        switch summary {
        case .unavailable:
            return .unavailable
        case .loading, .ready, .failed:
            return .newResult
        }
    }
}

/// 送入总结器的上下文。hook-only 模式下只使用结构化 agent 消息，tail 为空。
public struct SummaryContext: Equatable, Sendable {
    var repo: String
    var branch: String?
    var title: String?
    var agentMessage: String?
    var tail: [String]

    public init(repo: String, branch: String?, title: String?, agentMessage: String?, tail: [String]) {
        self.repo = repo
        self.branch = branch
        self.title = title
        self.agentMessage = agentMessage
        self.tail = tail
    }
}

// MARK: - 内容指纹（去重键）

/// 终端内容指纹：渲染 tail 文本的 SHA256（spec §3 去重键）。
public func contentFingerprint(_ tail: [String]) -> String {
    SHA256.hash(data: Data(tail.joined(separator: "\n").utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

// MARK: - 忙闲判定

/// 忙闲判定输入。
public struct StatusInput: Sendable {
    var agentStates: [String]
    var worktreeStatus: String?
    var lastOutputAt: Date?
    var tail: [String]?
    var now: Date

    public init(agentStates: [String], worktreeStatus: String?, lastOutputAt: Date?, tail: [String]?, now: Date) {
        self.agentStates = agentStates
        self.worktreeStatus = worktreeStatus
        self.lastOutputAt = lastOutputAt
        self.tail = tail
        self.now = now
    }
}

/// 忙闲判定（spec §2）：
/// 有 agents[].state 时用它；否则用 worktree status + lastOutputAt 新鲜度近似。
/// waitingForInput 由 agent state 指示，或渲染文本尾部出现提问/确认提示；
/// 拿不准一律归 .busy，不乱报等待。
public enum StatusResolver {
    /// agent state 里表示"等待用户"的取值（大小写不敏感）。
    static let waitingStates: Set<String> = [
        "waiting", "waitingforinput", "waiting-for-input", "needsinput",
        "needs-input", "awaitinginput", "awaiting-input", "blocked",
    ]

    /// "新鲜输出"阈值：30s 内有输出视为忙。
    static let outputFreshness: TimeInterval = 30

    /// 检查尾部提问的窗口行数。
    static let promptWindowLines = 8

    static func resolve(_ input: StatusInput) -> TerminalActivityStatus {
        let states = input.agentStates.map { $0.lowercased() }
        if states.contains(where: { waitingStates.contains($0) }) {
            return .waitingForInput
        }
        if states.contains("working") {
            return .busy
        }
        let fresh = input.lastOutputAt.map {
            input.now.timeIntervalSince($0) < outputFreshness
        } ?? false
        if input.worktreeStatus == "working" && fresh {
            return .busy
        }
        if hasWaitingPrompt(input.tail) {
            return .waitingForInput
        }
        return .idle
    }

    /// 启发式：尾部若干行里有明显提问/确认提示（"?"/"？"结尾或 y/n）。
    static func hasWaitingPrompt(_ tail: [String]?) -> Bool {
        guard let lines = tail?.suffix(promptWindowLines) else { return false }
        return lines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            return t.hasSuffix("?") || t.hasSuffix("？")
                || t.contains("y/n") || t.contains("[y/N]") || t.contains("Y/n")
        }
    }
}

// MARK: - 脱敏/裁剪（spec §7）

/// 发给云端总结器前的本地脱敏。目标是去掉高风险凭证/身份信息，而不是做语义改写。
public func redact(_ text: String) -> String {
    var output = text
    let replacements: [(pattern: String, replacement: String, options: NSRegularExpression.Options)] = [
        (
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            "[REDACTED_PRIVATE_KEY]",
            []
        ),
        (
            #"(?i)\b(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
            "$1[REDACTED_TOKEN]",
            [.caseInsensitive]
        ),
        (
            #"\b(sk-[A-Za-z0-9_-]{8,}|gho_[A-Za-z0-9_]{8,}|ghp_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]+)\b"#,
            "[REDACTED_TOKEN]",
            []
        ),
        (
            #"(?i)\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|session[_-]?token|password|passwd|pwd)\s*[:=]\s*)[^\s"']+"#,
            "$1[REDACTED_SECRET]",
            [.caseInsensitive]
        ),
        (
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            "[REDACTED_EMAIL]",
            [.caseInsensitive]
        ),
        (
            #"/Users/[^/\s]+/"#,
            "/Users/[USER]/",
            []
        ),
    ]

    for item in replacements {
        guard let regex = try? NSRegularExpression(pattern: item.pattern, options: item.options) else { continue }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        output = regex.stringByReplacingMatches(in: output, options: [], range: range, withTemplate: item.replacement)
    }
    return output
}

/// 脱敏后按字符数裁剪，保留开头语义并显式标记截断。
public func redactAndTruncate(_ text: String, maxCharacters: Int) -> String {
    let sanitized = redact(text)
    guard sanitized.count > maxCharacters else { return sanitized }
    let prefix = sanitized.prefix(maxCharacters)
    return "\(prefix)\n…[已截断 \(sanitized.count - maxCharacters) 字符]"
}

public enum ContextExportPolicy {
    public static let maxAgentMessageCharacters = 6_000
    public static let maxTailLines = 40
    public static let maxTailCharacters = 6_000
}
