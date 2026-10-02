#!/bin/bash
set -euo pipefail

EXTERNAL=/deepseek-harness-entrypoint.sh
BUILTIN=/usr/local/bin/deepseek-harness-entrypoint.sh

if [ -f "$EXTERNAL" ]; then
  echo "entrypoint: 使用外部脚本 ${EXTERNAL}" >&2
  exec bash "$EXTERNAL" "$@"
fi

if [ ! -f "$BUILTIN" ]; then
  echo "entrypoint: 未找到 ${EXTERNAL}，也没有 ${BUILTIN}" >&2
  exit 1
fi
echo "entrypoint: 未找到 ${EXTERNAL}，执行 ${BUILTIN}" >&2
exec bash "$BUILTIN" "$@"
