# 终端忙闲状态判定与灵动岛呈现规则

## 目标

把 Orca / TraeX terminal 映射成用户可快速理解的三类活动状态：

- `busy`：正在运行或近期仍有输出。
- `waitingForInput`：明确需要用户输入或确认。
- `idle`：没有新鲜运行信号，也没有等待输入提示。

## 判定输入

实现入口：`Sources/KeepAttentionCore/TerminalState.swift` 的 `StatusResolver.resolve(_:)`。

输入结构：`StatusInput`

- `agentStates`：来自 `worktree ps.agents[].state`，仅 hook-covered 会话可靠。
- `worktreeStatus`：来自 `worktree ps.worktrees[].status`。
- `lastOutputAt`：来自 terminal / worktree 的最后输出时间。
- `tail`：可选渲染文本尾部；当前 hook-only 总结路径不读取 tail，但状态判定 helper 保留该输入以支持未来 fallback。
- `now`：当前时间，测试可注入。

## 判定优先级

1. **agent 明确等待用户**
   - 若 `agentStates` 包含以下任一值（大小写不敏感），判定为 `waitingForInput`：
     - `waiting`
     - `waitingforinput`
     - `waiting-for-input`
     - `needsinput`
     - `needs-input`
     - `awaitinginput`
     - `awaiting-input`
     - `blocked`

2. **agent 明确工作中**
   - 若 `agentStates` 包含 `working`，判定为 `busy`。
   - 设计原则：有结构化 agent state 时优先相信 agent state，不从文本猜测。

3. **worktree working + 新鲜输出**
   - 若 `worktreeStatus == "working"` 且 `lastOutputAt` 距离 `now` 小于 `30s`，判定为 `busy`。
   - 即便 tail 里出现问号，仍保持 `busy`，避免把运行中的日志误判为等待输入。

4. **尾部文本启发式等待**
   - 若最近 `8` 行 tail 中任一行：
     - 以 `?` 或 `？` 结尾；
     - 或包含 `y/n`、`[y/N]`、`Y/n`；
   - 判定为 `waitingForInput`。
   - 仅用于无新鲜 working 信号或 agent 已非 working 的场景。

5. **默认空闲**
   - 不满足以上条件时，判定为 `idle`。

## 呈现规则

### 收起态 pill

实现位置：`Sources/keep-attention/Views/IslandPill.swift`。

- 状态圆点：
  - `busy`：绿色。
  - `waitingForInput`：橙色脉冲。
  - `idle`：灰色。
- waiting 抢显：
  - `AppModel.pillDisplay` 优先显示 `mostUrgentWaiting`。
  - 多个等待时，pill 徽标显示 `等待数/总终端数`。
  - 无等待时，pill 徽标显示总 terminal 数。

### 展开态详情

实现位置：`Sources/keep-attention/Views/IslandPanel.swift`。

- header 状态 badge：
  - `busy` → `忙碌`，绿色。
  - `waitingForInput` → `等待输入`，橙色。
  - `idle` → `空闲`，灰色。
- 四段式 summary：
  - `needsInput` 行高亮。
  - 信息不足显示 `未知`。
  - 无需输入显示 `无`。

### 展开态 terminal list

实现位置：`TerminalListRow` 和 `TerminalListVisualState`。

列表行使用更细的视觉 bucket：

- `waiting`：等待用户输入，橙色。
- `newResult`：有结构化结果 / loading / failed，蓝色。
- `running`：busy 但无结构化结果，绿色。
- `idle`：空闲，灰色。
- `unavailable`：无 hook / 无结构化输出，深灰。

列表按 attention 排序：

1. `waitingForInput`
2. 有结构化结果
3. `busy`
4. `idle` / `unavailable`

同 rank 内保持 Orca terminal list 原始顺序，避免 UI 抖动。

## 不采用主动 `terminal wait --for tui-idle`

当前版本不在常规 tick 中主动调用 `terminal wait --for tui-idle`：

- 它是主动探测命令，不适合作为所有 terminal 的高频轮询路径。
- 当前设计用 `worktree ps` + `terminal list --include-visual-layouts` 保持每 tick 低成本。
- 若未来需要更高准确率，可对用户选中 terminal 或可疑 stale terminal 做按需探测，而不是全量探测。

## 验证

覆盖测试：

- `StatusResolverTests.agentStateWorkingIsBusy`
- `StatusResolverTests.agentStateWaitingIsWaitingForInput`
- `StatusResolverTests.agentDoneWithQuestionTailIsWaitingForInput`
- `StatusResolverTests.agentDoneWithoutQuestionIsIdle`
- `StatusResolverTests.workingWorktreeWithFreshOutputIsBusyEvenWithQuestionTail`
- `StatusResolverTests.staleWorkingWorktreeWithPromptTailIsWaitingForInput`
- `StatusResolverTests.staleWithoutPromptIsIdle`
- `StatusResolverTests.chineseQuestionMarkCounts`
- `StatusResolverTests.questionTooFarFromTailIgnored`
- `PollerTests.attentionDisplaysSortWaitingFirstThenStructuredThenBusyStable`
- `PollerTests.attentionDisplaysSortBlockedAgentTerminalFirst`
- `PollerTests.terminalListVisualStateCoversStableRowBuckets`

验证命令：

```sh
swift run keep-attention-tests
swift build
scripts/make-app.sh
```
