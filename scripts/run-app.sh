#!/bin/sh
# 本地启动 keep-attention（request-centric Attention Queue 界面）。
# 从 .trae/keep-attention.env 读取 DEEPSEEK_API_KEY 等变量，免去每次手动 export。
# 注意：.trae/keep-attention.env 已被 .gitignore 忽略，key 不会进版本库。
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ENV_FILE="$ROOT_DIR/.trae/keep-attention.env"
APP_BIN="$ROOT_DIR/keep-attention.app/Contents/MacOS/keep-attention"

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

if [ ! -x "$APP_BIN" ]; then
  echo "未找到 app 产物，请先运行 scripts/make-app.sh" >&2
  exit 1
fi

exec "$APP_BIN"
