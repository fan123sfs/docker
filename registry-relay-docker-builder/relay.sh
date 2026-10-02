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
# copy 过程中每隔 N 秒打一条流量/均速心跳；0 关闭
COPY_PROGRESS_SECONDS="${COPY_PROGRESS_SECONDS:-30}"
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

# 代理 URL 脱敏（保留 scheme、用户、主机端口）
redact_proxy_url() {
  url="$1"
  case "$url" in
    *://*@*)
      scheme="${url%%://*}"
      rest="${url#*://}"
      hostport="${rest#*@}"
      user="${rest%%@*}"
      user="${user%%:*}"
      printf '%s://%s:***@%s' "$scheme" "$user" "$hostport"
      ;;
    *) printf '%s' "$url" ;;
  esac
}

proxy_env_summary() {
  parts=""
  for v in ALL_PROXY HTTPS_PROXY HTTP_PROXY; do
    eval "p=\${$v:-}"
    if [ -n "$p" ]; then
      parts="${parts}${v}=$(redact_proxy_url "$p") "
    fi
  done
  if [ -z "$parts" ]; then
    printf '下载代理：未设置（直连上游）'
    return 0
  fi
  printf '下载代理：%s' "$(printf '%s' "$parts" | sed 's/ $//')"
}

format_bytes_human() {
  bytes="${1:-0}"
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  awk -v b="$bytes" 'BEGIN {
    if (b >= 1073741824) printf "%.2f GiB", b/1073741824
    else if (b >= 1048576) printf "%.1f MiB", b/1048576
    else if (b >= 1024) printf "%.1f KiB", b/1024
    else printf "%d B", b
  }'
}

format_rate_human() {
  bytes="${1:-0}"
  sec="${2:-1}"
  case "$bytes" in
    ''|*[!0-9]*) bytes=0 ;;
  esac
  case "$sec" in
    ''|*[!0-9]*) sec=1 ;;
  esac
  if [ "$sec" -lt 1 ]; then
    sec=1
  fi
  awk -v b="$bytes" -v s="$sec" 'BEGIN { printf "%.2f MiB/s", b/s/1048576 }'
}

netdev_total_bytes() {
  if [ ! -r /proc/net/dev ]; then
    printf '0'
    return 0
  fi
  awk 'NR>2 {
    gsub(":", "", $1)
    if ($1 != "lo") { r += $2; t += $10 }
  } END { print r+t }' /proc/net/dev
}

# manifest 各层 Size 之和（linux/amd64），用于估算 copy 体量
image_transfer_bytes() {
  ref="$1"
  sum=0
  sizes=""
  sizes=$(regctl manifest get "$ref" --platform linux/amd64 --format '{{range .Layers}}{{.Size}} {{end}}' 2>/dev/null || true)
  if [ -z "$(printf '%s' "$sizes" | tr -d ' ')" ]; then
    sizes=$(regctl manifest get "$ref" --format '{{range .Layers}}{{.Size}} {{end}}' 2>/dev/null || true)
  fi
  for s in $sizes; do
    case "$s" in
      ''|*[!0-9]*) continue ;;
    esac
    sum=$((sum + s))
  done
  printf '%s' "$sum"
}

copy_progress_loop() {
  flag="$1"
  label="$2"
  start_net="$3"
  start_t="$4"
  interval="$5"
  case "$interval" in
    ''|*[!0-9]*) interval=30 ;;
  esac
  [ "$interval" -gt 0 ] 2>/dev/null || return 0
  while [ -f "$flag" ]; do
    sleep "$interval"
    [ -f "$flag" ] || break
    now_net=$(netdev_total_bytes)
    now_t=$(date +%s 2>/dev/null || printf '0')
    elapsed=$((now_t - start_t))
    delta=$((now_net - start_net))
    log "转发进行中 ${label} 已 ${elapsed}s 累计流量 $(format_bytes_human "$delta") 均速 $(format_rate_human "$delta" "$elapsed")"
  done
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

# 将 forward_state.tsv 打印到日志，便于 docker logs 查看已同步镜像与时间
log_forward_state() {
  if [ ! -s "$FORWARD_STATE" ]; then
    log "已同步记录：无（${FORWARD_STATE} 为空）"
    return 0
  fi
  n=0
  while IFS='	' read -r dst_repo tag built_epoch forwarded_epoch digest src_repo || [ -n "$dst_repo" ]; do
    [ -n "$dst_repo" ] && [ -n "$tag" ] || continue
    n=$((n + 1))
    digest_short="${digest}"
    case "$digest_short" in
      sha256:*) digest_short=$(printf '%s' "$digest_short" | cut -c1-19) ;;
    esac
    log "已同步[$n] ${ALIYUN_REGISTRY}/${dst_repo}:${tag} 编译 $(format_epoch_local "$built_epoch") 转发 $(format_epoch_local "$forwarded_epoch") 上游 ${src_repo} ${digest_short}"
  done <"$FORWARD_STATE"
  log "已同步合计 ${n} 条（${FORWARD_STATE}）"
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
  est_bytes=$(image_transfer_bytes "$src")
  est_human=$(format_bytes_human "$est_bytes")
  if [ "$est_bytes" -le 0 ] 2>/dev/null; then
    est_human="未知"
  fi
  log "转发 开始 $src -> $dst（编译 $(format_epoch_local "$src_epoch")，估算层体积 ${est_human}，超时 ${COPY_TIMEOUT_SECONDS}s）"
  log "$(proxy_env_summary)；上传 ${ALIYUN_REGISTRY} 走直连（NO_PROXY 含 ${NO_PROXY:-未设置}）"
  copy_start_t=$(date +%s 2>/dev/null || printf '0')
  net_start=$(netdev_total_bytes)
  progress_flag="$WORK_DIR/copy_$$.flag"
  : >"$progress_flag"
  copy_progress_loop "$progress_flag" "$dst" "$net_start" "$copy_start_t" "$COPY_PROGRESS_SECONDS" &
  progress_pid=$!
  copy_rc=0
  if ! timeout -s KILL -k 10 "$COPY_TIMEOUT_SECONDS" regctl image copy --fast "$src" "$dst"; then
    copy_rc=1
  fi
  rm -f "$progress_flag"
  wait "$progress_pid" 2>/dev/null || true
  copy_end_t=$(date +%s 2>/dev/null || printf '0')
  net_end=$(netdev_total_bytes)
  elapsed=$((copy_end_t - copy_start_t))
  [ "$elapsed" -lt 1 ] 2>/dev/null && elapsed=1
  net_delta=$((net_end - net_start))
  if [ "$copy_rc" -ne 0 ]; then
    log "转发失败 $dst（耗时 ${elapsed}s，流量 $(format_bytes_human "$net_delta")，均速 $(format_rate_human "$net_delta" "$elapsed")），保留待下轮重试: $src"
    return 1
  fi
  if ! regctl manifest head "$dst" >/dev/null 2>&1; then
    log "阿里云未见 $dst（耗时 ${elapsed}s），待下轮重试"
    return 1
  fi
  forward_state_write "$dst_repo" "$tag" "$src_epoch" "$src_digest" "$src_repo"
  eff_note=""
  if [ "$est_bytes" -gt 0 ] 2>/dev/null; then
    eff_note="，按层体积均速 $(format_rate_human "$est_bytes" "$elapsed")"
  fi
  log "转发成功 $dst（编译 $(format_epoch_local "$src_epoch")，耗时 ${elapsed}s，流量 $(format_bytes_human "$net_delta")，链路均速 $(format_rate_human "$net_delta" "$elapsed")${eff_note}）"
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
    log "扫描：无可用映射（上游无 tag 或未选出 owner）"
    return 1
  fi
  log "扫描映射：$active_map"
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
      log "扫描 ${src_repo} -> ${dst_repo}：上游无 tag"
      continue
    fi
    tags_checked=0
    tags_uptodate=0
    tags_queued=0
    while IFS= read -r tag || [ -n "$tag" ]; do
      [ -n "$tag" ] || continue
      case "$tag" in latest|sha256-*) continue ;; esac
      tags_checked=$((tags_checked + 1))
      ref="${UPSTREAM_REGISTRY}/${src_repo}:${tag}"
      tag_epoch=$(manifest_created_epoch "$ref")
      st_epoch=$(forward_state_read "$dst_repo" "$tag" | head -n 1)
      if [ "$tag_epoch" -gt 0 ] && [ "$st_epoch" -gt 0 ] && [ "$tag_epoch" -lt "$st_epoch" ] 2>/dev/null; then
        tags_uptodate=$((tags_uptodate + 1))
        continue
      fi
      dst_ref="${ALIYUN_REGISTRY}/${dst_repo}:${tag}"
      if regctl manifest head "$dst_ref" >/dev/null 2>&1; then
        dst_epoch=$(manifest_created_epoch "$dst_ref")
        if [ "$tag_epoch" -gt 0 ] && [ "$dst_epoch" -gt 0 ] && [ "$tag_epoch" -lt "$dst_epoch" ] 2>/dev/null; then
          tags_uptodate=$((tags_uptodate + 1))
          continue
        fi
      fi
      tags_queued=$((tags_queued + 1))
      printf '%s %s %s\n' "$src_repo" "$tag" "$dst_repo" >>"$job_file"
    done <"$tag_file"
    log "扫描 ${src_repo} -> ${dst_repo}：检查 ${tags_checked} tag，已最新 ${tags_uptodate}，待转发 ${tags_queued}"
  done
  if [ ! -s "$job_file" ]; then
    log "本轮无待转发 tag"
    log_forward_state
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
  job_total=0
  while IFS=' ' read -r _sr _tg _dr || [ -n "$_sr" ]; do
    [ -n "$_sr" ] && [ -n "$_tg" ] && [ -n "$_dr" ] || continue
    job_total=$((job_total + 1))
  done <"$job_file"
  log "待转发 ${job_total} 个 tag（去重后）"
  job_idx=0
  n=0
  while IFS=' ' read -r src_repo tag dst_repo || [ -n "$src_repo" ]; do
    [ -n "$src_repo" ] && [ -n "$tag" ] && [ -n "$dst_repo" ] || continue
    job_idx=$((job_idx + 1))
    log "进度 [${job_idx}/${job_total}] ${ALIYUN_REGISTRY}/${dst_repo}:${tag}"
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
  ok_count=0
  if [ -s "$copied_file" ]; then
    ok_count=$(wc -l <"$copied_file" | tr -d ' ')
  fi
  log "本轮结束：新转发成功 ${ok_count}/${job_total}"
  log_forward_state
  if [ "$ok_count" -gt 0 ] 2>/dev/null; then
    return 0
  fi
  return 1
}

if [ -z "${REPO_MAP:-}" ]; then
  log "映射模式：${UPSTREAM_OWNERS} 中每包选编译最新的 owner；按镜像编译时间转发，状态 ${FORWARD_STATE}"
else
  log "映射模式：固定 REPO_MAP"
fi
log "中转启动，上游 ${UPSTREAM_REGISTRY} -> ${ALIYUN_REGISTRY}，超时 ${COPY_TIMEOUT_SECONDS}s，并发 ${COPY_JOBS}，copy 心跳 ${COPY_PROGRESS_SECONDS}s"
log "$(proxy_env_summary)"
log "上传直连 NO_PROXY=${NO_PROXY:-未设置}"
if ! verify_upstream >/dev/null 2>&1; then
  log "上游登录校验失败，请检查 UPSTREAM_USER / UPSTREAM_TOKEN"
  exit 1
fi
if ! verify_aliyun >/dev/null 2>&1; then
  log "阿里云登录校验失败，请检查 ALIYUN_USERNAME / ALIYUN_PASSWORD"
  exit 1
fi
log "已登录，开始轮询"
log_forward_state

while true; do
  login_upstream >/dev/null
  login_aliyun >/dev/null
  log "—— 轮询（间隔 ${POLL_SECONDS}s）——"
  scan_once || true
  sleep "$POLL_SECONDS"
done
