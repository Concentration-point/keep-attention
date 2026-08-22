import Foundation
import Testing
@testable import KeepAttentionCore

@MainActor
@Suite struct AttentionQueueInteractionTests {
    @Test func tc05SeenActionKeepsRequestActive() {
        let harness = AttentionQueueInteractionHarness.permission()

        harness.perform(.markSeen)

        #expect(harness.model.projection.requestCount == 1)
        #expect(harness.model.projection.queueHead?.statusLabel == "Seen != Resolved")
    }

    @Test func tc06SnoozeActionMovesRequestIntoSnoozedFold() {
        let harness = AttentionQueueInteractionHarness.permission()
        let wakeAt = harness.now.addingTimeInterval(5 * 60)

        harness.perform(.snooze(until: wakeAt))

        #expect(harness.model.projection.requestCount == 0)
        #expect(harness.model.projection.snoozed.count == 1)
    }

    @Test func tc08JumpActionDelegatesToSessionAwareJumper() async {
        let harness = AttentionQueueInteractionHarness.permission(includeOrcaSnapshot: true)

        let outcome = await harness.performJump()

        guard case .succeeded(let success) = outcome else {
            Issue.record("期望 Jump 成功，实际 \(String(describing: outcome))")
            return
        }
        #expect(success.route.terminalHandle == "term_A2")
    }

    @Test func tc09RestartTurnsActiveRequestIntoStateConfirmation() {
        let harness = AttentionQueueInteractionHarness.permission()

        let restarted = harness.restart()

        #expect(restarted.projection.requestCount == 0)
        #expect(restarted.projection.staleHistory.count == 1)
        #expect(restarted.projection.staleHistory.first?.statusLabel == "Stale = state needs confirmation")
    }
}

@MainActor
private final class AttentionQueueInteractionHarness {
    enum Action {
        case markSeen
        case snooze(until: Date)
    }

    let model: AttentionQueueModel
    let now: Date
    private let defaults: InteractionDefaults
    private let orca: OrcaClient

    private init(model: AttentionQueueModel, now: Date, defaults: InteractionDefaults, orca: OrcaClient) {
        self.model = model
        self.now = now
        self.defaults = defaults
        self.orca = orca
    }

    static func permission(includeOrcaSnapshot: Bool = false) -> AttentionQueueInteractionHarness {
        let now = Date(timeIntervalSince1970: 8_000_000)
        let defaults = InteractionDefaults()
        let orca = OrcaClient { args in
            let joined = args.joined(separator: " ")
            if joined.contains("switch") { return Data(#"{"ok":true}"#.utf8) }
            if joined.contains("worktree") { return Fixtures.data(Fixtures.worktreePS) }
            return Fixtures.data(Fixtures.terminalList)
        }
        let model = AttentionQueueModel(
            orca: orca,
            jumper: SessionAwareJumper(client: orca),
            defaults: defaults,
            now: { now }
        )
        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.sessionStart,
            sessionId: "interaction-session",
            cwd: "/Users/dev/orca/repoA"
        ))
        model.applyTraeXEvent(TraeXEvent(
            hookEventName: TraeXEvent.permissionRequest,
            sessionId: "interaction-session",
            turnId: "interaction-turn",
            toolUseId: "interaction-tool",
            toolName: "Bash"
        ))
        if includeOrcaSnapshot {
            let ps: WorktreePSResult = try! OrcaClient.decode(Fixtures.data(Fixtures.worktreePS))
            let list: TerminalListResult = try! OrcaClient.decode(Fixtures.data(Fixtures.terminalList))
            model.applyOrcaSnapshot(FocusResolver.Snapshot(
                worktrees: ps.worktrees,
                terminals: list.terminals,
                layouts: list.visualLayouts
            ))
        }
        return AttentionQueueInteractionHarness(model: model, now: now, defaults: defaults, orca: orca)
    }

    func perform(_ action: Action) {
        let actions = AttentionQueueActions.live(model: model)
        switch action {
        case .markSeen:
            actions.onMarkSeen?()
        case .snooze(let until):
            actions.onSnooze?(until)
        }
    }

    func performJump() async -> JumpOutcome? {
        await AttentionQueueActions.live(model: model).performJump?()
    }

    func restart() -> AttentionQueueModel {
        AttentionQueueModel(
            orca: orca,
            jumper: SessionAwareJumper(client: orca),
            defaults: defaults,
            now: { self.now.addingTimeInterval(30) }
        )
    }
}

private final class InteractionDefaults: AttentionQueueDefaultsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var doubles: [String: Double] = [:]
    private var data: [String: Data] = [:]

    func double(forKey key: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        return doubles[key] ?? 0
    }
    func set(_ value: Double, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        doubles[key] = value
    }
    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return data[key]
    }
    func set(_ value: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        data[key] = value
    }
}
