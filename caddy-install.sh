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

COMMON_LIB="/usr/local/lib/sumingdk/common.sh"
REPO_BASE="https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main"

# 加载公共模块
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
else
    # Fallback：公共模块不存在时的内联定义
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m' BLUE=$'\033[0;34m' NC=$'\033[0m' BOLD=$'\033[1m'
    info()  { echo -e "${CYAN}>>> $1${NC}"; }
    ok()    { echo -e "${GREEN}✅ $1${NC}"; }
    warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
    error() { echo -e "${RED}❌ $1${NC}"; }
    die()   { error "$1"; exit 1; }
    line()  { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
fi

# ============================================================
# 初始化：前置无交互自动执行
# ============================================================
init_env() {
    echo -e "${CYAN}>>> 正在初始化 Caddy Proxy 环境，请稍候...${NC}"

    [ "$(id -u)" -ne 0 ] && die "请使用 root 用户运行此脚本"

    # 下载公共模块（如不存在）
    if [ ! -f "$COMMON_LIB" ]; then
        mkdir -p "$(dirname "$COMMON_LIB")"
        curl -sL "${REPO_BASE}/common.sh" -o "$COMMON_LIB" 2>/dev/null || true
        [ -f "$COMMON_LIB" ] && source "$COMMON_LIB"
    fi

    # 同步自身为管理脚本（仅当管理脚本不存在时才下载）
    if [ ! -f "${MANAGE_CMD}" ]; then
        curl -sL "${REPO_BASE}/caddy-install.sh" -o "${MANAGE_CMD}" 2>/dev/null || true
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
        echo ""
        read -p "安装完成！是否扫描当前宿主机遗留的 Nginx 配置并尝试导入到 Caddy？(y/N): " do_import
        if [ "$do_import" = "y" ] || [ "$do_import" = "Y" ]; then
            cmd_import
        fi
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

        local port=$(grep -o '127\.0\.0\.1:[0-9]*' "$conf" 2>/dev/null | head -1 | sed 's/127\.0\.0\.1://')
        echo -e "  - ${CYAN}${name}${NC}  ->  127.0.0.1:${port:-?}"
        count=$((count + 1))
    done
    if [ $count -eq 0 ]; then
        echo -e "  ${YELLOW}暂无已配置的域名${NC}"
    fi
    echo ""
}

# 如果 common.sh 未提供 cmd_ports，定义一个 fallback
if ! declare -f cmd_ports &>/dev/null; then
    cmd_ports() { warn "端口查看功能需要公共模块，请重新运行脚本"; }
fi

# ============================================================
# 选项 7：卸载 Caddy
# ============================================================
cmd_uninstall_caddy() {
    echo ""
    warn "此操作将完整卸载 Caddy！"
    echo ""

    if ! command -v caddy &>/dev/null; then
        error "Caddy 未安装"
        return 1
    fi

    # 展示当前配置的域名
    local domain_count=0
    for conf in ${SITES_DIR}/*.caddy; do
        [ -f "$conf" ] || continue
        domain_count=$((domain_count + 1))
    done
    if [ $domain_count -gt 0 ]; then
        echo -e "  ${YELLOW}当前已配置 ${domain_count} 个域名，卸载后将全部失效${NC}"
    fi
    echo ""

    read -p "确认卸载 Caddy？（输入 YES 确认）: " confirm
    [ "$confirm" != "YES" ] && { info "已取消卸载"; return 0; }

    echo ""
    read -p "是否同时删除所有配置和证书？(y/N): " clean_data

    # 停止并禁用服务
    info "停止 Caddy 服务..."
    systemctl stop caddy 2>/dev/null || true
    systemctl disable caddy 2>/dev/null || true

    # 卸载 Caddy 软件包
    info "卸载 Caddy 软件包..."
    if command -v apt-get &>/dev/null; then
        apt-get purge -y caddy 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    elif command -v yum &>/dev/null; then
        yum remove -y caddy 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf remove -y caddy 2>/dev/null || true
    fi

    # 清理 apt 源
    rm -f /etc/apt/sources.list.d/caddy-stable.list 2>/dev/null || true
    rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null || true

    # 清理配置和证书（如用户确认）
    if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
        info "清理配置和证书..."
        rm -rf "${CADDY_DIR}"
        rm -rf /var/lib/caddy
        rm -rf /var/log/caddy
        ok "Caddy 配置和证书已清理"
    else
        warn "Caddy 配置已保留在 ${CADDY_DIR}"
    fi

    # 删除管理脚本
    rm -f "${MANAGE_CMD}" 2>/dev/null || true

    echo ""
    ok "Caddy 已卸载完成！"
}

# ============================================================
# 选项 8：扫描并导入遗留的 Nginx 代理配置
# ============================================================
cmd_import() {
    echo ""
    info "正在扫描宿主机系统中遗留的 Nginx 配置并尝试转为 Caddy..."
    echo -e "  扫描目录: ${CYAN}/etc/nginx/conf.d/${NC} 和 ${CYAN}/etc/nginx/sites-enabled/${NC}"

    if ! command -v caddy &>/dev/null; then
        error "Caddy 未安装，请先执行选项 1 安装环境"
        return 1
    fi

    local found_count=0
    local imported_count=0

    # 扫描 Nginx 常见目录
    for conf_dir in /etc/nginx/conf.d /etc/nginx/sites-enabled; do
        [ -d "$conf_dir" ] || continue
        
        for f in "$conf_dir"/*; do
            [ -f "$f" ] || continue
            
            # 跳过默认配置
            local fname=$(basename "$f")
            if [ "$fname" = "default" ] || [ "$fname" = "default.conf" ]; then
                continue
            fi

            # 尝试提取域名和本地转发端口
            local domain=""
            local port=""
            
            # 提取 server_name 的第一个参数作为主域名
            domain=$(grep -Eo 'server_name[[:space:]]+[^;[:space:]]+' "$f" | head -1 | awk '{print $2}')
            # 提取 proxy_pass 后的 127.0.0.1:端口 或 localhost:端口
            port=$(grep -Eo '(127\.0\.0\.1|localhost):[0-9]+' "$f" | head -1 | grep -Eo '[0-9]+$')

            # 如果既提取到了域名也提取到了端口
            if [ -n "$domain" ] && [ -n "$port" ]; then
                # 检查是否已经被 Caddy 纳管
                if [ -f "${SITES_DIR}/${domain}.caddy" ]; then
                    continue
                fi

                found_count=$((found_count + 1))
                echo ""
                warn "发现未纳管的遗留 Nginx 配置: ${CYAN}$f${NC}"
                echo -e "  提取到域名: ${GREEN}${domain}${NC}"
                echo -e "  提取到反代端口: ${GREEN}${port}${NC}"
                
                read -p "是否将其导入到 Caddy 系统？(自动配置 HTTPS) (y/N): " confirm_import
                if [ "$confirm_import" = "y" ] || [ "$confirm_import" = "Y" ]; then
                    if cmd_add "$domain" "$port"; then
                        imported_count=$((imported_count + 1))
                    fi
                else
                    info "已跳过 ${domain}"
                fi
            fi
        done
    done

    echo ""
    if [ "$found_count" -eq 0 ]; then
        ok "未发现任何可以导入的遗留 Nginx 配置！"
    else
        ok "扫描结束！共发现 ${found_count} 个遗留配置，成功导入到 Caddy ${imported_count} 个！"
    fi
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
    echo -e "  ${GREEN}7.${NC} 卸载 Caddy"
    echo -e "  ${GREEN}8.${NC} 扫描导入遗留 Nginx 配置"
    echo -e "  ${GREEN}0.${NC} 退出脚本"
    line
    echo ""
}

menu_loop() {
    while true; do
        show_menu
        read -p "请输入数字 [0-8]: " choice
        case $choice in
            1) cmd_install_caddy; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            2) cmd_add; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            3) cmd_del; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            4) cmd_status; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            5) echo ""; cmd_list_domains; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            6) cmd_ports; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            7) cmd_uninstall_caddy; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            8) cmd_import; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
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
    add)       cmd_add "$2" "$3" ;;
    del)       cmd_del "$2" ;;
    import)    cmd_import ;;
    list)      cmd_list_domains ;;
    status)    cmd_status ;;
    install)   cmd_install_caddy ;;
    ports)     cmd_ports ;;
    uninstall) cmd_uninstall_caddy ;;
    *)         menu_loop ;;
esac
