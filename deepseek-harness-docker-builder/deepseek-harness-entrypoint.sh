#!/bin/bash
set -euo pipefail
ensure_runtime_dirs() {
  mkdir -p /workspace/.dsh/profiles /home/node/.local/share/pnpm /home/node/.cache/node/corepack
  chown -R node:node /workspace /home/node
  chmod -R u+rwX,g+rwX /workspace/.dsh /workspace
  # credentials-local 拒绝 group/other 可读；g+rwX 之后必须收回。
  if [ -f /workspace/.dsh/.credentials.yaml ]; then
    chmod 600 /workspace/.dsh/.credentials.yaml
  fi
  if [ -f /workspace/.dsh/auth/users.yaml ]; then
    chmod 600 /workspace/.dsh/auth/users.yaml
  fi
}
ensure_web_profile() {
  tmpl=/opt/dsh-home-template/profiles/web
  dest=/workspace/.dsh/profiles/web
  rm -rf "$dest/node_modules"
  mkdir -p "$dest"
  if [ -d "$tmpl" ]; then
    cp -a "$tmpl/." "$dest/"
  fi
}
wait_launch_token() {
  log="$1"
  pid="$2"
  i=0
  while [ "$i" -lt 240 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "dsh web exited before printing launch token" >&2
      if [ -f "$log" ]; then
        cat "$log" >&2
      else
        echo "log not created: $log" >&2
      fi
      exit 1
    fi
    token=
    if [ -f "$log" ]; then
      token=$(sed -n 's/.*dsh web: http[^?]*\?token=\([^ )"]*\).*/\1/p' "$log" | sed -n '1p' || true)
    fi
    if [ -n "$token" ]; then
      echo "$token"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  echo "timed out waiting for dsh launch token in log" >&2
  if [ -f "$log" ]; then
    cat "$log" >&2
  fi
  exit 1
}
write_nginx_conf() {
  publish="$1"
  backend_port="$2"
  public_token="$3"
  launch_token="$4"
  node - "$publish" "$backend_port" "$public_token" "$launch_token" <<'NODE'
const fs = require('fs')
const [, , publish, backendPort, publicToken, launchToken] = process.argv
const esc = (s) => String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
const conf = `map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

map $arg_token $dsh_backend_args {
  "${esc(publicToken)}" "token=${esc(launchToken)}";
  default $args;
}

server {
  listen ${publish};
  listen [::]:${publish};
  server_name _;
  client_max_body_size 160m;

  location / {
    proxy_http_version 1.1;
    # 统一成 loopback，避免为每个公网域名配置 --trusted-host（DSH /api Host 栅栏）。
    proxy_set_header Host 127.0.0.1:${backendPort};
    proxy_set_header Origin http://127.0.0.1:${backendPort};
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 86400s;
    proxy_send_timeout 86400s;
    proxy_pass http://127.0.0.1:${backendPort}$uri$is_args$dsh_backend_args;
  }
}
`
fs.writeFileSync('/etc/nginx/conf.d/dsh-proxy.conf', conf)
NODE
}
build_dsh_web_cmd() {
  port="${DSH_WEB_PORT:-3081}"
  # 与原先 pnpm --dir 一样，在源码树里启动，避免把 WORKDIR /workspace 当成仓库根。
  # 必须落到调用方可见的数组：函数内 set -- 只改本函数的位置参数，run_stack 的 "$@" 仍为空，启动器会立刻退出。
  dsh_web_cmd=(
    env --chdir=/opt/deepseek-harness
    node /opt/deepseek-harness/apps/cli/lib/bin.js web
    --patch /opt/dsh/docker.patch.yml
    --port "$port"
    --no-open
  )
}
run_as_node() {
  # bookworm-slim 默认无 runuser/su，需 util-linux；优先 runuser，否则 su -p。
  if command -v runuser >/dev/null 2>&1; then
    runuser -u node --preserve-environment -- "$@"
  elif command -v su >/dev/null 2>&1; then
    su -p -s /bin/bash node -c 'shift; exec "$@"' _ "$@"
  else
    echo "WARN: missing runuser/su (install util-linux); running as $(id -un)" >&2
    "$@"
  fi
}
exec_as_node() {
  if command -v runuser >/dev/null 2>&1; then
    exec runuser -u node --preserve-environment -- "$@"
  elif command -v su >/dev/null 2>&1; then
    exec su -p -s /bin/bash node -c 'shift; exec "$@"' _ "$@"
  else
    echo "WARN: missing runuser/su; continuing as $(id -un)" >&2
    exec "$@"
  fi
}
run_stack() {
  publish="${DSH_PUBLISH_PORT:-3080}"
  port="${DSH_WEB_PORT:-3081}"
  public_token="${DSH_AUTH_TOKEN:?set DSH_AUTH_TOKEN to the fixed public ?token= value}"
  log=/workspace/.dsh/dsh-web.log
  mkdir -p /workspace/.dsh
  : >"$log"
  chown node:node "$log"
  chmod 644 "$log"
  build_dsh_web_cmd
  (
    if ! run_as_node bash -c 'log=$1; shift; "$@" >>"$log" 2>&1' bash "$log" "${dsh_web_cmd[@]}"; then
      echo "dsh web launcher failed with exit $?"
    fi
  ) >>"$log" 2>&1 &
  dsh_pid=$!
  launch_token=$(wait_launch_token "$log" "$dsh_pid")
  echo "dsh web: launch token captured (internal only)"
  write_nginx_conf "$publish" "$port" "$public_token" "$launch_token"
  echo "dsh web (public): use any reachable URL with ?token=${public_token} (port ${publish} on this container)"
  nginx -t
  nginx -g 'daemon off;' &
  nginx_pid=$!
  while kill -0 "$dsh_pid" 2>/dev/null && kill -0 "$nginx_pid" 2>/dev/null; do
    sleep 2
  done
  if kill -0 "$nginx_pid" 2>/dev/null; then
    kill "$nginx_pid" 2>/dev/null || true
    wait "$nginx_pid" 2>/dev/null || true
  fi
  if kill -0 "$dsh_pid" 2>/dev/null; then
    kill "$dsh_pid" 2>/dev/null || true
  fi
  wait "$dsh_pid"
}
if [ "$(id -u)" = "0" ]; then
  ensure_runtime_dirs
  ensure_web_profile
  chown -R node:node /workspace/.dsh
  if [ -f /workspace/.dsh/.credentials.yaml ]; then
    chmod 600 /workspace/.dsh/.credentials.yaml
  fi
  if [ -f /workspace/.dsh/auth/users.yaml ]; then
    chmod 600 /workspace/.dsh/auth/users.yaml
  fi
  if [ "$#" -eq 0 ]; then
    run_stack
  fi
  exec_as_node bash "$0" "$@"
fi
if [ "$#" -eq 0 ]; then
  echo "default start must run as root (nginx + dsh stack)" >&2
  exit 1
fi
exec "$@"
