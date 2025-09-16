#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 基本参数（可用环境变量覆盖）
###############################################################################
WORKDIR="${WORKDIR:-$HOME/repeater-work}"
SANDBOX_PORT="${SANDBOX_PORT:-12580}"
SANDBOX_JAVA_MEM_OPTS="${SANDBOX_JAVA_MEM_OPTS:--Xms32m -Xmx128m -XX:+UseSerialGC}"
# 你的 console 地址（你提供的域名，走 HTTPS）
CONSOLE_BASE_URL="${CONSOLE_BASE_URL:-https://repeater-alpha.tplinkcloud.com}"

# Release 包（可换内网源）
SANDBOX_TAR_URL="${SANDBOX_TAR_URL:-https://github.com/alibaba/jvm-sandbox-repeater/releases/download/v1.0.0/sandbox-1.3.3-bin.tar}"
REPEATER_TAR_URL="${REPEATER_TAR_URL:-https://github.com/panelatta/sandbox-repeater/releases/download/v1.1.4/repeater-stable-bin.tar}"

# 多 JVM 时的行为：true=对“所有” Java 进程都 attach；false=仅自动挑一个
ATTACH_ALL="${ATTACH_ALL:-true}"

###############################################################################
# 工具与校验
###############################################################################
log()  { printf "\033[1;32m[%s]\033[0m %s\n" "$(date +'%F %T')" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_cmds=(bash curl tar sed grep ps awk nohup hostname find tr cut)
for c in "${need_cmds[@]}"; do have "$c" || err "缺少命令：$c"; done
mkdir -p "$WORKDIR"

download_and_extract() {
  local url="$1" dest="$2"
  log "下载并解压：$url → $dest"
  if ! curl -fsSL "$url" | tar xz -C "$dest"; then
    warn "不是 gzip 压缩，使用普通 tar 解压"
    curl -fsSL "$url" | tar x -C "$dest"
  fi
}

resolve_sandbox_home() {
  if [ -x "$HOME/sandbox/bin/sandbox.sh" ]; then (cd "$HOME/sandbox" && pwd;); return; fi
  local cand; cand="$(find "$HOME" -maxdepth 3 -type f -path "$HOME/*/bin/sandbox.sh" -print -quit 2>/dev/null || true)"
  [ -n "${cand:-}" ] && { (cd "$(dirname "$cand")/.." && pwd); return; }
  echo ""
}

get_pod_ip() {
  if have getent; then
    local ip; ip="$(getent hosts "$(hostname)" | awk '{print $1}' | head -n1)"
    [ -n "$ip" ] && { echo "$ip"; return; }
  fi
  local ip2; ip2="$(grep -m1 -E "[[:space:]]$(hostname)([[:space:]]|\$)" /etc/hosts | awk '{print $1}')"
  [ -n "$ip2" ] && { echo "$ip2"; return; }
  if have ip; then
    local ip3; ip3="$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
    [ -n "$ip3" ] && { echo "$ip3"; return; }
  fi
  echo "UNKNOWN"
}

###############################################################################
# 安装 sandbox + repeater 模块
###############################################################################
PATCHED_INSTALL="$WORKDIR/install-repeater.sh"
if [ ! -s "$PATCHED_INSTALL" ]; then
  cat > "$PATCHED_INSTALL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
download_and_extract() {
  local url="$1" dest="$2"
  echo "[install] 下载并解压：$url → $dest"
  if ! curl -fsSL "$url" | tar xz -C "$dest"; then
    echo "[install][WARN] 不是 gzip 压缩，改用普通 tar 解压" >&2
    curl -fsSL "$url" | tar x -C "$dest"
  fi
}
make_sandbox_symlink() {
  local cand dir
  cand="$(find "$HOME" -maxdepth 3 -type f -path "$HOME/*/bin/sandbox.sh" -print -quit 2>/dev/null || true)"
  if [ -n "${cand:-}" ]; then
    dir="$(cd "$(dirname "$cand")/.." && pwd)"
    ln -sfn "$dir" "$HOME/sandbox"
    echo "[install] 绑定稳定入口：$HOME/sandbox -> $dir"
  else
    echo "[install][WARN] 未发现 bin/sandbox.sh，符号链接未创建" >&2
  fi
}
MODULE_HOME="${HOME}/.sandbox-module"
main () {
  echo "[install] 下载 sandbox ..."
  download_and_extract "${SANDBOX_TAR_URL}" "${HOME}"
  echo "[install] 绑定 $HOME/sandbox 稳定入口 ..."
  make_sandbox_symlink
  echo "[install] 下载 repeater 模块 ..."
  mkdir -p "${MODULE_HOME}"
  download_and_extract "${REPEATER_TAR_URL}" "${MODULE_HOME}"
  echo "[install] 安装完成"
}
main
EOF
  chmod +x "$PATCHED_INSTALL"
fi

export SANDBOX_TAR_URL REPEATER_TAR_URL
if [ -x "$HOME/sandbox/bin/sandbox.sh" ] && [ -d "$HOME/.sandbox-module/repeater" ]; then
  log "检测到 sandbox 与 repeater 已安装，跳过安装"
else
  log "执行安装脚本 → $PATCHED_INSTALL"; bash "$PATCHED_INSTALL"
fi

# 合并 & 同步模块目录
MODULE_HOME="$HOME/.sandbox-module"
REPEATER_DIR="$MODULE_HOME/repeater"
[ -d "$REPEATER_DIR" ] || err "未找到 repeater 模块目录：$REPEATER_DIR"
log "合并 $REPEATER_DIR/* → $MODULE_HOME"; ( cd "$REPEATER_DIR" && tar cf - . ) | ( cd "$MODULE_HOME" && tar xpf - )
mkdir -p "$HOME/.sandbox-repeater"; log "同步 $REPEATER_DIR → ~/.sandbox-repeater"; ( cd "$REPEATER_DIR" && tar cf - . ) | ( cd "$HOME/.sandbox-repeater" && tar xpf - )

###############################################################################
# 自动探测：应用名 & 环境
###############################################################################
detect_app_and_env() {
  local pid="$1"
  local env_file="/proc/${pid}/environ"
  local cmd_file="/proc/${pid}/cmdline"
  local env_kv cmdline
  [ -r "$env_file" ] && env_kv="$(tr '\0' '\n' < "$env_file")" || env_kv=""
  [ -r "$cmd_file" ] && cmdline="$(tr '\0' ' '  < "$cmd_file")" || cmdline=""

  # ---- 应用名 appName ----
  # 1) SPRING_APPLICATION_NAME（环境变量）
  local app_name
  app_name="$(printf "%s\n" "$env_kv" | awk -F= '/^SPRING_APPLICATION_NAME=/{print $2; exit}')"
  # 2) -Dspring.application.name=（系统属性）
  [ -z "$app_name" ] && app_name="$(echo "$cmdline" | sed -n 's/.*-Dspring\.application\.name=\([^[:space:]]*\).*/\1/p' | head -n1)"
  # 3) -jar xxx.jar
  if [ -z "$app_name" ]; then
    local jar; jar="$(echo "$cmdline" | awk '{for(i=1;i<=NF;i++) if($i=="-jar"){print $(i+1); exit}}')"
    [ -n "$jar" ] && app_name="$(basename "$jar" | sed 's/\.jar$//')"
  fi
  # 4) 主类（启发式）：取第一个非 -X/-D/-cp/-classpath 选项的 token
  if [ -z "$app_name" ]; then
    app_name="$(echo "$cmdline" | awk '{
      skip=1; 
      for(i=1;i<=NF;i++){
        t=$i
        if (t=="-cp" || t=="-classpath"){i++; next}
        if (t ~ /^-/){next}
        if (skip){skip=0; next}  # 跳过第一个 java
        print t; exit
      }}' | sed 's/[,;].*$//' )"
  fi
  [ -z "$app_name" ] && app_name="unknown-app"

  # ---- 环境 environment ----
  # 1) SPRING_PROFILES_ACTIVE
  local env_name
  env_name="$(printf "%s\n" "$env_kv" | awk -F= '/^SPRING_PROFILES_ACTIVE=/{print $2; exit}')"
  # 2) 常见 ENV 变量
  [ -z "$env_name" ] && env_name="$(printf "%s\n" "$env_kv" | awk -F= '/^(APP_ENV|ENV|ENVIRONMENT|STAGE|PROFILE)=/{print $2; exit}')"
  # 3) -Dspring.profiles.active= / -Denv= / -Dprofile= / -Dstage=
  [ -z "$env_name" ] && env_name="$(echo "$cmdline" | sed -n 's/.*-Dspring\.profiles\.active=\([^[:space:]]*\).*/\1/p' | head -n1)"
  [ -z "$env_name" ] && env_name="$(echo "$cmdline" | sed -n 's/.*-Denv=\([^[:space:]]*\).*/\1/p' | head -n1)"
  [ -z "$env_name" ] && env_name="$(echo "$cmdline" | sed -n 's/.*-D\(profile\|stage\)=\([^[:space:]]*\).*/\2/p' | head -n1)"
  # 4) K8s namespace 兜底
  if [ -z "$env_name" ] && [ -r /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
    env_name="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace | tr -d '\n' )"
  fi
  [ -z "$env_name" ] && env_name="default"

  echo "${app_name}|${env_name}"
}

###############################################################################
# 生成 repeater 配置（联 console；standalone=false）
###############################################################################
gen_repeater_config() {
  local app_name="$1" env_name="$2"
  local cfg_dir="$HOME/.sandbox-module/cfg"
  local prop="$cfg_dir/repeater.properties"
  local json="$cfg_dir/repeater-config.json"
  mkdir -p "$cfg_dir"

  # repeater.properties（四个 URL 指向 console；关闭 standalone）
  cat > "$prop" <<EOF
# generated at $(date +'%F %T')
broadcaster.record.url=${CONSOLE_BASE_URL}/facade/api/record/save
broadcaster.repeat.url=${CONSOLE_BASE_URL}/facade/api/repeat/save
repeat.record.url=${CONSOLE_BASE_URL}/facade/api/record/%s/%s
repeat.config.url=${CONSOLE_BASE_URL}/facade/api/config/%s/%s
repeat.heartbeat.url=${CONSOLE_BASE_URL}/module/report.json
repeat.standalone.mode=false
EOF

  # repeater-config.json（最小可用集；附带 app/environment，若版本忽略也无害）
  # http 入口：默认全路径；后续可在 console 收敛
  cat > "$json" <<EOF
{
  "appName": "${app_name}",
  "environment": "${env_name}",
  "degrade": false,
  "exceptionThreshold": 1000,
  "httpEntrancePatterns": [ "^/.*$" ],
  "javaEntranceBehaviors": [],
  "javaSubInvokeBehaviors": [],
  "pluginIdentities": [ "http", "java-entrance", "java-subInvoke" ],
  "repeatIdentities": [ "java", "http" ],
  "sampleRate": 10000,
  "useTtl": true
}
EOF

  log "已生成配置：$prop / $json （app=${app_name}, env=${env_name}）"
}

###############################################################################
# attach 到目标 JVM
###############################################################################
attach_one() {
  local pid="$1" app_name="$2" env_name="$3"
  local SANDBOX_HOME SBOX attach_log list_log
  SANDBOX_HOME="$(resolve_sandbox_home)"; [ -n "$SANDBOX_HOME" ] || err "未找到 sandbox 安装目录"
  SBOX="$SANDBOX_HOME/bin/sandbox.sh";   [ -x "$SBOX" ]           || err "未找到 $SBOX"

  [ -f "$HOME/.sandbox.token" ] || printf "%s" "$(date +%Y%m%d%H%M%S)$$" > "$HOME/.sandbox.token"

  attach_log="$WORKDIR/sandbox-attach-${pid}.log"
  log "向 PID=$pid（${app_name}/${env_name}）注入 sandbox，端口：$SANDBOX_PORT ..."
  ( export JAVA_TOOL_OPTIONS="$SANDBOX_JAVA_MEM_OPTS ${JAVA_TOOL_OPTIONS:-}"; cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$pid" -P "$SANDBOX_PORT" ) >"$attach_log" 2>&1 || true

  if grep -q 'SERVER_PORT' "$attach_log"; then
    grep -E 'NAMESPACE|VERSION|MODE|SERVER_ADDR|SERVER_PORT' "$attach_log" || true
    grep -q "SERVER_PORT[[:space:]]*:[[:space:]]*$SANDBOX_PORT" "$attach_log" || err "SERVER_PORT 校验失败（详见 $attach_log）"
  else
    err "未看到 attach 成功的回显（详见 $attach_log）"
  fi

  # 验证模块加载；必要时刷新
  list_log="$WORKDIR/sandbox-modules-${pid}.log"
  ( cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$pid" -P "$SANDBOX_PORT" -l ) >"$list_log" 2>&1 || true
  if ! grep -qi "repeater" "$list_log"; then
    warn "未检测到 repeater 模块，尝试刷新"
    ( cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$pid" -P "$SANDBOX_PORT" -R ) >>"$WORKDIR/sandbox-refresh-${pid}.log" 2>&1 || true
    ( cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$pid" -P "$SANDBOX_PORT" -F ) >>"$WORKDIR/sandbox-refresh-${pid}.log" 2>&1 || true
    ( cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$pid" -P "$SANDBOX_PORT" -l ) >"$list_log" 2>&1 || true
    grep -qi "repeater" "$list_log" || warn "仍未检测到 repeater 模块，请检查 ~/.sandbox-module/repeater"
  fi
}

###############################################################################
# 主流程：遍历 Java 进程 → 生成配置 → attach
###############################################################################
# 枚举 Java PID
mapfile -t JAVA_PIDS < <(ps -eo pid,comm,args | awk '/[j]ava /{print $1}')
[ "${#JAVA_PIDS[@]}" -gt 0 ] || err "未发现任何 Java 进程，请先启动应用"

if [ "$ATTACH_ALL" = "true" ]; then
  TARGETS=("${JAVA_PIDS[@]}")
else
  TARGETS=("${JAVA_PIDS[0]}")
  [ "${#JAVA_PIDS[@]}" -gt 1 ] && warn "发现多个 Java 进程，仅对第一个 PID=${TARGETS[0]} 进行 attach；可设置 ATTACH_ALL=true"
fi

# 先生成一次通用配置（按最后一个探测到的 app/env 写入），再逐个 attach
# 注：当前 repeater 默认读取统一路径配置；我们把“app/env”也写进 json，供 console 索引使用
POD_IP="$(get_pod_ip)"
for pid in "${TARGETS[@]}"; do
  ident="$(detect_app_and_env "$pid")"
  app="${ident%%|*}"; env="${ident##*|}"
  gen_repeater_config "$app" "$env"
  attach_one "$pid" "$app" "$env"
  echo
  echo "--------------------[ Module for PID $pid ]--------------------"
  echo "APP_NAME   : $app"
  echo "ENV        : $env"
  echo "POD_IP     : $POD_IP"
  echo "SANDBOX_PORT: $SANDBOX_PORT"
  echo "console    : ${CONSOLE_BASE_URL}"
  echo "TOKEN_FILE : ${HOME}/.sandbox.token"
  echo "---------------------------------------------------------------"
  echo
done

echo
echo "====================[ 汇总 | SANDBOX 访问信息 ]===================="
echo "Pod IP: ${POD_IP}  | Port: ${SANDBOX_PORT}"
echo "Console: ${CONSOLE_BASE_URL}"
echo "提示：在 repeater-console 的“安装模块/在线模块”里，地址填 ${POD_IP}，端口 ${SANDBOX_PORT}"
echo "==================================================================="
