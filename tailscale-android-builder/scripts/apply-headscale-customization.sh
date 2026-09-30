#!/usr/bin/env bash
# 将自研 Headscale 定制（开机自启、JSON 登录）合入上游 tailscale-android 树。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${1:-${UPSTREAM:-}}"

if [[ -z "$UPSTREAM" || ! -d "$UPSTREAM/android" ]]; then
  echo "::error::apply-headscale-customization: 需要有效的上游目录" >&2
  exit 1
fi

CUSTOM_SRC="${ROOT}/custom/android/src/main"
DEST="${UPSTREAM}/android/src/main"

if [[ ! -d "$CUSTOM_SRC" ]]; then
  echo "::error::缺少 custom 目录: ${CUSTOM_SRC}（常见原因: 未 git add custom，或 .gitignore 误忽略 **/src/**）" >&2
  exit 1
fi

log() {
  echo "[apply-headscale] $*"
}

log "复制 Kotlin 源文件到 ${DEST}"
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
  "${DEST}/java/com/tailscale/ipn/headscale/HeadscaleConfigDialog.kt"
  "${DEST}/java/com/tailscale/ipn/headscale/HeadscaleConfigStore.kt"
  "${DEST}/java/com/tailscale/ipn/headscale/HeadscaleLoginWorker.kt"
  "${DEST}/java/com/tailscale/ipn/headscale/BootCompletedReceiver.kt"
)
for f in "${required[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "::error::定制未就绪，缺少: $f" >&2
    exit 1
  fi
done
grep -q 'headscale.BootCompletedReceiver' "${UPSTREAM}/android/src/main/AndroidManifest.xml" \
  || { echo "::error::AndroidManifest 未合入 BootCompletedReceiver" >&2; exit 1; }
grep -q 'HeadscaleConfigDialog' "${UPSTREAM}/android/src/main/java/com/tailscale/ipn/ui/view/MainView.kt" \
  || { echo "::error::MainView 未合入 HeadscaleConfigDialog" >&2; exit 1; }

log "完成"
