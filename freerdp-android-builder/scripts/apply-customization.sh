#!/usr/bin/env bash
# 合入 aFreeRDP 定制：应用名 freerdp、自定义图标、JSON 批量导入书签。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${1:-${UPSTREAM:-}}"

if [[ -z "$UPSTREAM" || ! -d "$UPSTREAM/client/Android/Studio" ]]; then
  echo "::error::apply-customization: 需要有效的 FreeRDP 根目录" >&2
  exit 1
fi

CUSTOM_SRC="${ROOT}/custom/client/Android/Studio"
DEST="${UPSTREAM}/client/Android/Studio"

if [[ ! -d "$CUSTOM_SRC" ]]; then
  echo "::error::缺少 custom 目录: ${CUSTOM_SRC}（常见原因: .gitignore 的 src/ 误忽略 **/src/**，或未 git add custom）" >&2
  exit 1
fi

log() {
  echo "[apply-freerdp] $*"
}

log "复制定制资源到 ${DEST}"
mkdir -p "$DEST"
cp -a "$CUSTOM_SRC/." "$DEST/"

PATCH_DIR="${ROOT}/patches"
if [[ -d "$PATCH_DIR" ]]; then
  shopt -s nullglob
  patches=("$PATCH_DIR"/*.patch)
  shopt -u nullglob
  for p in "${patches[@]}"; do
    log "应用补丁 $(basename "$p")"
    if ! git -C "$UPSTREAM" apply --check "$p" 2>/dev/null; then
      echo "::error::补丁与上游不匹配: $p（请按 ref 更新补丁）" >&2
      exit 1
    fi
    git -C "$UPSTREAM" apply "$p"
  done
fi

required=(
  "${DEST}/freeRDPCore/src/main/java/com/freerdp/freerdpcore/custom/RemoteDesktopConfigDialog.java"
  "${DEST}/freeRDPCore/src/main/res/values/strings_custom.xml"
)
for f in "${required[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "::error::定制未就绪，缺少: $f" >&2
    exit 1
  fi
done

log "完成"
