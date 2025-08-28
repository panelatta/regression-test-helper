#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 一、可调参数（都可用环境变量覆盖）
###############################################################################
WORKDIR="${WORKDIR:-$HOME/repeater-demo}"          # 工作目录（缓存下载/日志）
SANDBOX_PORT="${SANDBOX_PORT:-12580}"              # sandbox/repeater 监听端口（要求固定为 12580）
GSR_PORT="${GSR_PORT:-8080}"                       # 示例服务端口（仅在 START_GSR=true 且系统装有 Java 时启动）

# 你提供的已编译 gs-rest-service JAR（避免 git/mvn）
GSR_JAR_URL="${GSR_JAR_URL:-https://github.com/panelatta/regression-test-helper/raw/refs/heads/main/gs-rest-service/complete/target/gs-rest-service-0.1.0.jar}"

# 官方 Release 包（安装 sandbox 与 repeater 模块；如需内网镜像可改这两项）
SANDBOX_TAR_URL="${SANDBOX_TAR_URL:-https://github.com/alibaba/jvm-sandbox-repeater/releases/download/v1.0.0/sandbox-1.3.3-bin.tar}"
REPEATER_TAR_URL="${REPEATER_TAR_URL:-https://github.com/alibaba/jvm-sandbox-repeater/releases/download/v1.0.0/repeater-stable-bin.tar}"

# cloudflared 可执行文件路径（若不存在会自动下载到此处）
CLOUDFLARE_BIN="${CLOUDFLARE_BIN:-$HOME/bin/cloudflared}"

# 是否在 Pod 内启动示例服务并注入 sandbox；是否启动 cloudflared Quick Tunnel
START_GSR="${START_GSR:-true}"
START_TUNNEL="${START_TUNNEL:-true}"

###############################################################################
# 二、基础工具与函数（尽量只用 18.04 常见命令）
###############################################################################
log()  { printf "\033[1;32m[%s]\033[0m %s\n" "$(date +'%F %T')" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

need_cmds=(bash curl tar sed grep ps awk nohup)
for c in "${need_cmds[@]}"; do have "$c" || err "缺少命令：$c（请在镜像中安装）"; done

mkdir -p "$WORKDIR"

###############################################################################
# 三、下载 gs-rest-service.jar（存在即跳过，可重复执行幂等）
###############################################################################
GSR_JAR="$WORKDIR/gs-rest-service.jar"
if [ -s "$GSR_JAR" ]; then
  log "命中缓存：$GSR_JAR 已存在，跳过下载"
else
  log "下载示例服务 JAR → $GSR_JAR"
  curl -fsSL "$GSR_JAR_URL" -o "$GSR_JAR" || err "下载 gs-rest-service.jar 失败"
  log "下载完成：$(ls -lh "$GSR_JAR" | awk '{print $5" "$9}')"
fi

###############################################################################
# 四、生成并执行“修补版” install-repeater.sh
#    - 仅用 curl/tar 解压官方二进制
#    - curl 强制改为 -fsSL（跟随重定向+失败即退出）
#    - 已安装则跳过
###############################################################################
PATCHED_INSTALL="$WORKDIR/install-repeater.sh"
if [ ! -s "$PATCHED_INSTALL" ]; then
  log "生成修补后的安装脚本（curl -fsSL；URL 可配置）"
  cat > "$PATCHED_INSTALL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SANDBOX_HOME="${HOME}/sandbox"
MODULE_HOME="${HOME}/.sandbox-module"

main () {
  echo "[install] 下载 sandbox ..."
  curl -fsSL "${SANDBOX_TAR_URL}" | tar xz -C "${HOME}"

  echo "[install] 下载 repeater 模块 ..."
  mkdir -p "${MODULE_HOME}"
  curl -fsSL "${REPEATER_TAR_URL}" | tar xz -C "${MODULE_HOME}"

  echo "[install] 安装完成"
}
main
EOF
  chmod +x "$PATCHED_INSTALL"
fi

# 传入 URL 变量（可在外部通过环境变量覆盖）
export SANDBOX_TAR_URL REPEATER_TAR_URL

if [ -x "$HOME/sandbox/bin/sandbox.sh" ] && [ -d "$HOME/.sandbox-module/repeater" ]; then
  log "检测到 sandbox 与 repeater 模块已安装，跳过安装"
else
  log "执行安装脚本 → $PATCHED_INSTALL"
  bash "$PATCHED_INSTALL"
fi

###############################################################################
# 五、按你的要求：复制 ~/.sandbox-module/repeater → ~/.sandbox-repeater
###############################################################################
MODULE_HOME="$HOME/.sandbox-module"
SRC="$MODULE_HOME/repeater"
DST="$HOME/.sandbox-repeater"
if [ -d "$SRC" ]; then
  log "同步 $SRC → $DST（保持内容一致）"
  mkdir -p "$DST"
  # 使用 tar 管道，避免依赖 rsync 等额外工具
  ( cd "$SRC" && tar cf - . ) | ( cd "$DST" && tar xpf - )
else
  err "未找到 repeater 模块目录：$SRC"
fi

###############################################################################
# 六、配置 repeat.standalone.mode=false（按教程）
###############################################################################
CFG_DIR="$MODULE_HOME/cfg"
CFG_FILE="$CFG_DIR/repeater.properties"
mkdir -p "$CFG_DIR"
if [ -f "$CFG_FILE" ] && grep -q '^repeat.standalone.mode=' "$CFG_FILE"; then
  sed -i 's/^repeat.standalone.mode=.*/repeat.standalone.mode=false/' "$CFG_FILE"
else
  echo 'repeat.standalone.mode=false' >> "$CFG_FILE"
fi
log "配置完成：$CFG_FILE 中 repeat.standalone.mode=false"

###############################################################################
# 七、（可选）启动示例服务并注入 sandbox（端口固定 12580）
#     - 状态提示/校验：
#         * 示例服务端口是否就绪
#         * sandbox attach 是否成功（解析 attach 回显）
#         * SERVER_PORT 是否等于 12580
#         * repeater 模块是否出现在已加载模块列表；必要时 -F 刷新
###############################################################################
REPEATER_MODULE_ID="repeater"

start_gsr_and_inject() {
  if ! have java; then
    warn "未安装 Java，跳过启动示例服务与注入（仅完成安装/配置）"
    return 0
  fi

  # 1) 启动示例服务
  log "后台启动 gs-rest-service（端口 $GSR_PORT） ..."
  nohup java -Dserver.port="$GSR_PORT" -jar "$GSR_JAR" > "$WORKDIR/gs-rest-service.log" 2>&1 &
  local app_pid=$!
  log "示例服务已启动，PID=$app_pid；日志：$WORKDIR/gs-rest-service.log"

  # 2) 等待端口就绪（最多 30s），用 bash 的 /dev/tcp（无需 nc）
  local ready=0 i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    (echo >/dev/tcp/127.0.0.1/$GSR_PORT) >/dev/null 2>&1 && { ready=1; break; } || sleep 1
  done
  if [ $ready -eq 1 ]; then
    log "示例服务端口就绪：127.0.0.1:$GSR_PORT"
  else
    warn "未确认到端口就绪（继续尝试注入，若失败请查看 $WORKDIR/gs-rest-service.log）"
  fi

  # 3) 精确定位目标 PID（避免依赖 pgrep）
  local target_pid
  target_pid="$(ps -eo pid,cmd | grep -F "$GSR_JAR" | grep -v grep | awk '{print $1}' | head -n1)"
  [ -z "${target_pid:-}" ] && target_pid="$app_pid"
  [ -z "${target_pid:-}" ] && err "无法定位示例服务 PID"

  # 4) 注入 sandbox（指定端口 12580）
  local SBOX="$HOME/sandbox/bin/sandbox.sh"
  [ -x "$SBOX" ] || err "未找到 $SBOX"
  log "向 PID=$target_pid 注入 sandbox（指定端口：$SANDBOX_PORT） ..."
  local attach_log="$WORKDIR/sandbox-attach.log"
  bash "$SBOX" -p "$target_pid" -P "$SANDBOX_PORT" > "$attach_log" 2>&1 || true

  # 5) 校验 attach 回显（端口 & 基本信息）
  if grep -q 'SERVER_PORT' "$attach_log"; then
    log "附加回显（关键信息）如下："
    grep -E 'NAMESPACE|VERSION|MODE|SERVER_ADDR|SERVER_PORT' "$attach_log" || true
    if grep -q "SERVER_PORT[[:space:]]*:[[:space:]]*$SANDBOX_PORT" "$attach_log"; then
      log "端口校验通过：SERVER_PORT = $SANDBOX_PORT"
    else
      err "端口校验失败：未在回显中发现 SERVER_PORT=$SANDBOX_PORT（请检查 $attach_log）"
    fi
  else
    err "未看到 sandbox 附加成功的回显（请检查 $attach_log）"
  fi

  # 6) 检查 repeater 模块是否加载；未加载则尝试 -F 刷新后再检查一次
  log "检查已加载模块列表（应包含：$REPEATER_MODULE_ID） ..."
  local list_log="$WORKDIR/sandbox-modules.log"
  bash "$SBOX" -p "$target_pid" -P "$SANDBOX_PORT" -l > "$list_log" 2>&1 || true
  if grep -qi "$REPEATER_MODULE_ID" "$list_log"; then
    log "模块已加载：$REPEATER_MODULE_ID"
  else
    warn "首次未检测到 $REPEATER_MODULE_ID，尝试执行 -F 刷新用户模块后重试"
    bash "$SBOX" -p "$target_pid" -P "$SANDBOX_PORT" -F > "$WORKDIR/sandbox-refresh.log" 2>&1 || true
    bash "$SBOX" -p "$target_pid" -P "$SANDBOX_PORT" -l > "$list_log" 2>&1 || true
    if grep -qi "$REPEATER_MODULE_ID" "$list_log"; then
      log "刷新后已检测到模块：$REPEATER_MODULE_ID"
    else
      warn "仍未检测到 $REPEATER_MODULE_ID，请检查 ~/.sandbox-module/repeater 是否完整；详见 $list_log"
    fi
  fi

  log "repeater 配置文件：$HOME/.sandbox-module/cfg/repeater.properties（已设置 standalone=false）"
}

if [ "${START_GSR}" = "true" ]; then
  start_gsr_and_inject
else
  log "已完成安装/配置。未启动示例服务（START_GSR=false）"
fi

###############################################################################
# 八、cloudflared Quick Tunnel（把 12580 暴露到公网）
#     - 若未安装，自动下载对应架构二进制
#     - 后台启动并解析 trycloudflare.com 的临时域名
#     - 显示可供本地 repeater-console 使用的 HTTPS 入口
###############################################################################
if [ "${START_TUNNEL}" = "true" ]; then
  if ! have "$CLOUDFLARE_BIN"; then
    log "未发现 cloudflared，准备下载（仅用 curl）"
    mkdir -p "$(dirname "$CLOUDFLARE_BIN")"
    ARCH="$(uname -m)"
    case "$ARCH" in
      x86_64|amd64) CF_ARCH="amd64" ;;
      aarch64|arm64) CF_ARCH="arm64" ;;
      *) err "未知架构 $ARCH，请手动提供 cloudflared 可执行文件" ;;
    esac
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH" -o "$CLOUDFLARE_BIN"
    chmod +x "$CLOUDFLARE_BIN"
    log "cloudflared 已下载：$CLOUDFLARE_BIN"
  fi

  log "启动 cloudflared Quick Tunnel → http://127.0.0.1:${SANDBOX_PORT}"
  TLOG="$WORKDIR/cloudflared-${SANDBOX_PORT}.log"
  nohup "$CLOUDFLARE_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:${SANDBOX_PORT}" > "$TLOG" 2>&1 &

  # 等待日志中出现 trycloudflare URL（最多 40s）
  T_URL=""
  for i in 1 2 3 4 5 6 7 8 9 10 \
           11 12 13 14 15 16 17 18 19 20 \
           21 22 23 24 25 26 27 28 29 30 \
           31 32 33 34 35 36 37 38 39 40; do
    if grep -Eo 'https://[-a-z0-9.]*trycloudflare\.com' "$TLOG" >/dev/null 2>&1; then
      T_URL="$(grep -Eo 'https://[-a-z0-9.]*trycloudflare\.com' "$TLOG" | tail -n1)"
      break
    fi
    sleep 1
  done

  if [ -n "$T_URL" ]; then
    log "Cloudflared 隧道已就绪：$T_URL"
    echo ">>> 请在你本地运行的 repeater-console 中，将目标 Sandbox 地址设置为：$T_URL"
    echo ">>> 该地址会反代到 Pod 内的 127.0.0.1:${SANDBOX_PORT}（HTTPS → 12580）"
  else
    err "未能解析到 cloudflared URL，请检查日志：$TLOG"
  fi
else
  log "未启动 cloudflared（START_TUNNEL=false）。如需公网连接，请启用它。"
fi

log "全部完成。"

