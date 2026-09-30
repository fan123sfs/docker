#!/bin/sh
set -eu

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*"
}

LOCAL_REGISTRY="${LOCAL_REGISTRY:-registry:5000}"
ALIYUN_REGISTRY="${ALIYUN_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
FORWARD_PREFIX="${FORWARD_PREFIX:-syncimage/}"
POLL_SECONDS="${POLL_SECONDS:-15}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-acr-relay-registry}"
GC_IMAGE="${GC_IMAGE:-registry:3.1.2}"
REGISTRY_CONFIG="${REGISTRY_CONFIG:-/etc/distribution/config.yml}"
WORK_DIR="${WORK_DIR:-/tmp/acr-relay}"
COPY_TIMEOUT_SECONDS="${COPY_TIMEOUT_SECONDS:-600}"

need_var() {
  eval "val=\${$1-}"
  if [ -z "$val" ]; then
    log "缺少环境变量 $1"
    exit 1
  fi
}

need_var REGISTRY_USER
need_var REGISTRY_PASSWORD
need_var ALIYUN_USERNAME
need_var ALIYUN_PASSWORD

mkdir -p "$WORK_DIR"

regctl_local_tls() {
  regctl -v error registry set --tls disabled "$LOCAL_REGISTRY" >/dev/null 2>&1 || true
}

login_local() {
  printf '%s' "$REGISTRY_PASSWORD" | regctl -v error registry login "$LOCAL_REGISTRY" \
    -u "$REGISTRY_USER" --pass-stdin --skip-check
}

login_all() {
  login_local
  printf '%s' "$ALIYUN_PASSWORD" | regctl -v error registry login "$ALIYUN_REGISTRY" \
    -u "$ALIYUN_USERNAME" --pass-stdin --skip-check
}

verify_aliyun_login() {
  printf '%s' "$ALIYUN_PASSWORD" | regctl -v error registry login "$ALIYUN_REGISTRY" \
    -u "$ALIYUN_USERNAME" --pass-stdin
}

wait_registry() {
  regctl_local_tls
  n=0
  while [ "$n" -lt 90 ]; do
    if login_local >/dev/null 2>&1; then
      return 0
    fi
    n=$((n + 1))
    sleep 2
  done
  log "本地仓库仍未就绪: $LOCAL_REGISTRY"
  return 1
}

match_prefix() {
  repo="$1"
  if [ -z "$FORWARD_PREFIX" ]; then
    return 0
  fi
  case "$repo" in
    ${FORWARD_PREFIX}*) return 0 ;;
    *) return 1 ;;
  esac
}

gc_local() {
  if [ ! -S /var/run/docker.sock ]; then
    log "未挂载 docker.sock，跳过 GC（tag 已删，blob 仍占磁盘）"
    return 0
  fi
  if ! docker inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
    log "找不到容器 $REGISTRY_CONTAINER，跳过 GC"
    return 0
  fi
  log "暂停仓库并回收未引用 blob"
  if ! docker update --restart=no "$REGISTRY_CONTAINER" >/dev/null; then
    log "无法关闭自动重启，跳过 GC"
    return 1
  fi
  docker stop "$REGISTRY_CONTAINER" >/dev/null
  sleep 2
  gc_ok=0
  if docker run --rm --network none \
    --volumes-from "$REGISTRY_CONTAINER" \
    --entrypoint /bin/registry \
    "$GC_IMAGE" \
    garbage-collect --delete-untagged "$REGISTRY_CONFIG"; then
    gc_ok=1
  else
    log "GC 失败，正在拉起仓库"
  fi
  docker start "$REGISTRY_CONTAINER" >/dev/null || true
  docker update --restart=always "$REGISTRY_CONTAINER" >/dev/null || true
  wait_registry || true
  if [ "$gc_ok" -eq 1 ]; then
    log "GC 完成，仓库已恢复"
    return 0
  fi
  return 1
}

forward_tag() {
  repo="$1"
  tag="$2"
  src="${LOCAL_REGISTRY}/${repo}:${tag}"
  dst="${ALIYUN_REGISTRY}/${repo}:${tag}"
  if regctl manifest head "$dst" >/dev/null 2>&1; then
    log "阿里云已有 $dst，跳过 copy"
  else
    log "转发 $src -> $dst（超时 ${COPY_TIMEOUT_SECONDS}s）"
    if ! timeout "$COPY_TIMEOUT_SECONDS" regctl image copy --fast "$src" "$dst"; then
      ec=$?
      if [ "$ec" -eq 124 ] || [ "$ec" -eq 143 ]; then
        log "转发超时，保留本地 $src"
      else
        log "转发失败，保留本地 $src"
      fi
      return 1
    fi
  fi
  if ! regctl manifest head "$dst" >/dev/null 2>&1; then
    log "阿里云未见 $dst，保留本地"
    return 1
  fi
  log "转发成功，删除本地 $src"
  if ! regctl tag delete "$src"; then
    log "删除本地 tag 失败: $src"
    return 1
  fi
  return 0
}

scan_once() {
  deleted=0
  repo_file="$WORK_DIR/repos"
  tag_file="$WORK_DIR/tags"
  : >"$repo_file"
  regctl repo ls "$LOCAL_REGISTRY" >"$repo_file" 2>/dev/null || true
  if [ ! -s "$repo_file" ]; then
    return 1
  fi
  while IFS= read -r repo || [ -n "$repo" ]; do
    [ -n "$repo" ] || continue
    match_prefix "$repo" || continue
    : >"$tag_file"
    regctl tag ls "${LOCAL_REGISTRY}/${repo}" >"$tag_file" 2>/dev/null || true
    if [ ! -s "$tag_file" ]; then
      continue
    fi
    while IFS= read -r tag || [ -n "$tag" ]; do
      [ -n "$tag" ] || continue
      if forward_tag "$repo" "$tag"; then
        deleted=1
      fi
    done <"$tag_file"
  done <"$repo_file"
  if [ "$deleted" -eq 1 ]; then
    return 0
  fi
  return 1
}

log "中转启动，本地 $LOCAL_REGISTRY -> $ALIYUN_REGISTRY"
wait_registry
login_all
if ! verify_aliyun_login >/dev/null 2>&1; then
  log "阿里云登录校验失败，请检查 ALIYUN_USERNAME / ALIYUN_PASSWORD"
  exit 1
fi
log "已登录，开始轮询"

while true; do
  login_all >/dev/null
  if scan_once; then
    gc_local || true
  fi
  sleep "$POLL_SECONDS"
done
