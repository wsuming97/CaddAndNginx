#!/bin/bash
# ============================================================
# Nginx Docker 一键安装 + 交互式管理脚本
# 功能：安装 Docker + 部署 Nginx 反代 + 域名管理 + 自动证书续签
# 安装：bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/install.sh)
# 管理：nginx-proxy
# ============================================================

set -e

# ============================================================
# 全局变量和工具函数
# ============================================================
WEB_DIR="/home/web"
CONF_DIR="${WEB_DIR}/conf.d"
CERT_DIR="${WEB_DIR}/certs"
WEBROOT="${WEB_DIR}/letsencrypt"
MANAGE_CMD="/usr/local/bin/nginx-proxy"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
die()   { error "$1"; exit 1; }

# 分隔线
line() { echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ============================================================
# 交互式等待用户按回车
# ============================================================
pause_step() {
    echo ""
    read -p "$(echo -e ${CYAN}按回车继续下一步...${NC})" _pause
    echo ""
}

# ============================================================
# 安装函数（交互式引导）
# ============================================================
do_install() {
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║     Nginx Docker 一键反代安装程序            ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    [ "$(id -u)" -ne 0 ] && die "请使用 root 用户运行此脚本"

    echo -e "  本脚本将为你完成以下安装步骤："
    echo ""
    echo -e "  ${GREEN}Step 1.${NC} 检查系统环境"
    echo -e "  ${GREEN}Step 2.${NC} 安装 Docker"
    echo -e "  ${GREEN}Step 3.${NC} 创建目录结构"
    echo -e "  ${GREEN}Step 4.${NC} 生成 Nginx 配置文件"
    echo -e "  ${GREEN}Step 5.${NC} 安装管理脚本 (nginx-proxy)"
    echo -e "  ${GREEN}Step 6.${NC} 配置证书自动续签"
    echo -e "  ${GREEN}Step 7.${NC} 启动 Nginx 容器"
    echo ""
    line
    read -p "$(echo -e ${CYAN}是否开始安装？[Y/n]: ${NC})" start_confirm
    if [ "$start_confirm" = "n" ] || [ "$start_confirm" = "N" ]; then
        echo "已取消安装"
        exit 0
    fi
    echo ""

    # ---- Step 1 ----
    info "[Step 1/7] 检查系统环境..."
    for port in 80 443; do
        if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            warn "端口 ${port} 已被占用"
            read -p "$(echo -e ${YELLOW}是否继续？[Y/n]: ${NC})" port_confirm
            if [ "$port_confirm" = "n" ] || [ "$port_confirm" = "N" ]; then
                echo "已取消安装"
                exit 0
            fi
        fi
    done
    ok "环境检查通过"
    pause_step

    # ---- Step 2 ----
    info "[Step 2/7] 安装 Docker..."
    if command -v docker &> /dev/null; then
        ok "Docker 已安装：$(docker --version | head -1)"
    else
        echo -e "  即将安装 Docker..."
        read -p "$(echo -e ${CYAN}确认安装 Docker？[Y/n]: ${NC})" docker_confirm
        if [ "$docker_confirm" = "n" ] || [ "$docker_confirm" = "N" ]; then
            die "Docker 是必要依赖，无法跳过"
        fi
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        ok "Docker 安装完成"
    fi
    docker compose version &> /dev/null || die "docker compose 不可用"
    pause_step

    # ---- Step 3 ----
    info "[Step 3/7] 创建目录结构..."
    mkdir -p ${WEB_DIR}/{conf.d,stream.d,certs,html,letsencrypt,log/nginx}
    echo -e "  ${CYAN}${WEB_DIR}/${NC}"
    echo -e "  ├── conf.d/       站点配置"
    echo -e "  ├── certs/        SSL 证书"
    echo -e "  ├── html/         静态文件"
    echo -e "  ├── letsencrypt/  ACME 验证"
    echo -e "  ├── log/nginx/    日志"
    echo -e "  └── stream.d/     TCP/UDP 转发"
    ok "目录结构已创建"
    pause_step

    # ---- Step 4 ----
    info "[Step 4/7] 生成 Nginx 配置文件..."

    # 自签名证书
    if [ ! -f "${CERT_DIR}/default_server.crt" ]; then
        openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "${CERT_DIR}/default_server.key" \
            -out "${CERT_DIR}/default_server.crt" \
            -subj "/CN=default_server" 2>/dev/null
        ok "默认自签名证书已生成"
    else
        ok "默认自签名证书已存在，跳过"
    fi

    openssl rand -out "${CERT_DIR}/ticket12.key" 48 2>/dev/null
    openssl rand -out "${CERT_DIR}/ticket13.key" 80 2>/dev/null

    # nginx.conf
    if [ ! -f "${WEB_DIR}/nginx.conf" ]; then
cat > "${WEB_DIR}/nginx.conf" << 'NGINX_CONF'
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_session_ticket_key /etc/nginx/certs/ticket12.key;
    ssl_session_ticket_key /etc/nginx/certs/ticket13.key;

    include /etc/nginx/conf.d/*.conf;
}

stream {
    include /etc/nginx/stream.d/*.conf;
}
NGINX_CONF
        ok "nginx.conf 已生成"
    else
        ok "nginx.conf 已存在，跳过"
    fi

    # default.conf
    if [ ! -f "${CONF_DIR}/default.conf" ]; then
cat > "${CONF_DIR}/default.conf" << 'DEFAULT_CONF'
server {
    listen 80 reuseport default_server;
    listen [::]:80 reuseport default_server;
    listen 443 ssl reuseport default_server;
    listen [::]:443 ssl reuseport default_server;
    listen 443 quic reuseport default_server;
    listen [::]:443 quic reuseport default_server;

    server_name _;

    ssl_certificate /etc/nginx/certs/default_server.crt;
    ssl_certificate_key /etc/nginx/certs/default_server.key;

    return 444;
}

set_real_ip_from 172.0.0.0/8;
set_real_ip_from fd00::/8;
real_ip_header X-Forwarded-For;
real_ip_recursive on;

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      "";
}
DEFAULT_CONF
        ok "default.conf 已生成"
    else
        ok "default.conf 已存在，跳过"
    fi

    # docker-compose.yml
    if [ ! -f "${WEB_DIR}/docker-compose.yml" ]; then
cat > "${WEB_DIR}/docker-compose.yml" << 'COMPOSE'
services:
  nginx:
    image: nginx:alpine
    container_name: nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
      - ./conf.d:/etc/nginx/conf.d
      - ./stream.d:/etc/nginx/stream.d
      - ./certs:/etc/nginx/certs
      - ./html:/var/www/html
      - ./letsencrypt:/var/www/letsencrypt
      - ./log/nginx:/var/log/nginx
    tmpfs:
      - /var/cache/nginx:rw,noexec,nosuid,size=2048m
COMPOSE
        ok "docker-compose.yml 已生成"
    else
        ok "docker-compose.yml 已存在，跳过"
    fi

    ok "配置文件就绪"
    pause_step

    # ---- Step 5 ----
    info "[Step 5/7] 安装管理脚本..."
    install_manage_scripts
    ok "管理命令 nginx-proxy 已安装"
    pause_step

    # ---- Step 6 ----
    info "[Step 6/7] 配置证书自动续签..."
    install_cert_renewal
    if ! crontab -l 2>/dev/null | grep -q "auto_cert_renewal"; then
        (crontab -l 2>/dev/null; echo "0 0 * * * ~/auto_cert_renewal.sh >> /var/log/cert_renewal.log 2>&1") | crontab -
        ok "定时任务已添加（每天 0:00 自动检查续签）"
    else
        ok "定时任务已存在"
    fi
    pause_step

    # ---- Step 7 ----
    info "[Step 7/7] 启动 Nginx..."
    cd ${WEB_DIR} && docker compose up -d

    sleep 3
    if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
        ok "Nginx 已成功启动"
    else
        die "Nginx 启动失败，请检查日志：docker logs nginx"
    fi

    echo ""
    line
    echo -e "${GREEN}${BOLD}  🎉 安装完成！${NC}"
    line
    echo ""
    echo -e "  现在你可以："
    echo -e "  ${GREEN}1.${NC} 进入管理菜单添加域名"
    echo -e "  ${GREEN}2.${NC} 退出，稍后用 ${CYAN}nginx-proxy${NC} 命令管理"
    echo ""
    read -p "$(echo -e ${CYAN}是否立即进入管理菜单？[Y/n]: ${NC})" menu_confirm
    if [ "$menu_confirm" = "n" ] || [ "$menu_confirm" = "N" ]; then
        echo ""
        echo -e "  随时输入 ${CYAN}nginx-proxy${NC} 进入管理菜单"
        echo ""
        exit 0
    fi

    # 进入管理菜单
    exec ${MANAGE_CMD}
}

# ============================================================
# 安装证书续签脚本
# ============================================================
install_cert_renewal() {
cat > ~/auto_cert_renewal.sh << 'RENEW'
#!/bin/bash
certs_directory="/home/web/certs/"
days_before_expiry=15

for cert_file in $certs_directory*_cert.pem; do
    [ -f "$cert_file" ] || continue
    yuming=$(basename "$cert_file" "_cert.pem")
    [ "$yuming" = "default_server" ] && continue

    echo "检查证书： ${yuming}"
    expiration_date=$(openssl x509 -enddate -noout -in "${certs_directory}${yuming}_cert.pem" | cut -d "=" -f 2-)
    expiration_timestamp=$(date -d "${expiration_date}" +%s)
    current_timestamp=$(date +%s)
    days_until_expiry=$(( ($expiration_timestamp - $current_timestamp) / 86400 ))

    if [ $days_until_expiry -le $days_before_expiry ]; then
        echo "证书将在${days_before_expiry}天内过期，正在续签..."
        docker exec nginx [ -d /var/www/letsencrypt ] && DIR_OK=true || DIR_OK=false
        docker exec nginx grep -q "letsencrypt" /etc/nginx/conf.d/$yuming.conf 2>/dev/null && CONF_OK=true || CONF_OK=false

        if [ "$DIR_OK" = true ] && [ "$CONF_OK" = true ]; then
            docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n
            docker run --rm \
              -v "/etc/letsencrypt:/etc/letsencrypt" \
              -v "/home/web/letsencrypt:/var/www/letsencrypt" \
              certbot/certbot certonly \
              --webroot -w /var/www/letsencrypt \
              -d "$yuming" \
              --register-unsafely-without-email \
              --agree-tos --no-eff-email --key-type ecdsa --force-renewal
            cp /etc/letsencrypt/live/$yuming/fullchain.pem /home/web/certs/${yuming}_cert.pem 2>/dev/null
            cp /etc/letsencrypt/live/$yuming/privkey.pem /home/web/certs/${yuming}_key.pem 2>/dev/null
            openssl rand -out /home/web/certs/ticket12.key 48
            openssl rand -out /home/web/certs/ticket13.key 80
            docker exec nginx nginx -t && docker exec nginx nginx -s reload
        else
            docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n
            docker stop nginx > /dev/null 2>&1
            docker run --rm -p 80:80 -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot certonly \
              --standalone -d $yuming \
              --register-unsafely-without-email \
              --agree-tos --no-eff-email --force-renewal --key-type ecdsa
            cp /etc/letsencrypt/live/$yuming/fullchain.pem /home/web/certs/${yuming}_cert.pem 2>/dev/null
            cp /etc/letsencrypt/live/$yuming/privkey.pem /home/web/certs/${yuming}_key.pem 2>/dev/null
            openssl rand -out /home/web/certs/ticket12.key 48
            openssl rand -out /home/web/certs/ticket13.key 80
            docker start nginx > /dev/null 2>&1
        fi
        echo "✅ ${yuming} 证书已续签"
    else
        echo "✅ ${yuming} 证书有效，还剩 ${days_until_expiry} 天"
    fi
    echo "--------------------------"
done
RENEW
chmod +x ~/auto_cert_renewal.sh
}

# ============================================================
# 安装管理脚本（nginx-proxy 命令）
# ============================================================
install_manage_scripts() {
    # 将自身复制为管理命令
    local script_url="https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/install.sh"

    cat > ${MANAGE_CMD} << MANAGE_EOF
#!/bin/bash
# Nginx Proxy 管理命令 - 由 install.sh 生成
# 用法: nginx-proxy [add|del|list|status|renew|update|uninstall]

WEB_DIR="/home/web"
CONF_DIR="\${WEB_DIR}/conf.d"
CERT_DIR="\${WEB_DIR}/certs"
WEBROOT="\${WEB_DIR}/letsencrypt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "\${CYAN}>>> \$1\${NC}"; }
ok()    { echo -e "\${GREEN}✅ \$1\${NC}"; }
warn()  { echo -e "\${YELLOW}⚠️  \$1\${NC}"; }
error() { echo -e "\${RED}❌ \$1\${NC}"; }
line()  { echo -e "\${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\${NC}"; }

# ---- 添加域名 ----
cmd_add() {
    local domain=\$1
    local port=\$2

    if [ -z "\$domain" ]; then
        read -p "请输入域名: " domain
        [ -z "\$domain" ] && { error "域名不能为空"; return 1; }
    fi
    if [ -z "\$port" ]; then
        read -p "请输入后端端口: " port
        [ -z "\$port" ] && { error "端口不能为空"; return 1; }
    fi

    local upstream_name="backend_\$(echo \$domain | tr '.-' '_')"

    if [ -f "\${CONF_DIR}/\${domain}.conf" ]; then
        warn "域名 \${domain} 已配置，将覆盖"
    fi

    docker ps --format '{{.Names}}' | grep -q '^nginx\$' || { error "nginx 容器未运行"; return 1; }

    info "[1/4] 创建临时 HTTP 配置..."
    cat > "\${CONF_DIR}/\${domain}.conf" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name \${domain};

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }
    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}
EOF
    docker exec nginx nginx -s reload
    sleep 2

    info "[2/4] 签发 Let's Encrypt 证书..."
    docker run --rm \\
        -v "/etc/letsencrypt:/etc/letsencrypt" \\
        -v "\${WEBROOT}:/var/www/letsencrypt" \\
        certbot/certbot certonly \\
        --webroot -w /var/www/letsencrypt \\
        -d "\${domain}" \\
        --non-interactive \\
        --agree-tos \\
        --register-unsafely-without-email \\
        --key-type ecdsa \\
        --cert-name "\${domain}"

    if [ \$? -ne 0 ]; then
        error "证书签发失败，请检查域名 DNS 是否已指向本机 IP"
        rm -f "\${CONF_DIR}/\${domain}.conf"
        docker exec nginx nginx -s reload
        return 1
    fi

    cp /etc/letsencrypt/live/\${domain}/fullchain.pem "\${CERT_DIR}/\${domain}_cert.pem"
    cp /etc/letsencrypt/live/\${domain}/privkey.pem "\${CERT_DIR}/\${domain}_key.pem"
    ok "证书签发成功"

    info "[3/4] 生成 HTTPS 反代配置..."
    cat > "\${CONF_DIR}/\${domain}.conf" << EOF
upstream \${upstream_name} {
    server 127.0.0.1:\${port};
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name \${domain};

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }
    location / {
        return 301 https://\\\$host\\\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 443 quic;
    listen [::]:443 quic;

    server_name \${domain};

    ssl_certificate /etc/nginx/certs/\${domain}_cert.pem;
    ssl_certificate_key /etc/nginx/certs/\${domain}_key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    add_header Alt-Svc 'h3=":443"; ma=86400';

    location / {
        proxy_pass http://\${upstream_name};
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection \\\$connection_upgrade;
    }

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }

    client_max_body_size 100m;
}
EOF

    info "[4/4] 重载 Nginx..."
    docker exec nginx nginx -t && docker exec nginx nginx -s reload

    echo ""
    ok "配置完成！"
    echo -e "   域名: ${CYAN}https://\${domain}${NC}"
    echo -e "   反代: ${CYAN}127.0.0.1:\${port}${NC}"
    echo -e "   配置: ${CYAN}\${CONF_DIR}/\${domain}.conf${NC}"
}

# ---- 删除域名 ----
cmd_del() {
    local domain=\$1

    if [ -z "\$domain" ]; then
        echo ""
        cmd_list
        echo ""
        read -p "请输入要删除的域名: " domain
        [ -z "\$domain" ] && { error "域名不能为空"; return 1; }
    fi

    if [ ! -f "\${CONF_DIR}/\${domain}.conf" ]; then
        error "域名 \${domain} 的配置不存在"
        return 1
    fi

    read -p "确认删除 \${domain}？(y/N): " confirm
    [ "\$confirm" != "y" ] && [ "\$confirm" != "Y" ] && return 0

    info "删除配置和证书..."
    rm -f "\${CONF_DIR}/\${domain}.conf"
    rm -f "\${CERT_DIR}/\${domain}_cert.pem"
    rm -f "\${CERT_DIR}/\${domain}_key.pem"
    docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "\$domain" -n 2>/dev/null || true
    docker exec nginx nginx -s reload
    ok "域名 \${domain} 已删除"
}

# ---- 查看已配置域名 ----
cmd_list() {
    echo ""
    echo -e "\${BOLD}  已配置的域名列表：\${NC}"
    line

    local count=0
    for conf in \${CONF_DIR}/*.conf; do
        [ -f "\$conf" ] || continue
        local name=\$(basename "\$conf" .conf)
        [ "\$name" = "default" ] && continue

        local port=\$(grep -oP 'server 127\.0\.0\.1:\K[0-9]+' "\$conf" 2>/dev/null | head -1)
        local cert_file="\${CERT_DIR}/\${name}_cert.pem"

        if [ -f "\$cert_file" ]; then
            local expiry=\$(openssl x509 -enddate -noout -in "\$cert_file" 2>/dev/null | cut -d= -f2)
            local expiry_ts=\$(date -d "\$expiry" +%s 2>/dev/null)
            local now_ts=\$(date +%s)
            local days_left=\$(( (expiry_ts - now_ts) / 86400 ))

            if [ \$days_left -le 7 ]; then
                local cert_status="\${RED}⚠ \${days_left}天后过期\${NC}"
            else
                local cert_status="\${GREEN}✓ \${days_left}天\${NC}"
            fi
        else
            local cert_status="\${YELLOW}无证书\${NC}"
        fi

        printf "  %-30s → %-15s 证书: %b\\n" "\${name}" "127.0.0.1:\${port:-?}" "\${cert_status}"
        count=\$((count + 1))
    done

    if [ \$count -eq 0 ]; then
        echo -e "  \${YELLOW}暂无已配置的域名\${NC}"
    fi
    line
}

# ---- 查看状态 ----
cmd_status() {
    echo ""
    echo -e "\${BOLD}  Nginx 服务状态：\${NC}"
    line

    if docker ps --format '{{.Names}} {{.Status}}' | grep -q '^nginx'; then
        local status=\$(docker ps --format '{{.Status}}' --filter name=^nginx\$)
        echo -e "  容器状态:  \${GREEN}运行中\${NC} (\${status})"
    else
        echo -e "  容器状态:  \${RED}未运行\${NC}"
    fi

    local site_count=\$(ls \${CONF_DIR}/*.conf 2>/dev/null | grep -v default.conf | wc -l)
    echo -e "  站点数量:  \${CYAN}\${site_count}\${NC}"

    local cert_count=\$(ls \${CERT_DIR}/*_cert.pem 2>/dev/null | grep -v default_server | wc -l)
    echo -e "  证书数量:  \${CYAN}\${cert_count}\${NC}"

    echo -e "  配置目录:  \${CYAN}\${WEB_DIR}\${NC}"
    echo -e "  日志目录:  \${CYAN}\${WEB_DIR}/log/nginx/\${NC}"
    line
}

# ---- 手动续签 ----
cmd_renew() {
    info "执行证书续签检查..."
    if [ -f ~/auto_cert_renewal.sh ]; then
        bash ~/auto_cert_renewal.sh
    else
        error "续签脚本不存在，请重新安装"
    fi
}

# ---- 重启 Nginx ----
cmd_restart() {
    info "重启 Nginx..."
    cd \${WEB_DIR} && docker compose restart nginx
    sleep 2
    if docker ps --format '{{.Names}}' | grep -q '^nginx\$'; then
        ok "Nginx 已重启"
    else
        error "Nginx 重启失败"
    fi
}

# ---- 更新脚本 ----
cmd_update() {
    info "更新管理脚本..."
    bash <(curl -sL ${script_url}) install
    ok "更新完成"
}

# ---- 卸载 ----
cmd_uninstall() {
    echo ""
    warn "此操作将删除 Nginx 和所有配置！"
    read -p "确认卸载？(输入 YES 确认): " confirm
    [ "\$confirm" != "YES" ] && { echo "已取消"; return 0; }

    info "停止并删除容器..."
    cd \${WEB_DIR} && docker compose down 2>/dev/null

    info "删除管理命令..."
    rm -f /usr/local/bin/nginx-proxy
    rm -f ~/auto_cert_renewal.sh

    # 保留数据目录，让用户自行删除
    echo ""
    ok "Nginx 已卸载"
    warn "数据目录 \${WEB_DIR} 已保留，如需彻底删除请手动执行: rm -rf \${WEB_DIR}"
}

# ---- 交互式菜单 ----
show_menu() {
    clear
    echo ""
    echo -e "\${GREEN}\${BOLD}╔══════════════════════════════════════════════╗\${NC}"
    echo -e "\${GREEN}\${BOLD}║        Nginx Proxy 管理面板                  ║\${NC}"
    echo -e "\${GREEN}\${BOLD}╚══════════════════════════════════════════════╝\${NC}"
    echo ""
    cmd_status
    echo ""
    echo -e "  \${BOLD}操作菜单：\${NC}"
    line
    echo -e "  \${GREEN}1.\${NC} 添加域名反代"
    echo -e "  \${GREEN}2.\${NC} 删除域名"
    echo -e "  \${GREEN}3.\${NC} 查看域名列表"
    echo -e "  \${GREEN}4.\${NC} 手动续签证书"
    echo -e "  \${GREEN}5.\${NC} 重启 Nginx"
    echo -e "  \${GREEN}6.\${NC} 查看 Nginx 日志"
    echo -e "  \${GREEN}7.\${NC} 更新脚本"
    echo -e "  \${RED}8.\${NC} 卸载 Nginx"
    echo -e "  \${GREEN}0.\${NC} 退出"
    line
    echo ""
}

menu_loop() {
    while true; do
        show_menu
        read -p "请选择操作 [0-8]: " choice
        echo ""
        case \$choice in
            1) cmd_add ;;
            2) cmd_del ;;
            3) cmd_list; read -p "按回车继续..." ;;
            4) cmd_renew; read -p "按回车继续..." ;;
            5) cmd_restart; read -p "按回车继续..." ;;
            6) docker logs nginx --tail=30; read -p "按回车继续..." ;;
            7) cmd_update; exit 0 ;;
            8) cmd_uninstall; exit 0 ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ---- 命令行入口 ----
case "\$1" in
    add)    cmd_add "\$2" "\$3" ;;
    del)    cmd_del "\$2" ;;
    list)   cmd_list ;;
    status) cmd_status ;;
    renew)  cmd_renew ;;
    restart) cmd_restart ;;
    update) cmd_update ;;
    uninstall) cmd_uninstall ;;
    menu|"") menu_loop ;;
    *)
        echo "用法: nginx-proxy [命令]"
        echo ""
        echo "命令:"
        echo "  add <域名> <端口>   添加域名反代"
        echo "  del <域名>          删除域名"
        echo "  list                查看域名列表"
        echo "  status              查看服务状态"
        echo "  renew               手动续签证书"
        echo "  restart             重启 Nginx"
        echo "  update              更新脚本"
        echo "  uninstall           卸载"
        echo ""
        echo "不带参数则进入交互式菜单"
        ;;
esac
MANAGE_EOF

    chmod +x ${MANAGE_CMD}
}

# ============================================================
# 主入口
# ============================================================
case "$1" in
    install|"")
        do_install
        ;;
    *)
        echo "用法: bash install.sh"
        ;;
esac
