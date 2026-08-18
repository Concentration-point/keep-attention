import Testing
import Foundation
@testable import KeepAttentionCore

/// OrcaClient 三个 CLI JSON 输出的 Codable 解析（样例取自真实脱敏输出）。
@Suite struct OrcaClientDecodingTests {
    @Test func worktreePSDecodes() throws {
        let result: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        #expect(result.worktrees.count == 2)

        let active = try #require(result.worktrees.first { $0.isActive })
        #expect(active.repo == "repoA")
        #expect(active.worktreeId == "111::/Users/dev/orca/repoA")
        #expect(active.branch == "refs/heads/main")
        #expect(active.status == "working")
        #expect(active.lastOutputAt == 1_786_993_627_799)
        let agent = try #require(active.agents?.first)
        #expect(agent.state == "working")
        #expect(agent.agentType == "grok")
        #expect(agent.lastAssistantMessage == nil)

        let idle = result.worktrees[1]
        #expect(idle.isActive == false)
        #expect(idle.agents?.first?.lastAssistantMessage == "已找到三处风险，需要你确认选 A 还是 B？")
    }

    @Test func terminalListDecodes() throws {
        let result: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        #expect(result.terminals.count == 5)
        #expect(result.totalCount == 5)
        #expect(result.truncated == false)

        let t = try #require(result.terminals.first { $0.handle == "term_A2" })
        #expect(t.worktreeId == "111::/Users/dev/orca/repoA")
        #expect(t.branch == "refs/heads/main")
        #expect(t.title == "repoA · grok")
        #expect(t.connected == true)

        #expect(result.visualLayouts.count == 2)
        let layout = try #require(result.visualLayouts.first { $0.worktreeId == "111::/Users/dev/orca/repoA" })
        #expect(layout.root.activeTabId == "tab2")
        #expect(layout.root.tabs.count == 2)

        // active tab 的 panes 是 pane-split，first 是 active 终端
        let activeTab = try #require(layout.root.tabs.first { $0.tabId == "tab2" })
        guard case .split(let s) = activeTab.panes else {
            Issue.record("active tab panes 应为 pane-split")
            return
        }
        #expect(s.direction == "horizontal")
        guard case .terminal(let first) = s.first else {
            Issue.record("split.first 应为 terminal")
            return
        }
        #expect(first.handle == "term_A2")
        #expect(first.active == true)
        guard case .terminal(let second) = s.second else { return }
        #expect(second.handle == "term_A3")
        #expect(second.active == false)
    }

    @Test func terminalReadDecodes() throws {
        let result: TerminalReadResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalRead))
        #expect(result.terminal.handle == "term_B1")
        #expect(result.terminal.status == "running")
        #expect(result.terminal.tail.count == 5)
        #expect(result.terminal.tail.last == "B. 只返回自然语言分析")
        #expect(result.terminal.returnedLineCount == 5)
        #expect(result.terminal.truncated == false)
    }

    @Test func toleratesMinimalAndUnknownFields() throws {
        // 字段大量缺失/未知 pane 类型时不抛错
        let json = """
        {"ok":true,"result":{"terminals":[{"handle":"h1"}],
        "visualLayouts":[{"worktreeId":"w","root":{"type":"group","activeTabId":null,"tabs":[
          {"tabId":"t1","panes":{"type":"some-future-type","whatever":1}}
        ]}}],"totalCount":1,"truncated":false}}
        """
        let result: TerminalListResult = try OrcaClient.decode(Fixtures.data(json))
        #expect(result.terminals.count == 1)
        #expect(result.terminals[0].handle == "h1")
        guard case .unknown = result.visualLayouts[0].root.tabs[0].panes else {
            Issue.record("未知 pane 类型应解码为 .unknown")
            return
        }
    }

    @Test func decodesViaInjectedRunner() async throws {
        // runCLI 注入：按参数分发固定样例，验证三个入口走对命令
        let recorder = LockedBox([[String]]())
        let client = OrcaClient { args in
            recorder.with { $0.append(args) }
            let joined = args.joined(separator: " ")
            if joined.contains("worktree") { return Fixtures.data(Fixtures.worktreePS) }
            if joined.contains("list") { return Fixtures.data(Fixtures.terminalList) }
            return Fixtures.data(Fixtures.terminalRead)
        }
        let ps = try await client.worktreePS()
        let list = try await client.terminalList()
        let read = try await client.terminalRead(handle: "term_B1")
        #expect(ps.worktrees.count == 2)
        #expect(list.terminals.count == 5)
        #expect(read.tail.count == 5)
        let commands = recorder.with { $0 }
        #expect(commands.contains(["worktree", "ps", "--json"]))
        #expect(commands.contains(["terminal", "list", "--include-visual-layouts", "--json"]))
        #expect(commands.contains(["terminal", "read", "--terminal", "term_B1", "--json"]))
    }

    // MARK: - terminal switch（issue #15）
    // 真实行为：业务失败时进程仍 exit 0，成败只看信封 ok 字段（probe 自本机 orca CLI）。

    @Test func terminalSwitchSendsHandleAndJSONFlag() async throws {
        let recorder = LockedBox([[String]]())
        let client = OrcaClient { args in
            recorder.with { $0.append(args) }
            return Fixtures.data(#"{"id":"cmd-s1","ok":true,"result":{}}"#)
        }
        try await client.terminalSwitch(handle: "term_B1")
        #expect(recorder.with { $0 } == [["terminal", "switch", "--terminal", "term_B1", "--json"]])
    }

    @Test func terminalSwitchThrowsOnBusinessFailure() async throws {
        let client = OrcaClient { _ in
            Fixtures.data(#"{"id":"cmd-s2","ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}"#)
        }
        do {
            try await client.terminalSwitch(handle: "term_gone")
            Issue.record("ok=false 应抛错")
        } catch let error as OrcaError {
            #expect(error == .commandFailed("terminal_handle_stale"))
        } catch {
            Issue.record("应抛 OrcaError，实际 \(error)")
        }
    }

    @Test func terminalSwitchThrowsOnMalformedOutput() async throws {
        let client = OrcaClient { _ in Fixtures.data("not json") }
        do {
            try await client.terminalSwitch(handle: "term_B1")
            Issue.record("非 JSON 输出应抛错")
        } catch let error as OrcaError {
            #expect(error == .emptyOutput)
        } catch {
            Issue.record("应抛 OrcaError，实际 \(error)")
        }
    }
}
