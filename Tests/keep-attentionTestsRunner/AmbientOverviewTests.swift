import Foundation
import Testing
@testable import KeepAttentionCore

@Suite struct AmbientOverviewTests {
    private let observedAt = Date(timeIntervalSince1970: 1_786_100_100)

    @Test func terminalListProjectsAmbientEntriesMarkedNotRequest() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))

        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt
        )

        #expect(result.events.isEmpty)
        #expect(result.ambient.entries.count == list.terminals.count)
        #expect(result.ambient.entries.allSatisfy { $0.classification == .notRequest })
        #expect(result.ambient.entries.first { $0.terminalHandle == "term_A2" }?.isFocused == true)
    }

    @Test func projectionCarriesSafeTerminalContextWithoutPreview() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))

        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt
        )

        let entry = try #require(result.ambient.entries.first { $0.terminalHandle == "term_A2" })
        #expect(entry.worktreeID == "111::/Users/dev/orca/repoA")
        #expect(entry.repository == "repoA")
        #expect(entry.branch == "main")
        #expect(entry.title == "repoA · grok")
        #expect(entry.connected == true)
        #expect(entry.lastOutputAt == Date(timeIntervalSince1970: 1_786_993_627.799))
    }

    @Test func projectsBusyIdleAndStructuredCoverageWithoutCreatingRequests() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))

        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt
        )

        #expect(result.events.isEmpty)
        let busy = try #require(result.ambient.entries.first { $0.terminalHandle == "term_A2" })
        #expect(busy.activity == .busy)
        #expect(busy.coverage == .structuredAgent)

        let idle = try #require(result.ambient.entries.first { $0.terminalHandle == "term_B1" })
        #expect(idle.activity == .idle)
        #expect(idle.coverage == .structuredAgent)
    }

    @Test func noHookTerminalBecomesCoverageGapMarkedNotRequest() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))

        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt
        )

        let noHook = try #require(result.ambient.entries.first { $0.terminalHandle == "term_A3" })
        #expect(noHook.coverage == .coverageGap)
        #expect(noHook.classification == .notRequest)
        #expect(noHook.activity == .busy)
        #expect(result.events.isEmpty)
    }

    @Test func terminalTailQuestionAndOrdinaryDoneLogCannotCreateOrResolveRequests() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        let terminalRead: TerminalReadResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalRead))

        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt,
            terminalReads: [
                terminalRead.terminal,
                TerminalRead(handle: "term_A1", status: "done", tail: ["ordinary done", "build log"]),
            ]
        )

        #expect(result.events.isEmpty)
        #expect(result.ambient.entries.count == list.terminals.count)
        #expect(result.ambient.entries.allSatisfy { $0.classification == .notRequest })
    }

    @Test func disconnectedTerminalRemainsAmbientNotRequest() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        var terminals = list.terminals
        terminals[0].connected = false

        let result = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: terminals,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt
        )

        let disconnected = try #require(result.ambient.entries.first { $0.terminalHandle == "term_A1" })
        #expect(disconnected.connected == false)
        #expect(disconnected.classification == .notRequest)
        #expect(result.events.isEmpty)
    }

    @Test func previewQuestionAndDoneTextDoNotAffectProjectionOrEvents() throws {
        let ps: WorktreePSResult = try OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
        let list: TerminalListResult = try OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
        var changed = list.terminals
        changed[0].preview = "Do you want to continue?"
        changed[2].preview = "ordinary done log"

        let baseline = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt
        )
        let withPreviewText = OrcaAttentionAdapter.adapt(
            snapshot: .init(
                worktrees: ps.worktrees,
                terminals: changed,
                layouts: list.visualLayouts
            ),
            supervisedSignals: [],
            observedAt: observedAt
        )

        #expect(withPreviewText.events.isEmpty)
        #expect(withPreviewText == baseline)
    }
}
