#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

echo "[1/3] Swift 行为与交互契约回归"
swift run keep-attention-tests

echo "[2/3] 真实 .app GUI 全链回归"
scripts/run-gui-regression.sh

echo "[3/3] 真实 traex hook 回归"
scripts/run-traex-hook-probe.sh

echo "PASS: keep-attention 全量回归通过"
