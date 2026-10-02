#!/bin/sh
set -eu

BUILTIN=/usr/local/bin/relay.sh
RELAY_SCRIPT="${RELAY_SCRIPT:-/config/relay.sh}"

entry_log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"
}

if [ -f "$RELAY_SCRIPT" ]; then
  entry_log "entrypoint: 使用外部脚本 ${RELAY_SCRIPT}"
  exec /bin/sh "$RELAY_SCRIPT"
fi

if [ "$RELAY_SCRIPT" != "$BUILTIN" ]; then
  entry_log "entrypoint: 未找到 ${RELAY_SCRIPT}，执行 ${BUILTIN}（若 Compose 挂载了该路径则为宿主机脚本，否则为镜像内 COPY 的版本）"
fi
exec /bin/sh "$BUILTIN"
