import Foundation

/// 固定 JSON 样例：从 `orca worktree ps` / `orca terminal list --include-visual-layouts`
/// / `orca terminal read` 的真实输出脱敏取样（research/02-data-acquisition-spike.md）。
enum Fixtures {
    static func data(_ s: String) -> Data { Data(s.utf8) }

    static let worktreePS = """
    {
      "id": "cmd-1",
      "ok": true,
      "result": {
        "worktrees": [
          {
            "workspaceKind": "git",
            "worktreeId": "111::/Users/dev/orca/repoA",
            "repoId": "111",
            "repo": "repoA",
            "path": "/Users/dev/orca/repoA",
            "branch": "refs/heads/main",
            "isMainWorktree": true,
            "isActive": true,
            "liveTerminalCount": 2,
            "status": "working",
            "lastOutputAt": 1786993627799,
            "preview": "Building…",
            "agents": [
              {
                "paneKey": "tab2:leaf2",
                "state": "working",
                "agentType": "grok",
                "prompt": "实现功能 X",
                "taskTitle": "实现功能 X",
                "displayName": "实现功能 X",
                "lastAssistantMessage": null,
                "toolName": "run_terminal_command",
                "toolInput": "swift test",
                "interrupted": false,
                "stateStartedAt": 1786993609488,
                "updatedAt": 1786993627219
              }
            ]
          },
          {
            "worktreeId": "222::/Users/dev/orca/repoB",
            "repo": "repoB",
            "path": "/Users/dev/orca/repoB",
            "branch": "refs/heads/feat-y",
            "isActive": false,
            "liveTerminalCount": 2,
            "status": "active",
            "lastOutputAt": 1786990000000,
            "preview": "Waiting…",
            "agents": [
              {
                "paneKey": "tab3:leaf3",
                "state": "done",
                "agentType": "claude",
                "prompt": "审查 PR",
                "lastAssistantMessage": "已找到三处风险，需要你确认选 A 还是 B？",
                "interrupted": false,
                "updatedAt": 1786990000000
              }
            ]
          }
        ]
      }
    }
    """

    static let terminalList = """
    {
      "id": "cmd-2",
      "ok": true,
      "result": {
        "terminals": [
          {
            "handle": "term_A1",
            "worktreeId": "111::/Users/dev/orca/repoA",
            "worktreePath": "/Users/dev/orca/repoA",
            "branch": "refs/heads/main",
            "tabId": "tab1",
            "leafId": "leaf1",
            "title": "repoA · build",
            "connected": true,
            "writable": true,
            "lastOutputAt": 1786993620000,
            "preview": "build ok"
          },
          {
            "handle": "term_A2",
            "worktreeId": "111::/Users/dev/orca/repoA",
            "worktreePath": "/Users/dev/orca/repoA",
            "branch": "refs/heads/main",
            "tabId": "tab2",
            "leafId": "leaf2",
            "title": "repoA · grok",
            "connected": true,
            "writable": true,
            "lastOutputAt": 1786993627799,
            "preview": "Working…"
          },
          {
            "handle": "term_A3",
            "worktreeId": "111::/Users/dev/orca/repoA",
            "worktreePath": "/Users/dev/orca/repoA",
            "branch": "refs/heads/main",
            "tabId": "tab2",
            "leafId": "leaf9",
            "title": "logs",
            "connected": true,
            "writable": true,
            "lastOutputAt": 1786993500000,
            "preview": "tail -f"
          },
          {
            "handle": "term_B1",
            "worktreeId": "222::/Users/dev/orca/repoB",
            "worktreePath": "/Users/dev/orca/repoB",
            "branch": "refs/heads/feat-y",
            "tabId": "tab3",
            "leafId": "leaf3",
            "title": "repoB · claude",
            "connected": true,
            "writable": true,
            "lastOutputAt": 1786993627798,
            "preview": "done"
          },
          {
            "handle": "term_B2",
            "worktreeId": "222::/Users/dev/orca/repoB",
            "worktreePath": "/Users/dev/orca/repoB",
            "branch": "refs/heads/feat-y",
            "tabId": "tab4",
            "leafId": "leaf4",
            "title": "repoB · shell",
            "connected": true,
            "writable": true,
            "lastOutputAt": 1786980000000,
            "preview": "$"
          }
        ],
        "visualLayouts": [
          {
            "worktreeId": "111::/Users/dev/orca/repoA",
            "worktreePath": "/Users/dev/orca/repoA",
            "root": {
              "type": "group",
              "groupId": "g1",
              "activeTabId": "tab2",
              "tabs": [
                {
                  "tabId": "tab1",
                  "title": "build",
                  "activeLeafId": "leaf1",
                  "panes": {
                    "type": "terminal",
                    "handle": "term_A1",
                    "tabId": "tab1",
                    "leafId": "leaf1",
                    "title": "build",
                    "connected": true,
                    "active": true
                  }
                },
                {
                  "tabId": "tab2",
                  "title": "grok",
                  "activeLeafId": "leaf2",
                  "panes": {
                    "type": "pane-split",
                    "direction": "horizontal",
                    "first": {
                      "type": "terminal",
                      "handle": "term_A2",
                      "tabId": "tab2",
                      "leafId": "leaf2",
                      "title": "grok",
                      "connected": true,
                      "active": true
                    },
                    "second": {
                      "type": "terminal",
                      "handle": "term_A3",
                      "tabId": "tab2",
                      "leafId": "leaf9",
                      "title": "logs",
                      "connected": true,
                      "active": false
                    }
                  }
                }
              ]
            }
          },
          {
            "worktreeId": "222::/Users/dev/orca/repoB",
            "worktreePath": "/Users/dev/orca/repoB",
            "root": {
              "type": "group",
              "groupId": "g2",
              "activeTabId": "tab3",
              "tabs": [
                {
                  "tabId": "tab3",
                  "title": "claude",
                  "activeLeafId": "leaf3",
                  "panes": {
                    "type": "terminal",
                    "handle": "term_B1",
                    "tabId": "tab3",
                    "leafId": "leaf3",
                    "title": "claude",
                    "connected": true,
                    "active": true
                  }
                },
                {
                  "tabId": "tab4",
                  "title": "shell",
                  "activeLeafId": "leaf4",
                  "panes": {
                    "type": "terminal",
                    "handle": "term_B2",
                    "tabId": "tab4",
                    "leafId": "leaf4",
                    "title": "shell",
                    "connected": true,
                    "active": true
                  }
                }
              ]
            }
          }
        ],
        "topologyRevisions": {},
        "totalCount": 5,
        "truncated": false
      }
    }
    """

    static let terminalRead = """
    {
      "id": "cmd-3",
      "ok": true,
      "result": {
        "terminal": {
          "handle": "term_B1",
          "status": "running",
          "tail": [
            "分析完成，共三处风险",
            "",
            "下一个问题：这个 skill 的核心输出，你希望定义成什么？",
            "A. 结构化风险报告对象（推荐）",
            "B. 只返回自然语言分析"
          ],
          "truncated": false,
          "limited": false,
          "oldestCursor": "0",
          "nextCursor": "5",
          "latestCursor": "5",
          "returnedLineCount": 5
        }
      }
    }
    """

    /// 无 active worktree、无 layout 的快照，用于焦点兜底测试。
    static let terminalListNoFocus = """
    {
      "id": "cmd-4",
      "ok": true,
      "result": {
        "terminals": [
          {
            "handle": "term_X1",
            "worktreeId": "333::/x",
            "branch": "refs/heads/main",
            "title": "x1",
            "connected": true,
            "lastOutputAt": 100
          },
          {
            "handle": "term_X2",
            "worktreeId": "333::/x",
            "branch": "refs/heads/main",
            "title": "x2",
            "connected": true,
            "lastOutputAt": 900
          },
          {
            "handle": "term_X3",
            "worktreeId": "333::/x",
            "branch": "refs/heads/main",
            "title": "x3",
            "connected": true,
            "lastOutputAt": 500
          }
        ],
        "visualLayouts": [],
        "totalCount": 3,
        "truncated": false
      }
    }
    """
}
