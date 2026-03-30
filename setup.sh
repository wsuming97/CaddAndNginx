#!/bin/bash
# ============================================================
# Nginx & Caddy & Docker 统一入口脚本
# 作者：wsuming97
# ============================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
BOLD=$'\033[1m'

line() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}❌ 请使用 root 用户运行此脚本${NC}"; exit 1; }

REPO="https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main"

# ============================================================
# 主菜单（含系统信息面板）
# ============================================================
show_main_menu() {
    clear
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║        服务器一键管理 - 选择方案              ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    # ── 系统信息面板 ──
    local sys_time
    sys_time=$(date '+%Y-%m-%d %H:%M:%S')
    local sys_uptime
    sys_uptime=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime | awk -F'up ' '{print $2}' | cut -d',' -f1-2)
    local mem_used mem_total
    mem_used=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}')
    mem_total=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
    local disk_used disk_total disk_pct
    disk_used=$(df -h / 2>/dev/null | awk 'NR==2{print $3}')
    disk_total=$(df -h / 2>/dev/null | awk 'NR==2{print $2}')
    disk_pct=$(df -h / 2>/dev/null | awk 'NR==2{print $5}')
    # 公网 IP：强制 IPv4，多源降级，超时 3s，全部失败显示"获取失败"
    local sys_ip
    sys_ip=$(curl -s -4 --connect-timeout 3 ip.sb 2>/dev/null)
    [ -z "$sys_ip" ] && sys_ip=$(curl -s -4 --connect-timeout 3 icanhazip.com 2>/dev/null)
    [ -z "$sys_ip" ] && sys_ip=$(curl -s -4 --connect-timeout 3 api.ipify.org 2>/dev/null)
    [ -z "$sys_ip" ] && sys_ip="获取失败"
    local sys_os
    sys_os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || uname -sr)

    echo -e "  🕐 ${BOLD}当前时间${NC}:  ${CYAN}${sys_time}${NC}"
    echo -e "  ⏱️  ${BOLD}运行时间${NC}:  ${CYAN}${sys_uptime}${NC}"
    echo -e "  💾 ${BOLD}内存使用${NC}:  ${CYAN}${mem_used:-N/A} / ${mem_total:-N/A}${NC}"
    echo -e "  💿 ${BOLD}磁盘使用${NC}:  ${CYAN}${disk_used:-N/A} / ${disk_total:-N/A} (${disk_pct:-N/A})${NC}"
    echo -e "  🌐 ${BOLD}公网 IP${NC}:  ${CYAN}${sys_ip:-N/A}${NC}"
    echo -e "  🖥️  ${BOLD}系统版本${NC}:  ${CYAN}${sys_os:-N/A}${NC}"
    echo ""

    line
    echo -e "  ${GREEN}1.${NC} Nginx 方案    ${CYAN}(Docker + certbot + 静态缓存)${NC}"
    echo -e "  ${GREEN}2.${NC} Caddy 方案    ${CYAN}(直装 + 自动HTTPS + 零配置)${NC}"
    echo -e "  ${GREEN}3.${NC} Docker 管理   ${CYAN}(安装/管理/卸载 Docker & Compose)${NC}"
    echo -e "  ${GREEN}4.${NC} Docker 迁移   ${CYAN}(备份/传输/还原 Docker 服务)${NC}"
    echo -e "  ${GREEN}0.${NC} 退出"
    line
    echo ""
    echo -e "  ${BOLD}对比：${NC}"
    echo -e "  Nginx  → 功能强大，支持静态文件缓存，适合高流量站点"
    echo -e "  Caddy  → 极简省心，证书全自动，适合快速部署"
    echo -e "  Docker → Docker & Compose 一站式管理"
    echo -e "  迁移   → 一键备份旧 VPS 的 Docker 服务迁移到新 VPS"
    echo ""
}

# ============================================================
# 主循环：选完方案执行后自动返回主菜单
# ============================================================
while true; do
    show_main_menu
    read -p "请选择方案 [0-4]: " choice

    case $choice in
        1)
            echo ""
            echo -e "${CYAN}>>> 正在启动 Nginx 方案...${NC}"
            curl -sL "${REPO}/install.sh" -o /usr/local/bin/nginx-proxy
            chmod +x /usr/local/bin/nginx-proxy
            bash /usr/local/bin/nginx-proxy
            echo ""
            read -p "$(echo -e ${CYAN}按回车返回主菜单...${NC})"
            ;;
        2)
            echo ""
            echo -e "${CYAN}>>> 正在启动 Caddy 方案...${NC}"
            curl -sL "${REPO}/caddy-install.sh" -o /usr/local/bin/caddy-proxy
            chmod +x /usr/local/bin/caddy-proxy
            bash /usr/local/bin/caddy-proxy
            echo ""
            read -p "$(echo -e ${CYAN}按回车返回主菜单...${NC})"
            ;;
        3)
            echo ""
            echo -e "${CYAN}>>> 正在启动 Docker 管理...${NC}"
            curl -sL "${REPO}/docker-install.sh" -o /usr/local/bin/docker-manager
            chmod +x /usr/local/bin/docker-manager
            bash /usr/local/bin/docker-manager
            echo ""
            read -p "$(echo -e ${CYAN}按回车返回主菜单...${NC})"
            ;;
        4)
            echo ""
            echo -e "${CYAN}>>> 正在启动 Docker 迁移工具...${NC}"
            curl -sL "${REPO}/docker-install.sh" -o /usr/local/bin/docker-manager
            chmod +x /usr/local/bin/docker-manager
            bash /usr/local/bin/docker-manager migrate
            echo ""
            read -p "$(echo -e ${CYAN}按回车返回主菜单...${NC})"
            ;;
        0)
            echo -e "${GREEN}已退出！${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入 0-4${NC}"
            sleep 1
            ;;
    esac
done
