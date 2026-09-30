#!/usr/bin/env bash
# 本地与 CI 共用：编译 tailscale-android 并输出单份 APK 到 out/。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${ROOT}/upstream/tailscale-android"
OUT="${ROOT}/out"
SDK="${ROOT}/android-sdk"

BUILD_TYPE="${BUILD_TYPE:-release}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
SKIP_UPSTREAM_CHECKOUT="${SKIP_UPSTREAM_CHECKOUT:-0}"

KEYSTORE_FILE="${KEYSTORE_FILE:-${JKS_PATH:-}}"
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-${JKS_PASSWORD:-}}"
KEY_PASSWORD="${KEY_PASSWORD:-$KEYSTORE_PASSWORD}"
KEY_ALIAS="${KEY_ALIAS:-tailscale}"

export JKS_PATH="${KEYSTORE_FILE}"
export JKS_PASSWORD="${KEYSTORE_PASSWORD}"
export TS_USE_TOOLCHAIN=1
export GOTOOLCHAIN=local
export ANDROID_SDK_ROOT="$SDK"
export ANDROID_HOME="$SDK"

log() {
  echo "[build-android] $*"
}

# 上游 Makefile 用环境变量 PWD 拼 $(PWD)/tool 和 GOBIN，不是 make 的 CURDIR。
# make -C 只改工作目录，PWD 仍是仓库根，gomobile 会装到错误路径，
# 再调用 Actions 预装的旧 Go（GOTOOLCHAIN=local 时不会升级）。
run_make() {
  (
    cd "$UPSTREAM"
    export PWD="$UPSTREAM"
    make "$@"
  )
}

ensure_upstream() {
  if [[ "$SKIP_UPSTREAM_CHECKOUT" == "1" ]]; then
    if [[ ! -d "$UPSTREAM" ]]; then
      echo "::error::SKIP_UPSTREAM_CHECKOUT=1 但上游目录不存在: $UPSTREAM" >&2
      exit 1
    fi
    return
  fi

  mkdir -p "$(dirname "$UPSTREAM")"
  if [[ ! -d "$UPSTREAM/.git" ]]; then
    log "克隆 tailscale-android @ ${UPSTREAM_REF}"
    git clone --depth 1 --branch "$UPSTREAM_REF" \
      https://github.com/tailscale/tailscale-android.git "$UPSTREAM"
  else
    log "更新 tailscale-android @ ${UPSTREAM_REF}"
    git -C "$UPSTREAM" fetch --depth 1 origin "$UPSTREAM_REF"
    git -C "$UPSTREAM" checkout -f FETCH_HEAD
  fi
}

ensure_android_sdk() {
  local sdkmanager="$SDK/cmdline-tools/latest/bin/sdkmanager"
  if [[ -x "$sdkmanager" ]] && "$sdkmanager" --list_installed 2>/dev/null | grep -q 'ndk'; then
    log "Android SDK 已就绪: $SDK"
    return
  fi

  log "安装 Android SDK 组件到 $SDK"
  run_make androidsdk ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
}

read_gradle_prop() {
  local key="$1"
  grep -E "^${key}=" "$UPSTREAM/android/gradle.properties" | cut -d= -f2-
}

write_build_info() {
  # shellcheck disable=SC1091
  source "$UPSTREAM/tailscale.version"
  mkdir -p "$OUT"
  cat >"$OUT/build-info.txt" <<EOF
tailscale_version_short=${VERSION_SHORT}
tailscale_version=${VERSION_LONG}
upstream_ref=${UPSTREAM_REF}
build_type=${BUILD_TYPE}
EOF
}

sign_release_apk() {
  local unsigned="$1"
  local signed="$OUT/tailscale-release.apk"
  local tools ver zipalign apksigner aligned

  ver="$(read_gradle_prop androidBuildToolsVersion)"
  tools="$SDK/build-tools/$ver"
  zipalign="$tools/zipalign"
  apksigner="$tools/apksigner"

  for bin in "$zipalign" "$apksigner"; do
    if [[ ! -x "$bin" ]]; then
      echo "::error::缺少签名工具: $bin" >&2
      exit 1
    fi
  done
  if [[ -z "$JKS_PATH" || ! -f "$JKS_PATH" ]]; then
    echo "::error::release 构建需要 KEYSTORE_FILE/JKS_PATH" >&2
    exit 1
  fi
  if [[ -z "$JKS_PASSWORD" ]]; then
    echo "::error::release 构建需要 KEYSTORE_PASSWORD/JKS_PASSWORD" >&2
    exit 1
  fi

  aligned="$OUT/aligned-unsigned.apk"
  rm -f "$aligned" "$signed"
  # build-tools 35+ 用 -P 16 对齐 16KB 页的 .so；更早的 zipalign 没有该参数。
  if "$zipalign" -h 2>&1 | grep -q -- '-P '; then
    "$zipalign" -f -P 16 4 "$unsigned" "$aligned"
  else
    "$zipalign" -f -p 4 "$unsigned" "$aligned"
  fi
  "$apksigner" sign \
    --ks "$JKS_PATH" \
    --ks-pass "pass:${JKS_PASSWORD}" \
    --key-pass "pass:${KEY_PASSWORD}" \
    --ks-key-alias "$KEY_ALIAS" \
    --out "$signed" \
    "$aligned"
  "$apksigner" verify --verbose "$signed"
  rm -f "$aligned"
  log "已签名: $signed"
}

build_debug_apk() {
  run_make tailscale-debug ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
  mkdir -p "$OUT"
  rm -f "$OUT"/*.apk
  install -C "$UPSTREAM/tailscale-debug.apk" "$OUT/tailscale-debug.apk"
}

build_release_apk() {
  run_make gradle-dependencies ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
  (
    cd "$UPSTREAM/android"
    ./gradlew --no-daemon test assembleRelease
  )

  mapfile -t candidates < <(find "$UPSTREAM/android/build/outputs/apk" -name '*.apk' -type f | sort)
  if [ "${#candidates[@]}" -eq 0 ]; then
    echo "::error::assembleRelease 未产出 APK" >&2
    exit 1
  fi

  local unsigned=""
  local apk
  for apk in "${candidates[@]}"; do
    if [[ "$apk" == *-unsigned.apk ]] || [[ "$apk" == *unsigned*.apk ]]; then
      unsigned="$apk"
      break
    fi
  done
  if [ -z "$unsigned" ]; then
    if [ "${#candidates[@]}" -ne 1 ]; then
      printf '%s\n' "${candidates[@]}" >&2
      echo "::error::无法确定待签名的 release APK（找到 ${#candidates[@]} 个）" >&2
      exit 1
    fi
    unsigned="${candidates[0]}"
  fi

  rm -f "$OUT"/*.apk
  sign_release_apk "$unsigned"
}

main() {
  ensure_upstream
  git config --global --add safe.directory "$UPSTREAM" >/dev/null 2>&1 || true

  ensure_android_sdk
  if [[ "${SKIP_HEADSCALE_CUSTOMIZATION:-0}" == "1" ]]; then
    log "跳过 Headscale 定制（SKIP_HEADSCALE_CUSTOMIZATION=1，假定已由 workflow 合入）"
  elif [[ -f "${ROOT}/scripts/apply-headscale-customization.sh" ]]; then
    bash "${ROOT}/scripts/apply-headscale-customization.sh" "$UPSTREAM"
  fi
  run_make version ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
  write_build_info

  case "$BUILD_TYPE" in
    release)
      build_release_apk
      ;;
    debug)
      build_debug_apk
      ;;
    *)
      echo "::error::不支持的 BUILD_TYPE: $BUILD_TYPE（应为 release 或 debug）" >&2
      exit 1
      ;;
  esac

  mapfile -t out_apks < <(find "$OUT" -maxdepth 1 -name '*.apk' -type f | sort)
  if [ "${#out_apks[@]}" -ne 1 ]; then
    printf '%s\n' "${out_apks[@]:-}" >&2
    echo "::error::out/ 中应有且仅有 1 个 APK，实际 ${#out_apks[@]} 个" >&2
    exit 1
  fi
  log "完成: ${out_apks[0]}"
}

main "$@"
