#!/bin/bash
# ============================================================
# Nginx & Caddy 统一入口脚本
# 作者：wsuming97
# ============================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'
BOLD=$'\033[1m'

line() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[ "$(id -u)" -ne 0 ] && { echo -e "${RED}❌ 请使用 root 用户运行此脚本${NC}"; exit 1; }

REPO="https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main"

clear
echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║      反向代理一键管理 - 选择方案              ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
line
echo -e "  ${GREEN}1.${NC} Nginx 方案  ${CYAN}(Docker + certbot + 静态缓存)${NC}"
echo -e "  ${GREEN}2.${NC} Caddy 方案  ${CYAN}(直装 + 自动HTTPS + 零配置)${NC}"
line
echo ""
echo -e "  ${BOLD}对比：${NC}"
echo -e "  Nginx → 功能强大，支持静态文件缓存，适合高流量站点"
echo -e "  Caddy → 极简省心，证书全自动，适合快速部署"
echo ""

read -p "请选择方案 [1/2]: " choice

case $choice in
    1)
        echo ""
        echo -e "${CYAN}>>> 正在启动 Nginx 方案...${NC}"
        # 下载并执行 Nginx 脚本
        curl -sL "${REPO}/install.sh" -o /usr/local/bin/nginx-proxy
        chmod +x /usr/local/bin/nginx-proxy
        bash /usr/local/bin/nginx-proxy
        ;;
    2)
        echo ""
        echo -e "${CYAN}>>> 正在启动 Caddy 方案...${NC}"
        # 下载并执行 Caddy 脚本
        curl -sL "${REPO}/caddy-install.sh" -o /usr/local/bin/caddy-proxy
        chmod +x /usr/local/bin/caddy-proxy
        bash /usr/local/bin/caddy-proxy
        ;;
    *)
        echo -e "${RED}请输入 1 或 2${NC}"
        exit 1
        ;;
esac
