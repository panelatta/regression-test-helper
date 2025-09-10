#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 一、可调参数（都可用环境变量覆盖）
###############################################################################
WORKDIR="${WORKDIR:-$HOME/repeater-demo}"          # 工作目录（缓存下载/日志）
SANDBOX_PORT="${SANDBOX_PORT:-12580}"              # sandbox/repeater 监听端口（要求固定为 12580）
GSR_PORT="${GSR_PORT:-18080}"                      # 示例服务端口（仅在 START_GSR=true 且系统装有 Java 时启动）

# JVM 内存（为避免 OOM，给出保守值；如内存充足可上调）
JAVA_MEM_OPTS="${JAVA_MEM_OPTS:--Xms32m -Xmx128m -XX:+UseSerialGC}"
SANDBOX_JAVA_MEM_OPTS="${SANDBOX_JAVA_MEM_OPTS:--Xms32m -Xmx128m -XX:+UseSerialGC}"

# 你提供的已编译 gs-rest-service JAR（避免 git/mvn）
GSR_JAR_URL="${GSR_JAR_URL:-https://github.com/panelatta/regression-test-helper/raw/refs/heads/main/gs-rest-service/complete/target/gs-rest-service-0.1.0.jar}"

# 官方 Release 包（安装 sandbox 与 repeater 模块；如需内网镜像可改这两项）
SANDBOX_TAR_URL="${SANDBOX_TAR_URL:-https://github.com/alibaba/jvm-sandbox-repeater/releases/download/v1.0.0/sandbox-1.3.3-bin.tar}"
REPEATER_TAR_URL="${REPEATER_TAR_URL:-https://github.com/panelatta/sandbox-repeater/releases/download/v1.1.4/repeater-stable-bin.tar}"

# cloudflared 可执行文件路径（若不存在会自动下载到此处）
# CLOUDFLARE_BIN="${CLOUDFLARE_BIN:-$HOME/bin/cloudflared}"

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

# 兼容 .tar 与 .tar.gz：先尝试 -xz，失败则降级为 -x
download_and_extract() {
  local url="$1" dest="$2"
  log "下载并解压：$url → $dest"
  if ! curl -fsSL "$url" | tar xz -C "$dest"; then
    warn "不是 gzip 压缩，使用普通 tar 解压"
    curl -fsSL "$url" | tar x -C "$dest"
  fi
}

# 解析 sandbox 绝对路径；若存在 $HOME/sandbox（目录或符号链接）优先使用
resolve_sandbox_home() {
  if [ -x "$HOME/sandbox/bin/sandbox.sh" ]; then
    (cd "$HOME/sandbox" && pwd)
    return
  fi
  # 在 $HOME 下找任意包含 bin/sandbox.sh 的目录（<=3 层）
  local cand
  cand="$(find "$HOME" -maxdepth 3 -type f -path "$HOME/*/bin/sandbox.sh" -print -quit 2>/dev/null || true)"
  if [ -n "${cand:-}" ]; then
    (cd "$(dirname "$cand")/.." && pwd)
    return
  fi
  echo ""  # 调用方决定是否 err
}

###############################################################################
# 三、下载 gs-rest-service.jar（存在即跳过）
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
# 四、生成并执行“修补版” install-repeater.sh（建立 $HOME/sandbox 稳定入口）
###############################################################################
PATCHED_INSTALL="$WORKDIR/install-repeater.sh"
if [ ! -s "$PATCHED_INSTALL" ]; then
  log "生成修补后的安装脚本（兼容 .tar/.tar.gz；建立稳定符号链接）"
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
    ln -sfn "$dir" "$HOME/sandbox"   # 稳定入口
    echo "[install] 绑定稳定入口：$HOME/sandbox -> $dir"
  else
    echo "[install][WARN] 未发现 bin/sandbox.sh，符号链接未创建；请检查解压结果" >&2
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
  log "检测到 sandbox 与 repeater 模块已安装，跳过安装"
else
  log "执行安装脚本 → $PATCHED_INSTALL"
  bash "$PATCHED_INSTALL"
fi

###############################################################################
# 4.5 覆盖拷贝：将 ~/.sandbox-module/repeater/* 合并到 ~/.sandbox-module/
#     目的：确保后续修改 ~/.sandbox-module/cfg/repeater.properties 命中拷贝到根的那份
#     说明：采用 tar 管道，避免依赖 rsync；可重复执行（幂等覆盖）
###############################################################################
MODULE_HOME="$HOME/.sandbox-module"
REPEATER_DIR="$MODULE_HOME/repeater"
if [ -d "$REPEATER_DIR" ]; then
  log "合并 $REPEATER_DIR/* → $MODULE_HOME"
  mkdir -p "$MODULE_HOME"
  ( cd "$REPEATER_DIR" && tar cf - . ) | ( cd "$MODULE_HOME" && tar xpf - )
else
  err "未找到 repeater 模块目录：$REPEATER_DIR（请检查安装是否成功）"
fi

###############################################################################
# 五、复制 ~/.sandbox-module/repeater → ~/.sandbox-repeater
###############################################################################
MODULE_HOME="$HOME/.sandbox-module"
SRC="$MODULE_HOME/repeater"
DST="$HOME/.sandbox-repeater"
if [ -d "$SRC" ]; then
  log "同步 $SRC → $DST（保持内容一致）"
  mkdir -p "$DST"
  ( cd "$SRC" && tar cf - . ) | ( cd "$DST" && tar xpf - )
else
  err "未找到 repeater 模块目录：$SRC"
fi

###############################################################################
# 六、配置 repeat.standalone.mode=false
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
# 七、启动示例服务并注入 sandbox（绝对路径 + 限制 JVM 内存）
###############################################################################
REPEATER_MODULE_ID="repeater"

start_gsr_and_inject() {
  if ! have java; then
    warn "未安装 Java，跳过启动示例服务与注入（仅完成安装/配置）"
    return 0
  fi

  # 1) 启动示例服务（限制堆，避免 OOM 137）
  log "后台启动 gs-rest-service（端口 $GSR_PORT） ..."
  nohup java $JAVA_MEM_OPTS -Djava.awt.headless=true -Dserver.port="$GSR_PORT" -jar "$GSR_JAR" > "$WORKDIR/gs-rest-service.log" 2>&1 &
  local app_pid=$!
  log "示例服务已启动，PID=$app_pid；日志：$WORKDIR/gs-rest-service.log"

  # 2) 等待端口就绪（最多 30s）
  local ready=0
  for i in {1..30}; do
    (echo >/dev/tcp/127.0.0.1/$GSR_PORT) >/dev/null 2>&1 && { ready=1; break; } || sleep 1
  done
  [ $ready -eq 1 ] && log "示例服务端口就绪：127.0.0.1:$GSR_PORT" || warn "未确认到端口就绪（继续尝试注入，若失败请看日志）"

  # 3) 精确定位 PID
  local target_pid
  target_pid="$(ps -eo pid,cmd | grep -F "$GSR_JAR" | grep -v grep | awk '{print $1}' | head -n1 || true)"
  [ -z "${target_pid:-}" ] && target_pid="$app_pid"
  [ -z "${target_pid:-}" ] && err "无法定位示例服务 PID"

  # 4) 注入 sandbox（绝对路径 + 进入 bin 执行；通过 JAVA_TOOL_OPTIONS 限制 JVM 内存）
  local SANDBOX_HOME SBOX attach_log list_log
  SANDBOX_HOME="$(resolve_sandbox_home)"
  [ -n "$SANDBOX_HOME" ] || err "未找到 sandbox 安装目录，请检查安装步骤"
  SBOX="$SANDBOX_HOME/bin/sandbox.sh"
  [ -x "$SBOX" ] || err "未找到可执行文件：$SBOX"
  [ -r "$SANDBOX_HOME/lib/sandbox-core.jar" ] || err "缺少 $SANDBOX_HOME/lib/sandbox-core.jar（安装异常）"

  # 预创建 token（减少噪音并供控制台使用）
  [ -f "$HOME/.sandbox.token" ] || printf "%s" "$(date +%Y%m%d%H%M%S)$$" > "$HOME/.sandbox.token"

  log "向 PID=$target_pid 注入 sandbox（指定端口：$SANDBOX_PORT） ..."
  attach_log="$WORKDIR/sandbox-attach.log"
  ( export JAVA_TOOL_OPTIONS="$SANDBOX_JAVA_MEM_OPTS ${JAVA_TOOL_OPTIONS:-}"; cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$target_pid" -P "$SANDBOX_PORT" ) >"$attach_log" 2>&1 || true

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
  list_log="$WORKDIR/sandbox-modules.log"
  ( export JAVA_TOOL_OPTIONS="$SANDBOX_JAVA_MEM_OPTS ${JAVA_TOOL_OPTIONS:-}"; cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$target_pid" -P "$SANDBOX_PORT" -l ) >"$list_log" 2>&1 || true
  if grep -qi "$REPEATER_MODULE_ID" "$list_log"; then
    log "模块已加载：$REPEATER_MODULE_ID"
  else
    warn "首次未检测到 $REPEATER_MODULE_ID，尝试执行 -F 刷新用户模块后重试"
    ( export JAVA_TOOL_OPTIONS="$SANDBOX_JAVA_MEM_OPTS ${JAVA_TOOL_OPTIONS:-}"; cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$target_pid" -P "$SANDBOX_PORT" -R ) >"$WORKDIR/sandbox-refresh.log" 2>&1 || true
    ( export JAVA_TOOL_OPTIONS="$SANDBOX_JAVA_MEM_OPTS ${JAVA_TOOL_OPTIONS:-}"; cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$target_pid" -P "$SANDBOX_PORT" -F ) >"$WORKDIR/sandbox-refresh.log" 2>&1 || true
    ( export JAVA_TOOL_OPTIONS="$SANDBOX_JAVA_MEM_OPTS ${JAVA_TOOL_OPTIONS:-}"; cd "$SANDBOX_HOME/bin" && ./sandbox.sh -p "$target_pid" -P "$SANDBOX_PORT" -l ) >"$list_log" 2>&1 || true
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
###############################################################################
# if [ "${START_TUNNEL}" = "true" ]; then
#   if ! have "$CLOUDFLARE_BIN"; then
#     log "未发现 cloudflared，准备下载（仅用 curl）"
#     mkdir -p "$(dirname "$CLOUDFLARE_BIN")"
#     ARCH="$(uname -m)"
#     case "$ARCH" in
#       x86_64|amd64) CF_ARCH="amd64" ;;
#       aarch64|arm64) CF_ARCH="arm64" ;;
#       *) err "未知架构 $ARCH，请手动提供 cloudflared 可执行文件" ;;
#     esac
#     curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH" -o "$CLOUDFLARE_BIN"
#     chmod +x "$CLOUDFLARE_BIN"
#     log "cloudflared 已下载：$CLOUDFLARE_BIN"
#   fi

#   log "启动 cloudflared Quick Tunnel → http://127.0.0.1:${SANDBOX_PORT}"
#   TLOG="$WORKDIR/cloudflared-${SANDBOX_PORT}.log"
#   nohup "$CLOUDFLARE_BIN" tunnel --no-autoupdate --url "http://127.0.0.1:${SANDBOX_PORT}" > "$TLOG" 2>&1 &

#   # 等待日志中出现 trycloudflare URL（最多 40s）
#   T_URL=""
#   for i in {1..40}; do
#     if grep -Eo 'https://[-a-z0-9.]*trycloudflare\.com' "$TLOG" >/dev/null 2>&1; then
#       T_URL="$(grep -Eo 'https://[-a-z0-9.]*trycloudflare\.com' "$TLOG" | tail -n1)"
#       break
#     fi
#     sleep 1
#   done

#   if [ -n "$T_URL" ]; then
#     log "Cloudflared 隧道已就绪：$T_URL"
#     echo ">>> 请在你本地运行的 repeater-console 中，将目标 Sandbox 地址设置为：$T_URL"
#     echo ">>> 该地址会反代到 Pod 内的 127.0.0.1:${SANDBOX_PORT}（HTTPS → 12580）"
#   else
#     err "未能解析到 cloudflared URL，请检查日志：$TLOG"
#   fi
# else
#   log "未启动 cloudflared（START_TUNNEL=false）。如需公网连接，请启用它。"
# fi

log "全部完成。"

