#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"
}

UPSTREAM_REGISTRY="${UPSTREAM_REGISTRY:-ghcr.io}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
POLL_SECONDS="${POLL_SECONDS:-15}"
COPY_TIMEOUT_SECONDS="${COPY_TIMEOUT_SECONDS:-3600}"
COPY_JOBS="${COPY_JOBS:-3}"
# 上游包 -> 阿里云仓库 的映射，空格或换行分隔，例如：
#   REPO_MAP="owner/deepseek-harness=syncimage/deepseek-harness owner/deepseek-harness-desktop=syncimage/deepseek-harness-desktop"
REPO_MAP="${REPO_MAP:-}"
case "$COPY_JOBS" in
  ''|*[!0-9]*) COPY_JOBS=3 ;;
esac
if [ "$COPY_JOBS" -lt 1 ]; then
  COPY_JOBS=1
fi

need_var() {
  eval "val=\${$1-}"
  if [ -z "$val" ]; then
    log "缺少环境变量 $1"
    exit 1
  fi
}

need_var REPO_MAP
need_var ALIYUN_USERNAME
need_var ALIYUN_PASSWORD

WORK_DIR="${WORK_DIR:-/tmp/acr-relay}"
mkdir -p "$WORK_DIR"

# 上游私有包需要 UPSTREAM_TOKEN；公开包可留空匿名拉取
login_upstream() {
  if [ -z "${UPSTREAM_TOKEN:-}" ]; then
    return 0
  fi
  printf '%s' "$UPSTREAM_TOKEN" | regctl -v error registry login "$UPSTREAM_REGISTRY" \
    -u "${UPSTREAM_USER:-github}" --pass-stdin --skip-check
}

login_aliyun() {
  printf '%s' "$ALIYUN_PASSWORD" | regctl -v error registry login "$ALIYUN_REGISTRY" \
    -u "$ALIYUN_USERNAME" --pass-stdin --skip-check
}

verify_upstream() {
  if [ -z "${UPSTREAM_TOKEN:-}" ]; then
    return 0
  fi
  printf '%s' "$UPSTREAM_TOKEN" | regctl -v error registry login "$UPSTREAM_REGISTRY" \
    -u "${UPSTREAM_USER:-github}" --pass-stdin
}

verify_aliyun() {
  printf '%s' "$ALIYUN_PASSWORD" | regctl -v error registry login "$ALIYUN_REGISTRY" \
    -u "$ALIYUN_USERNAME" --pass-stdin
}

# 上游 tag 与阿里云 digest 一致就跳过；上游仓库是唯一事实来源，不做删除
forward_tag() {
  src_repo="$1"
  tag="$2"
  dst_repo="$3"
  src="${UPSTREAM_REGISTRY}/${src_repo}:${tag}"
  dst="${ALIYUN_REGISTRY}/${dst_repo}:${tag}"
  src_digest=$(regctl manifest digest "$src" 2>/dev/null || true)
  if [ -z "$src_digest" ]; then
    log "读不到上游 manifest，跳过: $src"
    return 1
  fi
  if regctl manifest head "$dst" >/dev/null 2>&1; then
    dst_digest=$(regctl manifest digest "$dst" 2>/dev/null || true)
    if [ -n "$dst_digest" ] && [ "$src_digest" = "$dst_digest" ]; then
      log "阿里云已有 $dst（digest 一致），跳过 copy"
      return 1
    fi
    log "阿里云 $dst 与上游 digest 不一致（远端 ${dst_digest:-未知}，上游 $src_digest），重新转发"
  fi
  log "转发 $src -> $dst（超时 ${COPY_TIMEOUT_SECONDS}s）"
  if ! timeout -s KILL -k 10 "$COPY_TIMEOUT_SECONDS" regctl image copy --fast "$src" "$dst"; then
    log "转发失败，保留待下轮重试: $src"
    return 1
  fi
  if ! regctl manifest head "$dst" >/dev/null 2>&1; then
    log "阿里云未见 $dst，待下轮重试"
    return 1
  fi
  log "转发成功 $dst"
  return 0
}

scan_once() {
  job_file="$WORK_DIR/jobs"
  copied_file="$WORK_DIR/copied"
  tag_file="$WORK_DIR/tags"
  : >"$job_file"
  : >"$copied_file"
  printf '%s\n' "$REPO_MAP" | tr ' ' '\n' | while IFS= read -r mapping || [ -n "$mapping" ]; do
    [ -n "$mapping" ] || continue
    src_repo="${mapping%%=*}"
    dst_repo="${mapping#*=}"
    if [ -z "$src_repo" ] || [ -z "$dst_repo" ] || [ "$src_repo" = "$dst_repo" ]; then
      log "跳过无效映射: $mapping"
      continue
    fi
    : >"$tag_file"
    regctl tag ls "${UPSTREAM_REGISTRY}/${src_repo}" >"$tag_file" 2>/dev/null || true
    if [ ! -s "$tag_file" ]; then
      continue
    fi
    while IFS= read -r tag || [ -n "$tag" ]; do
      [ -n "$tag" ] || continue
      printf '%s %s %s\n' "$src_repo" "$tag" "$dst_repo" >>"$job_file"
    done <"$tag_file"
  done
  if [ ! -s "$job_file" ]; then
    return 1
  fi
  n=0
  while IFS=' ' read -r src_repo tag dst_repo || [ -n "$src_repo" ]; do
    [ -n "$src_repo" ] && [ -n "$tag" ] && [ -n "$dst_repo" ] || continue
    (
      if forward_tag "$src_repo" "$tag" "$dst_repo"; then
        echo 1 >>"$copied_file"
      fi
    ) &
    n=$((n + 1))
    if [ "$n" -ge "$COPY_JOBS" ]; then
      wait
      n=0
    fi
  done <"$job_file"
  wait
  if [ -s "$copied_file" ]; then
    return 0
  fi
  return 1
}

log "中转启动，上游 ${UPSTREAM_REGISTRY} -> ${ALIYUN_REGISTRY}，超时 ${COPY_TIMEOUT_SECONDS}s，并发 ${COPY_JOBS}"
if ! verify_upstream >/dev/null 2>&1; then
  log "上游登录校验失败，请检查 UPSTREAM_USER / UPSTREAM_TOKEN"
  exit 1
fi
if ! verify_aliyun >/dev/null 2>&1; then
  log "阿里云登录校验失败，请检查 ALIYUN_USERNAME / ALIYUN_PASSWORD"
  exit 1
fi
log "已登录，开始轮询"

while true; do
  login_upstream >/dev/null
  login_aliyun >/dev/null
  if scan_once; then
    log "本轮有转发"
  fi
  sleep "$POLL_SECONDS"
done
