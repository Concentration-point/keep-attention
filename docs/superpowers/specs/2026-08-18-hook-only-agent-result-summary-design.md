# Hook-Only Agent Result Summary Design

## Goal

keep-attention should summarize only structured Orca agent results, not terminal screen output. The product should favor accuracy over coverage: if a terminal has no structured Orca agent hook data, the app should say so instead of inferring a summary from rendered terminal text.

## Product behavior

- The app still polls Orca lightly to discover worktrees, terminals, focus, and agent hook state.
- DeepSeek summarization is triggered only when `orca worktree ps --json` reports a non-empty `agents[].lastAssistantMessage` whose content fingerprint changed.
- A message is eligible for summarization only when the agent is not in a working/running state. While the agent is working, the UI should show execution state, not a spinner or fresh summary attempt.
- Terminals without matching `agents[]` data are displayed as unavailable for structured summary. They are not summarized from `terminal read` tail.
- Existing cached summaries are reused when the same structured agent result remains current.

## Data source

Primary and only summarization input:

```text
orca worktree ps --json -> worktrees[].agents[]
```

Relevant fields:

- `paneKey`: maps agent to terminal via `terminal.tabId + ":" + terminal.leafId`.
- `state`: controls whether a result is final enough to summarize.
- `agentType`: display metadata.
- `prompt` / `taskTitle`: user/request context.
- `lastAssistantMessage`: structured agent result to summarize.
- `updatedAt`: display metadata and stale-state comparison.
- `toolName` / `toolInput`: optional working-state display metadata.

`terminal read` is not part of the summary trigger or summary input for this design.

## State model

Each display keeps:

- terminal identity: handle, repo, branch, title;
- activity status: busy, waiting for input, idle;
- structured agent metadata if available;
- summary state.

Summary states:

- unavailable: no structured agent result is available or agent is still working;
- loading: a newly eligible structured result is being summarized;
- ready: a cached or newly generated summary is available;
- failed: a structured result existed but summarization failed.

## Trigger rules

A structured agent result is summarizable when all are true:

1. `lastAssistantMessage` is non-empty after trimming whitespace.
2. `state` is not a working state (`working`, `running`, `thinking`, `streaming`, `in_progress`, `in-progress`, `busy`).
3. The fingerprint of `worktreeId + paneKey + lastAssistantMessage` differs from the last summarized fingerprint.

When the fingerprint is unchanged, the cached summary is used and DeepSeek is not called.

## UI rules

- The panel should not show a spinner merely because a poll tick is running.
- For terminals without structured output, show a clear neutral message: `未检测到结构化 agent 输出`.
- For terminals whose agent is still working, show `Agent 正在执行，等待下一条完整回复`.
- For newly eligible results, show loading only for that terminal while DeepSeek is actually summarizing.
- For cached results, continue showing the previous summary.

## Verification

Use the existing Swift Testing command, not `swift test`:

```bash
swift run keep-attention-tests
```

Expected coverage:

- new `lastAssistantMessage` triggers one summary;
- identical `lastAssistantMessage` does not summarize again;
- `state=working` with a message does not summarize;
- `agents=[]` does not summarize and displays unavailable;
- agent `paneKey` maps to the matching terminal;
- existing tests remain green.
