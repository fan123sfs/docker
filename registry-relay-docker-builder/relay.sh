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
# 上游包 -> 阿里云仓库 的映射，空格或换行分隔；留空则用 UPSTREAM_OWNERS × RELAY_PACKAGES 探测 GHCR 有 tag 的项
REPO_MAP="${REPO_MAP:-}"
UPSTREAM_OWNERS="${UPSTREAM_OWNERS:-}"
RELAY_PACKAGES="${RELAY_PACKAGES:-}"
ALIYUN_NAMESPACE="${ALIYUN_NAMESPACE:-syncimage}"
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

need_var ALIYUN_USERNAME
need_var ALIYUN_PASSWORD
if [ -z "${REPO_MAP:-}" ]; then
  need_var UPSTREAM_OWNERS
  need_var RELAY_PACKAGES
fi

WORK_DIR="${WORK_DIR:-/tmp/acr-relay}"
mkdir -p "$WORK_DIR"
FORWARD_STATE="${WORK_DIR}/forward_state.tsv"
# 列：dst_repo tag built_epoch forwarded_epoch digest src_repo（制表符分隔）

format_epoch_local() {
  epoch="$1"
  if [ -z "$epoch" ] || [ "$epoch" -le 0 ] 2>/dev/null; then
    printf '?'
    return 0
  fi
  date -r "$epoch" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
    || date -d "@$epoch" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null \
    || printf '@%s' "$epoch"
}

manifest_created_epoch() {
  ref="$1"
  created=""
  created=$(regctl image inspect "$ref" --format '{{.Created}}' 2>/dev/null || true)
  if [ -z "$created" ]; then
    created=$(regctl manifest get "$ref" --format '{{.Created}}' 2>/dev/null || true)
  fi
  if [ -z "$created" ]; then
    printf '0'
    return 0
  fi
  epoch=$(date -d "$created" +%s 2>/dev/null || true)
  if [ -z "$epoch" ]; then
    epoch=$(date -D '%Y-%m-%dT%H:%M:%SZ' -t "${created%%.*}Z" +%s 2>/dev/null || true)
  fi
  if [ -z "$epoch" ]; then
    printf '0'
  else
    printf '%s' "$epoch"
  fi
}

forward_state_read() {
  dst_repo="$1"
  tag="$2"
  if [ ! -f "$FORWARD_STATE" ]; then
    printf '0\n\n'
    return 0
  fi
  line=$(awk -F '	' -v d="$dst_repo" -v t="$tag" '$1 == d && $2 == t { last = $0 } END { print last }' "$FORWARD_STATE")
  if [ -z "$line" ]; then
    printf '0\n\n'
    return 0
  fi
  built=$(printf '%s' "$line" | awk -F '	' '{ print $3 }')
  digest=$(printf '%s' "$line" | awk -F '	' '{ print $5 }')
  printf '%s\n%s\n' "${built:-0}" "$digest"
}

forward_state_write() {
  dst_repo="$1"
  tag="$2"
  built_epoch="$3"
  digest="$4"
  src_repo="$5"
  forwarded_epoch=$(date +%s 2>/dev/null || printf '0')
  tmp="$WORK_DIR/forward_state.tmp"
  if [ -f "$FORWARD_STATE" ]; then
    awk -F '	' -v d="$dst_repo" -v t="$tag" '$1 != d || $2 != t { print }' "$FORWARD_STATE" >"$tmp" || : >"$tmp"
  else
    : >"$tmp"
  fi
  printf '%s	%s	%s	%s	%s	%s\n' "$dst_repo" "$tag" "$built_epoch" "$forwarded_epoch" "$digest" "$src_repo" >>"$tmp"
  mv "$tmp" "$FORWARD_STATE"
}

# 多 owner 同名包：选「任一 tag 编译时间最新」的那个 owner，只从该 owner 同步
pick_owner_for_pkg() {
  pkg="$1"
  best_owner=""
  best_epoch=0
  best_tag=""
  tag_file="$WORK_DIR/pick_tags"
  for owner in $UPSTREAM_OWNERS; do
    [ -n "$owner" ] || continue
    src="${owner}/${pkg}"
    : >"$tag_file"
    regctl tag ls "${UPSTREAM_REGISTRY}/${src}" >"$tag_file" 2>/dev/null || true
    if [ ! -s "$tag_file" ]; then
      continue
    fi
    owner_epoch=0
    owner_tag=""
    while IFS= read -r tag || [ -n "$tag" ]; do
      [ -n "$tag" ] || continue
      case "$tag" in latest|sha256-*) continue ;; esac
      ref="${UPSTREAM_REGISTRY}/${src}:${tag}"
      e=$(manifest_created_epoch "$ref")
      if [ "$e" -gt "$owner_epoch" ] 2>/dev/null; then
        owner_epoch=$e
        owner_tag=$tag
      fi
    done <"$tag_file"
    [ "$owner_epoch" -gt 0 ] 2>/dev/null || continue
    if [ "$owner_epoch" -gt "$best_epoch" ] 2>/dev/null; then
      best_owner=$owner
      best_epoch=$owner_epoch
      best_tag=$owner_tag
    fi
  done
  if [ -n "$best_owner" ]; then
    pick_cache="$WORK_DIR/pick_owner_${pkg}"
    prev=$(cat "$pick_cache" 2>/dev/null || true)
    cur="${best_owner}@${best_tag}@${best_epoch}"
    if [ "$prev" != "$cur" ]; then
      log "包 ${pkg} 选用上游 ${best_owner}/${pkg}（代表 tag ${best_tag} 编译 $(format_epoch_local "$best_epoch")）"
      printf '%s' "$cur" >"$pick_cache"
    fi
  fi
  printf '%s' "$best_owner"
}

# 返回当前轮询用的映射（写入 $WORK_DIR/repo_map 供 forgehub docker exec 探测待转发 tag）
resolve_repo_map() {
  if [ -n "${REPO_MAP:-}" ]; then
    printf '%s' "$REPO_MAP" >"$WORK_DIR/repo_map"
    printf '%s' "$REPO_MAP"
    return 0
  fi
  out=""
  for pkg in $RELAY_PACKAGES; do
    [ -n "$pkg" ] || continue
    owner=$(pick_owner_for_pkg "$pkg")
    [ -n "$owner" ] || continue
    out="${out}${owner}/${pkg}=${ALIYUN_NAMESPACE}/${pkg} "
  done
  out=$(printf '%s' "$out" | sed 's/ $//')
  printf '%s' "$out" >"$WORK_DIR/repo_map"
  printf '%s' "$out"
}

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

# 上游 tag 与阿里云 digest 一致就跳过；按编译时间拒绝旧构建；成功写入 forward_state
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
  src_epoch=$(manifest_created_epoch "$src")
  _st=$(forward_state_read "$dst_repo" "$tag")
  st_epoch=$(printf '%s' "$_st" | sed -n '1p')
  st_digest=$(printf '%s' "$_st" | sed -n '2p')
  if [ -n "$st_digest" ] && [ "$st_digest" = "$src_digest" ]; then
    log "已记录转发 $dst（编译 $(format_epoch_local "$st_epoch")），跳过"
    return 1
  fi
  if [ "$src_epoch" -gt 0 ] && [ "$st_epoch" -gt 0 ] && [ "$src_epoch" -lt "$st_epoch" ] 2>/dev/null; then
    log "上游较旧 $src（编译 $(format_epoch_local "$src_epoch") < 已转发 $(format_epoch_local "$st_epoch")），跳过"
    return 1
  fi
  if regctl manifest head "$dst" >/dev/null 2>&1; then
    dst_digest=$(regctl manifest digest "$dst" 2>/dev/null || true)
    dst_epoch=$(manifest_created_epoch "$dst")
    if [ -n "$dst_digest" ] && [ "$src_digest" = "$dst_digest" ]; then
      forward_state_write "$dst_repo" "$tag" "$src_epoch" "$src_digest" "$src_repo"
      log "阿里云已有 $dst（digest 一致，编译 $(format_epoch_local "$src_epoch")），跳过 copy"
      return 1
    fi
    if [ "$src_epoch" -gt 0 ] && [ "$dst_epoch" -gt 0 ] && [ "$src_epoch" -lt "$dst_epoch" ] 2>/dev/null; then
      log "上游较旧 $src（编译 $(format_epoch_local "$src_epoch") < 阿里云 $(format_epoch_local "$dst_epoch")），跳过"
      return 1
    fi
    log "阿里云 $dst 与上游 digest 不一致（远端 ${dst_digest:-未知}，上游 $src_digest），重新转发"
  fi
  log "转发 $src -> $dst（编译 $(format_epoch_local "$src_epoch")，超时 ${COPY_TIMEOUT_SECONDS}s）"
  if ! timeout -s KILL -k 10 "$COPY_TIMEOUT_SECONDS" regctl image copy --fast "$src" "$dst"; then
    log "转发失败，保留待下轮重试: $src"
    return 1
  fi
  if ! regctl manifest head "$dst" >/dev/null 2>&1; then
    log "阿里云未见 $dst，待下轮重试"
    return 1
  fi
  forward_state_write "$dst_repo" "$tag" "$src_epoch" "$src_digest" "$src_repo"
  log "转发成功 $dst（编译 $(format_epoch_local "$src_epoch")，记录于 ${FORWARD_STATE}）"
  return 0
}

scan_once() {
  job_file="$WORK_DIR/jobs"
  copied_file="$WORK_DIR/copied"
  tag_file="$WORK_DIR/tags"
  active_map=$(resolve_repo_map)
  : >"$job_file"
  : >"$copied_file"
  if [ -z "$active_map" ]; then
    return 1
  fi
  printf '%s\n' "$active_map" | tr ' ' '\n' | while IFS= read -r mapping || [ -n "$mapping" ]; do
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
      case "$tag" in latest|sha256-*) continue ;; esac
      ref="${UPSTREAM_REGISTRY}/${src_repo}:${tag}"
      tag_epoch=$(manifest_created_epoch "$ref")
      st_epoch=$(forward_state_read "$dst_repo" "$tag" | head -n 1)
      if [ "$tag_epoch" -gt 0 ] && [ "$st_epoch" -gt 0 ] && [ "$tag_epoch" -lt "$st_epoch" ] 2>/dev/null; then
        continue
      fi
      dst_ref="${ALIYUN_REGISTRY}/${dst_repo}:${tag}"
      if regctl manifest head "$dst_ref" >/dev/null 2>&1; then
        dst_epoch=$(manifest_created_epoch "$dst_ref")
        if [ "$tag_epoch" -gt 0 ] && [ "$dst_epoch" -gt 0 ] && [ "$tag_epoch" -lt "$dst_epoch" ] 2>/dev/null; then
          continue
        fi
      fi
      printf '%s %s %s\n' "$src_repo" "$tag" "$dst_repo" >>"$job_file"
    done <"$tag_file"
  done
  if [ ! -s "$job_file" ]; then
    return 1
  fi
  # 多个上游映射到同一 dst:tag 时只保留首个，避免并发 push 同一 tag 导致 ACR blob 404
  dedup_file="$WORK_DIR/jobs.dedup"
  seen_file="$WORK_DIR/seen"
  : >"$dedup_file"
  : >"$seen_file"
  while IFS=' ' read -r src_repo tag dst_repo || [ -n "$src_repo" ]; do
    [ -n "$src_repo" ] && [ -n "$tag" ] && [ -n "$dst_repo" ] || continue
    key="${dst_repo}:${tag}"
    if grep -qxF "$key" "$seen_file" 2>/dev/null; then
      continue
    fi
    printf '%s\n' "$key" >>"$seen_file"
    printf '%s %s %s\n' "$src_repo" "$tag" "$dst_repo" >>"$dedup_file"
  done <"$job_file"
  mv "$dedup_file" "$job_file"
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

if [ -z "${REPO_MAP:-}" ]; then
  log "映射模式：${UPSTREAM_OWNERS} 中每包选编译最新的 owner；按镜像编译时间转发，状态 ${FORWARD_STATE}"
else
  log "映射模式：固定 REPO_MAP"
fi
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
