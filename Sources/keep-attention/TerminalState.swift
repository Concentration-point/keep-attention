import Foundation
import CryptoKit

// MARK: - 忙闲状态

/// 终端忙闲枚举（spec §2）：绿=忙 / 琥珀=等待输入 / 灰=空闲。
enum TerminalActivityStatus: String, Equatable, Sendable {
    case busy
    case waitingForInput
    case idle
}

// MARK: - 四段式摘要

/// DeepSeek 输出的四段式摘要（spec §3）。
struct TerminalSummary: Codable, Equatable, Sendable {
    var currentTask: String
    var progress: String
    var nextStep: String
    var needsInput: String
}

/// 单个终端摘要的可用状态；failed 携带 UI 直接显示的文案。
enum SummaryState: Equatable, Sendable {
    case loading
    case ready(TerminalSummary)
    case failed(String)
}

/// 送入总结器的上下文（双通道：结构化 agent 消息 + 渲染 tail）。
struct SummaryContext: Equatable, Sendable {
    var repo: String
    var branch: String?
    var title: String?
    var agentMessage: String?
    var tail: [String]
}

// MARK: - 内容指纹（去重键）

/// 终端内容指纹：渲染 tail 文本的 SHA256（spec §3 去重键）。
func contentFingerprint(_ tail: [String]) -> String {
    SHA256.hash(data: Data(tail.joined(separator: "\n").utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

// MARK: - 忙闲判定

/// 忙闲判定输入。
struct StatusInput: Sendable {
    var agentStates: [String]
    var worktreeStatus: String?
    var lastOutputAt: Date?
    var tail: [String]?
    var now: Date
}

/// 忙闲判定（spec §2）：
/// 有 agents[].state 时用它；否则用 worktree status + lastOutputAt 新鲜度近似。
/// waitingForInput 由 agent state 指示，或渲染文本尾部出现提问/确认提示；
/// 拿不准一律归 .busy，不乱报等待。
enum StatusResolver {
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

// MARK: - 脱敏钩子（占位，默认透传；spec §7）

/// 上下文脱敏钩子。MVP 直接透传，后续 #7 在此实现真正的脱敏。
func redact(_ text: String) -> String {
    text
}
