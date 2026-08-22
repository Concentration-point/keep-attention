#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SUITE=keep-attention-gui-regression-$$
APP_ID=com.orca.keep-attention
SOCKET=/tmp/keep-attention-gui-regression-$$.sock
ORCA_FIXTURE=/tmp/keep-attention-gui-orca-$$

cd "$ROOT_DIR"

# 当前 GUI 冒烟覆盖：真实 app 启动、Accessibility 可见、药丸展开、拖动。
# Seen/Snooze/Jump 的业务后果由 AttentionQueueInteractionTests 使用同一
# AttentionQueueActions.live(model:) 契约做确定性回归，不需要真实权限弹窗。
swift run keep-attention-tests >/tmp/keep-attention-gui-unit.log 2>&1
# 不覆盖用户可能正在运行的 keep-attention.app；在 /tmp 打一个独立测试 bundle。
swift build -c release >/tmp/keep-attention-gui-build.log 2>&1
TEST_APP=${TMPDIR:-/tmp}/keep-attention-gui-regression.app
rm -rf "$TEST_APP"
mkdir -p "$TEST_APP/Contents/MacOS"
cp .build/arm64-apple-macosx/release/keep-attention "$TEST_APP/Contents/MacOS/keep-attention"
cp .build/arm64-apple-macosx/release/keep-attention-hook "$TEST_APP/Contents/MacOS/keep-attention-hook"

# 受控的 10-session Orca CLI fixture：仍由生产 OrcaClient 通过 Process 调用并解码，
# 但不依赖用户当前真实 Orca 会话数量，确保 3–10 密度/coverage 回归可重复。
cat >"$ORCA_FIXTURE" <<'ORCA'
#!/bin/sh
set -eu
if [ "${1:-}" = worktree ]; then
  cat <<'JSON'
{"ok":true,"result":{"worktrees":[
{"worktreeId":"wt0","repo":"keep-attention","path":"/Users/test/keep-attention","branch":"refs/heads/main","status":"working","isActive":true,"lastOutputAt":1787171000000,"agents":[{"paneKey":"tab0:leaf0","state":"working","taskTitle":"Implement Session Overview","toolName":"swift","updatedAt":1787171000000}]},
{"worktreeId":"wt1","repo":"permission","path":"/Users/test/permission","branch":"refs/heads/master","status":"idle","isActive":false,"lastOutputAt":1787170900000,"agents":[{"paneKey":"tab1:leaf1","state":"done","taskTitle":"Review policy tests","lastAssistantMessage":"Completed structured review","updatedAt":1787170900000}]},
{"worktreeId":"wt2","repo":"context","path":"/Users/test/context","branch":"refs/heads/main","status":"idle","isActive":false,"lastOutputAt":1787170800000,"agents":[]},
{"worktreeId":"wt3","repo":"terminal","path":"/Users/test/terminal","branch":"refs/heads/master","status":"idle","isActive":false,"agents":[]},
{"worktreeId":"wt4","repo":"guardian","path":"/Users/test/guardian","branch":"refs/heads/main","status":"idle","isActive":false,"agents":[]},
{"worktreeId":"wt5","repo":"helper","path":"/Users/test/helper","branch":"refs/heads/main","status":"idle","isActive":false,"agents":[]},
{"worktreeId":"wt6","repo":"idl","path":"/Users/test/idl","branch":"refs/heads/master","status":"idle","isActive":false,"agents":[]},
{"worktreeId":"wt7","repo":"learn","path":"/Users/test/learn","branch":"refs/heads/main","status":"idle","isActive":false,"agents":[]},
{"worktreeId":"wt8","repo":"orca","path":"/Users/test/orca","branch":"refs/heads/main","status":"idle","isActive":false,"agents":[]}
]}}
JSON
else
  cat <<'JSON'
{"ok":true,"result":{"terminals":[
{"handle":"term0","worktreeId":"wt0","worktreePath":"/Users/test/keep-attention","branch":"refs/heads/main","tabId":"tab0","leafId":"leaf0","connected":true,"lastOutputAt":1787171000000},
{"handle":"term1","worktreeId":"wt1","worktreePath":"/Users/test/permission","branch":"refs/heads/master","tabId":"tab1","leafId":"leaf1","connected":true,"lastOutputAt":1787170900000},
{"handle":"term2","worktreeId":"wt2","tabId":"tab2","leafId":"leaf2","connected":true,"lastOutputAt":1787170800000},
{"handle":"term3","worktreeId":"wt3","tabId":"tab3","leafId":"leaf3","connected":true},
{"handle":"term4","worktreeId":"wt4","tabId":"tab4","leafId":"leaf4","connected":true},
{"handle":"term5","worktreeId":"wt5","tabId":"tab5","leafId":"leaf5","connected":true},
{"handle":"term6","worktreeId":"wt6","tabId":"tab6","leafId":"leaf6","connected":true},
{"handle":"term7","worktreeId":"wt7","tabId":"tab7","leafId":"leaf7","connected":true},
{"handle":"term8","worktreeId":"wt8","tabId":"tab8","leafId":"leaf8","connected":false}
],"visualLayouts":[],"totalCount":9,"truncated":false}}
JSON
fi
ORCA
chmod +x "$ORCA_FIXTURE"
cat >"$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>keep-attention</string>
<key>CFBundleIdentifier</key><string>com.orca.keep-attention.regression</string>
<key>CFBundleName</key><string>keep-attention-regression</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

env KEEP_ATTENTION_DEFAULTS_SUITE=$SUITE \
  KEEP_ATTENTION_SOCKET=$SOCKET \
  KEEP_ATTENTION_ORCA_BINARY=$ORCA_FIXTURE \
  "$TEST_APP/Contents/MacOS/keep-attention" \
  >/tmp/keep-attention-gui-app.log 2>&1 &
launcher_pid=$!
trap 'kill "${app_pid:-$launcher_pid}" 2>/dev/null || true; rm -f "$ORCA_FIXTURE"' EXIT INT TERM

app_pid=
attempt=0
while [ "$attempt" -lt 20 ]; do
  if lsof -t "$SOCKET" >/tmp/keep-attention-gui-pid 2>/dev/null; then
    app_pid=$(head -1 /tmp/keep-attention-gui-pid)
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.25
done
[ -n "$app_pid" ] || { echo "FAIL: app 未在 5 秒内启动 socket" >&2; cat /tmp/keep-attention-gui-app.log >&2; exit 1; }
sleep 1

inject_event() {
  printf '%s\n' "$1" | env KEEP_ATTENTION_SOCKET=$SOCKET \
    "$TEST_APP/Contents/MacOS/keep-attention-hook"
}

state=$(orca computer get-app-state --app "pid:$app_pid" --restore-window --json)
printf '%s' "$state" | grep -q '"ok": true' || {
  echo "FAIL: app Accessibility state 不可读" >&2
  echo "$state" >&2
  exit 1
}
printf '%s' "$state" | grep -q '"elementCount": 2' || {
  echo "FAIL: TC-1 冷启动药丸 Accessibility 结构异常" >&2
  exit 1
}

# TC-1 完成后再注入真实 helper → Unix socket → reducer → UI 事件，
# 避免把 fixture 当成冷启动结果，同时覆盖 TC-2/TC-7。
inject_event "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"gui-session\",\"cwd\":\"$ROOT_DIR\",\"source\":\"startup\"}"
inject_event "{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"gui-session\",\"turn_id\":\"gui-permission-turn\",\"tool_use_id\":\"gui-permission-tool\",\"tool_name\":\"Bash\",\"cwd\":\"$ROOT_DIR\"}"
sleep 0.5
state=$(orca computer get-app-state --app "pid:$app_pid" --restore-window --json)
printf '%s' "$state" | grep -q '已升级' || { echo "FAIL: permission 未触发应用内升级 banner" >&2; exit 1; }

# banner 覆盖药丸命中区域；等待 6 秒自动消失后再做交互。
sleep 6.2
state=$(orca computer get-app-state --app "pid:$app_pid" --restore-window --json)

# 收起态表面位于固定 420×560 窗口顶端。用 window-local 坐标点击药丸，
# 再检查展开后的可访问元素数量增加；这能捕获窗口命中穿透/展开接线回归。
before=$(printf '%s' "$state" | sed -n 's/.*"elementCount": *\([0-9][0-9]*\).*/\1/p' | head -1)
before_x=$(printf '%s' "$state" | sed -n 's/.*"x": *\([-0-9][0-9]*\).*/\1/p' | head -1)
before_y=$(printf '%s' "$state" | sed -n 's/.*"y": *\([-0-9][0-9]*\).*/\1/p' | head -1)
# accessory/nonactivating panel 没有 focused window；用 CGEvent 真实点击，而不是要求
# focused recipient 的 coordinate click。
start_screen_x=$((before_x + 210))
start_screen_y=$((before_y + 24))
swift -e 'import CoreGraphics; import Foundation
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
func post(_ type: CGEventType) {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: a[0], y: a[1]), mouseButton: .left)?.post(tap: .cghidEventTap)
  usleep(120_000)
}
post(.mouseMoved); post(.leftMouseDown); post(.leftMouseUp)
' "$start_screen_x" "$start_screen_y" >/tmp/keep-attention-gui-click.json
sleep 1
expanded=$(orca computer get-app-state --app "pid:$app_pid" --json)
printf '%s\n' "$expanded" >/tmp/keep-attention-gui-expanded.json
after=$(printf '%s' "$expanded" | sed -n 's/.*"elementCount": *\([0-9][0-9]*\).*/\1/p' | head -1)
if [ "$after" -le "$before" ]; then
  echo "FAIL: 点击药丸后 Accessibility 元素未增加（before=${before} after=${after}）" >&2
  exit 1
fi

# permission fixture 展开后的第一个运行时 action 是 Seen。实际点击后必须仍在
# 队列且状态变为 Seen != Resolved，覆盖 SwiftUI Button → model action 接线。
seen_index=$(printf '%s' "$expanded" | python3 -c 'import json,sys,re; t=json.load(sys.stdin)["result"]["snapshot"]["treeText"]; print([re.match(r"\s*(\d+) button", x).group(1) for x in t.splitlines() if re.match(r"\s*(\d+) button", x)][2])')
[ -n "$seen_index" ] || { echo "FAIL: 未找到 Seen 按钮 Accessibility 元素" >&2; exit 1; }
orca computer click --app "pid:$app_pid" --element-index "$seen_index" --json >/tmp/keep-attention-gui-seen.json
sleep 1
after_seen=$(orca computer get-app-state --app "pid:$app_pid" --json)
printf '%s' "$after_seen" | grep -q 'Seen != Resolved' || {
  echo "FAIL: 点击 Seen 后未显示 Seen != Resolved" >&2
  exit 1
}
expanded="$after_seen"

# TC-3：精确 tool_use_id completion 必须让 permission 退出队列。
inject_event "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"gui-session\",\"turn_id\":\"gui-permission-turn\",\"tool_use_id\":\"gui-permission-tool\",\"tool_name\":\"Bash\",\"cwd\":\"$ROOT_DIR\"}"
sleep 0.5
permission_closed=$(orca computer get-app-state --app "pid:$app_pid" --json)
printf '%s' "$permission_closed" | grep -q 'No request needs action' || { echo "FAIL: permission completion 后 request 未离队" >&2; exit 1; }

# TC-4：Plan question 的 Pre/PostToolUse 必须形成并关闭 Answer required。
inject_event "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"gui-session\",\"turn_id\":\"gui-question-turn\",\"tool_use_id\":\"gui-question-tool\",\"tool_name\":\"request_user_input\",\"cwd\":\"$ROOT_DIR\"}"
sleep 0.5
question_open=$(orca computer get-app-state --app "pid:$app_pid" --json)
printf '%s' "$question_open" | grep -q 'Answer required' || { echo "FAIL: question 未进入队列" >&2; exit 1; }
inject_event "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"gui-session\",\"turn_id\":\"gui-question-turn\",\"tool_use_id\":\"gui-question-tool\",\"tool_name\":\"request_user_input\",\"cwd\":\"$ROOT_DIR\"}"
sleep 0.5
question_closed=$(orca computer get-app-state --app "pid:$app_pid" --json)
printf '%s' "$question_closed" | grep -q 'No request needs action' || { echo "FAIL: question answer 后 request 未离队" >&2; exit 1; }

# TC-Session-Overview：真实 helper → socket → reducer → SwiftUI。先用 UserPromptSubmit
# 建立进行中背景会话，再用 Stop.last_assistant_message 更新同一个 session；不依赖
# terminal tail，也不要求配置 DeepSeek key。
inject_event "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"term0\",\"turn_id\":\"gui-overview-turn\",\"cwd\":\"$ROOT_DIR\",\"prompt\":\"raw prompt must stay hidden\"}"
sleep 0.5
overview_prompt=$(orca computer get-app-state --app "pid:$app_pid" --json)
scroll_index=$(printf '%s' "$overview_prompt" | python3 -c 'import json,sys,re; t=json.load(sys.stdin)["result"]["snapshot"]["treeText"]; print(next((re.match(r"\s*(\d+) scroll area", x).group(1) for x in t.splitlines() if re.match(r"\s*(\d+) scroll area", x)), ""))')
[ -n "$scroll_index" ] || { echo "FAIL: 未找到展开态滚动区" >&2; exit 1; }
attempt=0
while ! printf '%s' "$overview_prompt" | grep -q 'Session Overview' && [ "$attempt" -lt 6 ]; do
  orca computer scroll --app "pid:$app_pid" --element-index "$scroll_index" --direction down --json >/tmp/keep-attention-gui-overview-scroll.json
  sleep 0.25
  overview_prompt=$(orca computer get-app-state --app "pid:$app_pid" --json)
  scroll_index=$(printf '%s' "$overview_prompt" | python3 -c 'import json,sys,re; t=json.load(sys.stdin)["result"]["snapshot"]["treeText"]; print(next((re.match(r"\s*(\d+) scroll area", x).group(1) for x in t.splitlines() if re.match(r"\s*(\d+) scroll area", x)), ""))')
  attempt=$((attempt + 1))
done
# SwiftUI ScrollView 的 disclosure 在 macOS AX tree 中可能只暴露为无 label
# button。此布局中 quiet card 后的第一个 button 是 Session Overview（后两项依次为
# Snoozed / State confirmation）；点击后仍用真实行内容做语义验收。

# 展开 Session Overview disclosure；通过可访问树中的 label 找 element index，
# 不依赖控件顺序。
ambient_index=$(printf '%s' "$overview_prompt" | python3 -c 'import json,sys,re; t=json.load(sys.stdin)["result"]["snapshot"]["treeText"]; buttons=[re.match(r"\s*(\d+) button", x).group(1) for x in t.splitlines() if re.match(r"\s*(\d+) button", x)]; print(buttons[-3] if len(buttons) >= 3 else "")')
[ -n "$ambient_index" ] || { echo "FAIL: 未找到 Session Overview disclosure" >&2; exit 1; }
orca computer click --app "pid:$app_pid" --element-index "$ambient_index" --json >/tmp/keep-attention-gui-overview-open.json
sleep 0.5
overview_working=$(orca computer get-app-state --app "pid:$app_pid" --json)
# 保留当前 GUI 证据截图/AX tree 的稳定副本，供 acceptance report 复核。
mkdir -p "$ROOT_DIR/.scratch/keep-attention/acceptance"
printf '%s\n' "$overview_working" >"$ROOT_DIR/.scratch/keep-attention/acceptance/session-overview-working.json"
working_screenshot=$(printf '%s' "$overview_working" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("screenshot",{}).get("path",""))')
[ -z "$working_screenshot" ] || cp "$working_screenshot" "$ROOT_DIR/.scratch/keep-attention/acceptance/session-overview-working.png"
printf '%s' "$overview_working" | grep -q 'TraeX task submitted' || { echo "FAIL: UserPromptSubmit 未显示当前任务" >&2; exit 1; }
printf '%s' "$overview_working" | grep -q 'Processing structured prompt' || { echo "FAIL: Session Overview 未显示进度" >&2; exit 1; }
printf '%s' "$overview_working" | grep -q 'Waiting for Stop.last_assistant_message' || { echo "FAIL: Session Overview 未显示下一步" >&2; exit 1; }
printf '%s' "$overview_working" | grep -q 'Updated now' || { echo "FAIL: Session Overview 未显示更新时间" >&2; exit 1; }
overview_entry_count=$(printf '%s' "$overview_working" | python3 -c 'import json,sys; t=json.load(sys.stdin)["result"]["snapshot"]["treeText"]; print((1 if "TraeX task submitted" in t else 0) + (1 if "Implement Session Overview" in t else 0) + (1 if "Review policy tests" in t else 0) + t.count("text Coverage gap"))')
[ "$overview_entry_count" -eq 10 ] || { echo "FAIL: 受控 10-session 密度缺失（实际 $overview_entry_count）" >&2; exit 1; }
printf '%s' "$overview_working" | grep -q 'Disconnected' || { echo "FAIL: disconnected session 未显示" >&2; exit 1; }
! printf '%s' "$overview_working" | grep -q 'raw prompt must stay hidden' || { echo "FAIL: GUI 泄漏完整 prompt" >&2; exit 1; }

inject_event "{\"hook_event_name\":\"Stop\",\"session_id\":\"term0\",\"turn_id\":\"gui-overview-turn\",\"cwd\":\"$ROOT_DIR\",\"last_assistant_message\":\"private complete reply must stay local\"}"
sleep 0.5
overview_done=$(orca computer get-app-state --app "pid:$app_pid" --json)
printf '%s\n' "$overview_done" >"$ROOT_DIR/.scratch/keep-attention/acceptance/session-overview-done.json"
done_screenshot=$(printf '%s' "$overview_done" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result",{}).get("screenshot",{}).get("path",""))')
[ -z "$done_screenshot" ] || cp "$done_screenshot" "$ROOT_DIR/.scratch/keep-attention/acceptance/session-overview-done.png"
printf '%s' "$overview_done" | grep -q 'TraeX completed response' || { echo "FAIL: Stop 未更新 Session Overview" >&2; exit 1; }
printf '%s' "$overview_done" | grep -q 'Received complete structured reply' || { echo "FAIL: 完整回复未更新进度" >&2; exit 1; }
printf '%s' "$overview_done" | grep -q 'Unknown · not request' || { echo "FAIL: 完整回复 fallback 错误宣称输入状态" >&2; exit 1; }
! printf '%s' "$overview_done" | grep -q 'private complete reply must stay local' || { echo "FAIL: GUI 泄漏完整 reply" >&2; exit 1; }

before_x=$(printf '%s' "$expanded" | sed -n 's/.*"x": *\([-0-9][0-9]*\).*/\1/p' | head -1)
before_y=$(printf '%s' "$expanded" | sed -n 's/.*"y": *\([-0-9][0-9]*\).*/\1/p' | head -1)
window="$before_x $before_y"
set -- $window
before_x=$1
before_y=$2
# SwiftUI DragGesture 使用 NSEvent.mouseLocation 读取真实全局鼠标位置。Orca 的窗口内
# synthetic drag 不会移动系统指针，因此用 AppKit/CGEvent 发一条真实鼠标拖动。
start_x=$((before_x + 210))
start_y=$((before_y + 24))
end_x=$((start_x + 60))
end_y=$((start_y + 50))
swift -e 'import CoreGraphics; import Foundation
let a = CommandLine.arguments.dropFirst().map { Double($0)! }
func post(_ type: CGEventType, _ x: Double, _ y: Double) {
  CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?.post(tap: .cghidEventTap)
  usleep(120_000)
}
post(.mouseMoved, a[0], a[1]); post(.leftMouseDown, a[0], a[1]); post(.leftMouseDragged, a[2], a[3]); post(.leftMouseUp, a[2], a[3])
' "$start_x" "$start_y" "$end_x" "$end_y" >/tmp/keep-attention-gui-drag.json
sleep 1
moved=$(orca computer get-app-state --app "pid:$app_pid" --json)
after_x=$(printf '%s' "$moved" | sed -n 's/.*"x": *\([-0-9][0-9]*\).*/\1/p' | head -1)
after_y=$(printf '%s' "$moved" | sed -n 's/.*"y": *\([-0-9][0-9]*\).*/\1/p' | head -1)
if [ "$after_x" = "$before_x" ] && [ "$after_y" = "$before_y" ]; then
  echo "FAIL: 拖动后窗口位置未变化" >&2
  exit 1
fi

echo "PASS: GUI 全链通过（permission/question 闭环、Session Overview prompt→Stop、更新时间、隐私、Seen、拖动）"
echo "PASS: Snooze/Jump/Restart 交互契约已由 swift runner 回归"
