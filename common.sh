#!/bin/bash
# ============================================================
# sumingdk - 公共函数库
# 被 setup.sh / install.sh / caddy-install.sh / docker-install.sh 共享
# 作者：wsuming97
#
# 使用方式：source /usr/local/lib/sumingdk/common.sh
# ============================================================

# 防止重复 source
[ -n "$_SUMINGDK_COMMON_LOADED" ] && return 0
_SUMINGDK_COMMON_LOADED=1

# ============================================================
# 颜色变量
# ============================================================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
BOLD=$'\033[1m'

# ============================================================
# 输出工具函数
# ============================================================
info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
die()   { error "$1"; exit 1; }
line()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# 带日志记录的输出（供 backup/restore 使用，需先设置 LOG_FILE）
log_info()  { info "$1";  _log "INFO" "$1"; }
log_ok()    { ok "$1";    _log "OK" "$1"; }
log_warn()  { warn "$1";  _log "WARN" "$1"; }
log_error() { error "$1"; _log "ERROR" "$1"; }
log_fatal() { log_error "$1"; exit 1; }

_log() {
    local level="$1" msg="$2"
    if [ -n "${LOG_FILE:-}" ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE"
    fi
}

# 分隔线（加粗版，备份/还原脚本用）
separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================================
# 下载公共模块到本地（供各脚本 init_env 调用）
# ============================================================
COMMON_LIB_DIR="/usr/local/lib/sumingdk"
COMMON_LIB_PATH="${COMMON_LIB_DIR}/common.sh"
REPO_BASE="https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main"

# 确保 common.sh 存在于本地；不存在则下载
ensure_common_lib() {
    if [ ! -f "${COMMON_LIB_PATH}" ]; then
        mkdir -p "${COMMON_LIB_DIR}"
        curl -sL "${REPO_BASE}/common.sh" -o "${COMMON_LIB_PATH}" 2>/dev/null || true
        chmod +x "${COMMON_LIB_PATH}" 2>/dev/null || true
    fi
}

# ============================================================
# 公共功能：查看服务端口占用
# 避免在 install.sh 和 caddy-install.sh 中重复 ~60 行代码
# ============================================================
cmd_ports() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 一、系统端口监听总览（所有进程）${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""

    # 表头
    printf "  ${CYAN}%-8s %-28s %-20s${NC}\n" "协议" "监听地址" "进程"
    echo -e "  ${BLUE}──────── ──────────────────────────── ────────────────────${NC}"

    # 解析 ss 输出，只取 tcp LISTEN 和 udp UNCONN（即监听状态）
    # 跳过 IPv6 重复行以保持简洁
    ss -ntulp 2>/dev/null | awk 'NR>1 {
        proto = $1
        addr  = $5
        proc  = $7
        # 提取进程名
        match(proc, /users:\(\("([^"]+)"/, m)
        pname = m[1] ? m[1] : "-"
        # 只显示 IPv4 行（避免重复）
        if (addr !~ /^\[/) {
            printf "  %-8s %-28s %-20s\n", proto, addr, pname
        }
    }'

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${BOLD} 二、Docker 容器端口映射${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""

    if ! command -v docker &>/dev/null; then
        warn "Docker 未安装，跳过容器端口查询"
        echo ""
        return 0
    fi

    # 检查是否有运行中的容器
    local running_count
    running_count=$(docker ps -q 2>/dev/null | wc -l)
    if [ "$running_count" -eq 0 ]; then
        echo -e "  ${YELLOW}当前无运行中的 Docker 容器${NC}"
        echo ""
        return 0
    fi

    printf "  ${CYAN}%-22s %-50s${NC}\n" "容器名称" "端口映射"
    echo -e "  ${BLUE}────────────────────── ──────────────────────────────────────────────────${NC}"

    docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | while IFS=$'\t' read -r name ports; do
        if [ -z "$ports" ]; then
            printf "  %-22s ${YELLOW}%-50s${NC}\n" "$name" "(仅内部通信，无对外端口)"
        else
            local short_ports
            short_ports=$(echo "$ports" | sed 's/, \[::\]:[0-9]*->[0-9]*\/tcp//g; s/, \[::\]:[0-9]*->[0-9]*\/udp//g')
            printf "  %-22s %-50s\n" "$name" "$short_ports"
        fi
    done

    echo ""
    echo -e "  ${GREEN}提示${NC}: 地址为 ${CYAN}0.0.0.0:端口${NC} 表示对外开放；仅显示内部端口（如 5432/tcp）表示仅容器间通信"
    echo ""
}
