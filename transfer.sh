#!/bin/bash
# ============================================================
# sumingdk - Docker 通用迁移工具 · 传输脚本
# 在旧 VPS 上运行，将备份传输到新 VPS
#
# 用法：
#   bash transfer.sh <备份文件> <目标IP> [选项]
#   bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 192.168.1.100
#   bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 192.168.1.100 --port 55520
#   bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 192.168.1.100 --method rsync
#
# 支持传输方式：scp、rsync（默认）、tar+ssh 管道
# ============================================================

set -euo pipefail

# ============================================================
# 全局变量
# ============================================================
VERSION="1.0.0"

# 参数
BACKUP_FILE=""
TARGET_HOST=""
TARGET_USER="root"
SSH_PORT="22"
METHOD="rsync"                   # rsync | scp | pipe
TARGET_DIR="/tmp"
VERIFY=true                      # 传输后校验

# ============================================================
# 颜色与输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
fatal() { error "$1"; exit 1; }

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    if [ $# -lt 2 ]; then
        show_help
        exit 1
    fi

    BACKUP_FILE="$1"
    TARGET_HOST="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|-p)
                SSH_PORT="$2"
                shift 2
                ;;
            --user|-u)
                TARGET_USER="$2"
                shift 2
                ;;
            --method|-m)
                METHOD="$2"
                shift 2
                ;;
            --target-dir)
                TARGET_DIR="$2"
                shift 2
                ;;
            --no-verify)
                VERIFY=false
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                fatal "未知参数: $1"
                ;;
        esac
    done
}

show_help() {
    cat << EOF
${BOLD}sumingdk transfer${NC} - 备份传输工具 v${VERSION}

${BOLD}用法:${NC}
  bash transfer.sh <备份文件> <目标IP> [选项]

${BOLD}参数:${NC}
  备份文件              backup.sh 生成的 .tar.gz 文件路径
  目标IP                新 VPS 的 IP 地址

${BOLD}选项:${NC}
  --port, -p PORT       SSH 端口（默认 22）
  --user, -u USER       SSH 用户名（默认 root）
  --method, -m METHOD   传输方式：rsync（默认）| scp | pipe
  --target-dir DIR      目标目录（默认 /tmp）
  --no-verify           跳过传输后校验
  -h, --help            显示此帮助

${BOLD}传输方式对比:${NC}
  rsync    断点续传，中断后再跑同命令可续传（推荐）
  scp      简单直接，适合小文件
  pipe     tar+ssh 管道，不在本地落盘，适合磁盘空间不足

${BOLD}示例:${NC}
  bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 192.168.1.100
  bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 192.168.1.100 --port 55520
  bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 10.0.0.1 --method scp --port 2222
EOF
}

# ============================================================
# 传输前检查
# ============================================================
pre_check() {
    info "传输前检查..."

    # 检查备份文件是否存在
    if [ ! -f "$BACKUP_FILE" ]; then
        fatal "备份文件不存在: ${BACKUP_FILE}"
    fi

    local size
    size=$(du -h "$BACKUP_FILE" | cut -f1)
    echo -e "  备份文件: ${BOLD}${BACKUP_FILE}${NC} (${size})"
    echo -e "  目标地址: ${BOLD}${TARGET_USER}@${TARGET_HOST}:${SSH_PORT}${NC}"
    echo -e "  传输方式: ${BOLD}${METHOD}${NC}"
    echo -e "  目标目录: ${BOLD}${TARGET_DIR}${NC}"

    # 检查连通性
    info "检查 SSH 连通性..."
    if ! ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes \
         "${TARGET_USER}@${TARGET_HOST}" "echo ok" &>/dev/null; then
        warn "SSH 免密登录不可用，传输时需要输入密码"
        # 测试能否连接（允许密码）
        echo -e "  测试连接中... 如需输入密码请输入："
        if ! ssh -p "$SSH_PORT" -o ConnectTimeout=10 \
             "${TARGET_USER}@${TARGET_HOST}" "echo '连接成功'" 2>/dev/null; then
            fatal "无法连接到 ${TARGET_HOST}:${SSH_PORT}"
        fi
    else
        ok "SSH 连接正常"
    fi
}

# ============================================================
# 计算文件 MD5
# ============================================================
get_md5() {
    local file="$1"
    if command -v md5sum &>/dev/null; then
        md5sum "$file" | awk '{print $1}'
    elif command -v md5 &>/dev/null; then
        md5 -q "$file"
    else
        echo "unknown"
    fi
}

# ============================================================
# 传输：rsync
# ============================================================
transfer_rsync() {
    info "使用 rsync 传输（支持断点续传）..."

    rsync -avz --progress \
        -e "ssh -p ${SSH_PORT}" \
        "$BACKUP_FILE" \
        "${TARGET_USER}@${TARGET_HOST}:${TARGET_DIR}/"
}

# ============================================================
# 传输：scp
# ============================================================
transfer_scp() {
    info "使用 scp 传输..."

    scp -P "$SSH_PORT" \
        "$BACKUP_FILE" \
        "${TARGET_USER}@${TARGET_HOST}:${TARGET_DIR}/"
}

# ============================================================
# 传输：tar + ssh 管道（不落盘直传）
# 注意：管道方式直接传目录，不是传 tar.gz 文件
# 如果传的是已打包的 tar.gz 文件，效果和 scp 类似
# ============================================================
transfer_pipe() {
    info "使用 tar + ssh 管道传输..."

    # 判断备份文件是 tar.gz 还是目录
    if [ -f "$BACKUP_FILE" ]; then
        # 直接传文件
        cat "$BACKUP_FILE" | ssh -p "$SSH_PORT" \
            "${TARGET_USER}@${TARGET_HOST}" \
            "cat > ${TARGET_DIR}/$(basename "$BACKUP_FILE")"
    elif [ -d "$BACKUP_FILE" ]; then
        # 目录：用管道直接打包传输
        tar czf - -C "$(dirname "$BACKUP_FILE")" "$(basename "$BACKUP_FILE")" | \
            ssh -p "$SSH_PORT" \
            "${TARGET_USER}@${TARGET_HOST}" \
            "cat > ${TARGET_DIR}/$(basename "$BACKUP_FILE").tar.gz"
    fi
}

# ============================================================
# 传输后校验
# ============================================================
verify_transfer() {
    info "校验传输完整性..."

    local local_md5 remote_md5
    local_md5=$(get_md5 "$BACKUP_FILE")

    remote_md5=$(ssh -p "$SSH_PORT" "${TARGET_USER}@${TARGET_HOST}" \
        "md5sum '${TARGET_DIR}/$(basename "$BACKUP_FILE")' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "failed")

    if [ "$local_md5" = "unknown" ] || [ "$remote_md5" = "failed" ]; then
        warn "无法校验 MD5，请手动确认文件完整性"
        return
    fi

    if [ "$local_md5" = "$remote_md5" ]; then
        ok "MD5 校验通过: ${local_md5}"
    else
        error "MD5 不匹配！本地: ${local_md5}, 远端: ${remote_md5}"
        error "文件可能损坏，建议重新传输"
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}  sumingdk 传输工具 v${VERSION}${NC}"
    echo ""

    # 1. 传输前检查
    pre_check

    # 2. 执行传输
    echo ""
    case "$METHOD" in
        rsync)  transfer_rsync ;;
        scp)    transfer_scp ;;
        pipe)   transfer_pipe ;;
        *)      fatal "不支持的传输方式: ${METHOD}，可选: rsync / scp / pipe" ;;
    esac

    # 3. 校验
    if [ "$VERIFY" = true ]; then
        echo ""
        verify_transfer
    fi

    # 4. 完成
    echo ""
    ok "传输完成！"
    echo ""
    echo -e "下一步：登录新服务器执行还原"
    echo -e "  ${CYAN}ssh -p ${SSH_PORT} ${TARGET_USER}@${TARGET_HOST}${NC}"
    echo -e "  ${CYAN}bash restore.sh ${TARGET_DIR}/$(basename "$BACKUP_FILE")${NC}"
    echo ""
}

main "$@"
