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
  entry_log "entrypoint: 未找到 ${RELAY_SCRIPT}，使用内置脚本"
fi
exec /bin/sh "$BUILTIN"
