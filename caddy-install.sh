#!/bin/bash
# ============================================================
# Caddy 一键安装 + 交互式管理脚本
# 自动 HTTPS，无需 certbot
# 作者：wsuming97
# ============================================================

# 注意：不在顶层使用 set -e，避免函数内预期失败的命令中断脚本
# 各函数内部自行处理错误

# ============================================================
# 全局变量和颜色
# ============================================================
CADDY_DIR="/etc/caddy"
SITES_DIR="${CADDY_DIR}/sites"
MANAGE_CMD="/usr/local/bin/caddy-proxy"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
BOLD=$'\033[1m'

info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
die()   { error "$1"; exit 1; }
line()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ============================================================
# 初始化：前置无交互自动执行
# ============================================================
init_env() {
    echo -e "${CYAN}>>> 正在初始化 Caddy Proxy 环境，请稍候...${NC}"

    [ "$(id -u)" -ne 0 ] && die "请使用 root 用户运行此脚本"

    # 同步自身为管理脚本（仅当管理脚本不存在时才下载）
    if [ ! -f "${MANAGE_CMD}" ]; then
        curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/caddy-install.sh -o "${MANAGE_CMD}" 2>/dev/null || true
        chmod +x "${MANAGE_CMD}" 2>/dev/null || true
    fi
}

# ============================================================
# 选项 1：安装 Caddy
# ============================================================
cmd_install_caddy() {
    echo ""
    info "开始安装 Caddy..."

    # 检查端口占用
    for port in 80 443; do
        if ss -tlnp | grep -q ":${port} "; then
            warn "端口 ${port} 已被占用："
            ss -tlnp | grep ":${port} "
            read -p "是否继续？(y/N): " confirm
            [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 1
        fi
    done

    # 安装 Caddy（通过官方 apt 源）
    if ! command -v caddy &> /dev/null; then
        info "正在通过官方源安装 Caddy..."
        apt-get update -qq
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl > /dev/null 2>&1
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
        apt-get update -qq
        apt-get install -y -qq caddy > /dev/null 2>&1
        ok "Caddy 安装完成：$(caddy version)"
    else
        ok "Caddy 已安装：$(caddy version)"
    fi

    # 创建站点目录
    mkdir -p "${SITES_DIR}"

    # 生成主 Caddyfile
    info "生成 Caddyfile..."
    cat > "${CADDY_DIR}/Caddyfile" << 'CADDYFILE'
# Caddy 全局配置
{
    # 自动 HTTPS（默认开启）
    # email your@email.com  # 可选：填写邮箱用于 Let's Encrypt 通知
    log {
        output file /var/log/caddy/access.log
        format json
    }
}

# 导入所有站点配置
import /etc/caddy/sites/*.caddy
CADDYFILE

    # 创建日志目录并设置权限（Caddy 以 caddy 用户运行）
    mkdir -p /var/log/caddy
    chown -R caddy:caddy /var/log/caddy

    # 启动 Caddy
    systemctl enable caddy > /dev/null 2>&1
    systemctl restart caddy

    sleep 2
    if systemctl is-active --quiet caddy; then
        ok "Caddy 安装且启动成功！"
    else
        error "Caddy 启动失败，请检查日志：journalctl -u caddy --no-pager -n 20"
    fi
}

# ============================================================
# 选项 2：添加域名反代
# ============================================================
cmd_add() {
    local domain=$1
    local port=$2

    echo ""
    info "正在配置域名反代..."

    if [ -z "$domain" ]; then
        read -p "请输入域名 (例如 my.example.com): " domain
        [ -z "$domain" ] && { error "域名不能为空"; return 1; }
    fi
    if [ -z "$port" ]; then
        read -p "请输入后端端口 (例如 8080): " port
        [ -z "$port" ] && { error "端口不能为空"; return 1; }
    fi

    if [ -f "${SITES_DIR}/${domain}.caddy" ]; then
        warn "域名 ${domain} 已配置，将被覆盖"
    fi

    if ! systemctl is-active --quiet caddy; then
        error "Caddy 未运行，请先执行选项 1 安装环境"
        return 1
    fi

    mkdir -p "${SITES_DIR}"

    info "生成反代配置..."
    cat > "${SITES_DIR}/${domain}.caddy" << EOF
${domain} {
    # 反向代理到后端服务
    reverse_proxy 127.0.0.1:${port} {
        # WebSocket 支持（自动）
        # 健康检查
        health_uri /
        health_interval 30s
        health_timeout 5s
    }

    # 请求头设置
    header {
        X-Real-IP {remote_host}
        X-Forwarded-Proto {scheme}
        -Server
    }

    # 请求体大小限制
    request_body {
        max_size 100MB
    }

    # 日志
    log {
        output file /var/log/caddy/${domain}.log
        format json
    }
}
EOF

    # 确保日志目录权限正确
    chown -R caddy:caddy /var/log/caddy

    info "重载 Caddy..."
    if caddy validate --config "${CADDY_DIR}/Caddyfile" > /dev/null 2>&1; then
        systemctl reload caddy
        sleep 3

        # 检查证书是否签发成功
        if curl -sI "https://${domain}" --max-time 10 -o /dev/null 2>&1; then
            echo ""
            ok "配置完成！"
            echo -e "   域名: ${CYAN}https://${domain}${NC}"
            echo -e "   反代: ${CYAN}127.0.0.1:${port}${NC}"
            echo -e "   证书: ${CYAN}自动签发 ✅${NC}"
        else
            echo ""
            ok "配置已生效！"
            echo -e "   域名: ${CYAN}https://${domain}${NC}"
            echo -e "   反代: ${CYAN}127.0.0.1:${port}${NC}"
            echo -e "   证书: ${YELLOW}正在自动签发中，请稍后访问${NC}"
        fi
    else
        error "配置验证失败！"
        caddy validate --config "${CADDY_DIR}/Caddyfile" 2>&1
        rm -f "${SITES_DIR}/${domain}.caddy"
        return 1
    fi
}

# ============================================================
# 选项 3：删除域名
# ============================================================
cmd_del() {
    local domain=$1

    echo ""
    info "删除域名配置..."

    if [ -z "$domain" ]; then
        cmd_list_domains
        read -p "请输入要删除的域名: " domain
        [ -z "$domain" ] && { error "域名不能为空"; return 1; }
    fi

    if [ ! -f "${SITES_DIR}/${domain}.caddy" ]; then
        error "域名 ${domain} 的配置不存在"
        return 1
    fi

    read -p "确认删除 ${domain} 的配置？(y/N): " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 0

    rm -f "${SITES_DIR}/${domain}.caddy"
    rm -f "/var/log/caddy/${domain}.log"
    systemctl reload caddy

    ok "域名 ${domain} 已删除"
}

# ============================================================
# 选项 4：查看 Caddy 状态
# ============================================================
cmd_status() {
    echo ""
    info "Caddy 服务状态："
    systemctl status caddy --no-pager -l | head -15
    echo ""
    info "已签发的证书："
    if [ -d "/var/lib/caddy/.local/share/caddy/certificates" ]; then
        find /var/lib/caddy/.local/share/caddy/certificates -name "*.crt" 2>/dev/null | while read cert; do
            domain=$(basename "$(dirname "$cert")")
            expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
            echo -e "  - ${CYAN}${domain}${NC}  到期: ${expiry}"
        done
    else
        echo -e "  ${YELLOW}暂无证书${NC}"
    fi
}

# ============================================================
# 查看已配域名辅助函数
# ============================================================
cmd_list_domains() {
    echo -e "${BOLD}当前已配置的域名：${NC}"
    local count=0
    for conf in ${SITES_DIR}/*.caddy; do
        [ -f "$conf" ] || continue
        local name=$(basename "$conf" .caddy)

        local port=$(grep -oP '127\.0\.0\.1:\K[0-9]+' "$conf" 2>/dev/null | head -1)
        echo -e "  - ${CYAN}${name}${NC}  ->  127.0.0.1:${port:-?}"
        count=$((count + 1))
    done
    if [ $count -eq 0 ]; then
        echo -e "  ${YELLOW}暂无已配置的域名${NC}"
    fi
    echo ""
}

# ============================================================
# 选项 6：查看服务端口占用
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
    local running_count=$(docker ps -q 2>/dev/null | wc -l)
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
            local short_ports=$(echo "$ports" | sed 's/, \[::\]:[0-9]*->[0-9]*\/tcp//g; s/, \[::\]:[0-9]*->[0-9]*\/udp//g')
            printf "  %-22s %-50s\n" "$name" "$short_ports"
        fi
    done

    echo ""
    echo -e "  ${GREEN}提示${NC}: 地址为 ${CYAN}0.0.0.0:端口${NC} 表示对外开放；仅显示内部端口（如 5432/tcp）表示仅容器间通信"
    echo ""
}

# ============================================================
# 交互式主菜单
# ============================================================
show_menu() {
    clear
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║        Caddy 反向代理管理菜单                ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    if command -v caddy &> /dev/null && systemctl is-active --quiet caddy; then
        echo -e "  Caddy 状态: ${GREEN}运行中${NC} ($(caddy version 2>/dev/null))"
    elif command -v caddy &> /dev/null; then
        echo -e "  Caddy 状态: ${RED}已安装但未运行${NC}"
    else
        echo -e "  Caddy 状态: ${RED}未安装 (请先执行 1 安装)${NC}"
    fi
    echo ""
    line
    echo -e "  ${GREEN}1.${NC} 安装 Caddy 环境"
    echo -e "  ${GREEN}2.${NC} 添加域名反代（自动 HTTPS）"
    echo -e "  ${GREEN}3.${NC} 删除域名反代"
    echo -e "  ${GREEN}4.${NC} 查看 Caddy 状态与证书"
    echo -e "  ${GREEN}5.${NC} 查看已配置的域名列表"
    echo -e "  ${GREEN}6.${NC} 查看服务端口占用"
    echo -e "  ${GREEN}0.${NC} 退出脚本"
    line
    echo ""
}

menu_loop() {
    while true; do
        show_menu
        read -p "请输入数字 [0-6]: " choice
        case $choice in
            1) cmd_install_caddy; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            2) cmd_add; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            3) cmd_del; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            4) cmd_status; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            5) echo ""; cmd_list_domains; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            6) cmd_ports; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            0) echo "已退出！随时输入 caddy-proxy 重新进入菜单。"; exit 0 ;;
            *) warn "请输入正确的数字"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 脚本入口点
# ============================================================
# 执行前置环境检查
init_env

# 命令行直传参数快捷访问（兼容系统命令模式）
case "$1" in
    add)     cmd_add "$2" "$3" ;;
    del)     cmd_del "$2" ;;
    list)    cmd_list_domains ;;
    status)  cmd_status ;;
    install) cmd_install_caddy ;;
    ports)   cmd_ports ;;
    *)       menu_loop ;;
esac
