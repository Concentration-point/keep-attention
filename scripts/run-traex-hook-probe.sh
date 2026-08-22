#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOG="$ROOT_DIR/.scratch/keep-attention/traex-hook-events.jsonl"
OUT=${TMPDIR:-/tmp}/keep-attention-traex-probe.jsonl
ERR=${TMPDIR:-/tmp}/keep-attention-traex-probe.err

before=0
if [ -f "$LOG" ]; then before=$(wc -l < "$LOG" | tr -d ' '); fi

# 命令名必须是 traex。exec 需要真实 app-server 权限；在受限 sandbox 内运行时会
# 明确报 Operation not permitted，不能据此判定产品 hook 失败。这里刻意不绕过
# hook trust，确保与用户平时直接启动 traex 的加载语义一致。
traex exec \
  -C "$ROOT_DIR" \
  --permission-mode bypass_permissions \
  --ephemeral \
  --json \
  'Do not use any tools. Reply with exactly: hook-probe-ok' >"$OUT" 2>"$ERR"

after=0
if [ -f "$LOG" ]; then after=$(wc -l < "$LOG" | tr -d ' '); fi
delta=$((after - before))

if [ "$delta" -lt 4 ]; then
  echo "FAIL: traex hook 仅新增 $delta 条事件，期望至少 SessionStart/UserPromptSubmit/Stop/SessionEnd" >&2
  cat "$ERR" >&2
  exit 1
fi

events=$(tail -n "$delta" "$LOG")
for expected in SessionStart UserPromptSubmit Stop SessionEnd; do
  echo "$events" | grep -q '"event_name":"'"$expected"'"' || {
    echo "FAIL: traex hook 缺少 $expected" >&2
    exit 1
  }
done

# Stop 必须携带完整结构化回复字段；只检查字段形状，绝不读取/打印正文。
stop_shape_ok=$(printf '%s
' "$events" | python3 -c 'import json,sys; print(any(d.get("event_name")=="Stop" and "last_assistant_message" in d.get("field_shape",[]) for d in map(json.loads, sys.stdin)))')
[ "$stop_shape_ok" = "True" ] || {
  echo "FAIL: 真实 Stop hook 未观测到 last_assistant_message 字段形状" >&2
  exit 1
}

echo "PASS: 真实 traex 产生 $delta 条安全 hook 事件（SessionStart/UserPromptSubmit/Stop/SessionEnd 已确认）"
