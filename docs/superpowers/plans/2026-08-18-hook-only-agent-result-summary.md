# Hook-Only Agent Result Summary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Summarize only structured Orca agent results from `worktree ps.agents[].lastAssistantMessage`, never terminal tail output.

**Architecture:** Keep Orca polling for discovery, focus, and structured agent state. Replace tail-driven summary triggers with agent-result fingerprints keyed by `worktreeId + paneKey + lastAssistantMessage`; render unavailable/working states when no final structured result exists.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing executable runner `swift run keep-attention-tests`.

---

## Files

- Modify `Sources/KeepAttentionCore/OrcaClient.swift`: expose agent hook fields needed by app (`paneKey`, `updatedAt`, tool metadata if not already public internally).
- Modify `Sources/KeepAttentionCore/TerminalState.swift`: add summary unavailable state and agent display metadata.
- Modify `Sources/KeepAttentionCore/Poller.swift`: replace tail-driven summary trigger with hook-only agent-result trigger.
- Modify `Sources/keep-attention/Views/IslandPanel.swift`: render unavailable/working state.
- Modify `Tests/keep-attentionTestsRunner/PollerTests.swift`: add red/green tests for hook-only behavior.
- Modify `Tests/keep-attentionTestsRunner/Fixtures.swift`: ensure fixtures include paneKey mapping and state variants.

## Tasks

### Task 1: Add failing hook-only summary tests

- [ ] Add tests proving: final structured message summarizes, duplicate message dedupes, working agent does not summarize, no agents means unavailable.
- [ ] Run `swift run keep-attention-tests` and verify the new tests fail before production code changes.

### Task 2: Add minimal model support

- [ ] Add summary unavailable/agent metadata types.
- [ ] Add agent fields required for mapping and display.
- [ ] Run tests and keep expected failures scoped to hook-only behavior.

### Task 3: Implement hook-only trigger in Poller

- [ ] Map `agents[].paneKey` to terminals using `tabId:leafId`.
- [ ] Build summary contexts from `prompt/taskTitle/lastAssistantMessage` only.
- [ ] Skip summarization for working states and missing messages.
- [ ] Preserve cache when fingerprints are unchanged.
- [ ] Run `swift run keep-attention-tests` and verify all tests pass.

### Task 4: Update UI copy

- [ ] Render unavailable/working state in `IslandPanel`.
- [ ] Ensure no per-tick spinner appears unless a real summarization call is in flight.
- [ ] Run `swift run keep-attention-tests` again.

### Task 5: Final audit

- [ ] Inspect `git diff` for unrelated changes.
- [ ] Confirm `App.swift` pre-existing drag change is preserved, not reverted.
- [ ] Run final `swift run keep-attention-tests`.
