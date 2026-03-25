#!/bin/bash
# ============================================================
# Nginx Docker 一键安装脚本
# 功能：安装 Docker + 部署 Nginx 反代 + 配置自动证书续签
# 用法：bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/install.sh)
# ============================================================

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ============================================================
# 检查环境
# ============================================================
[ "$(id -u)" -ne 0 ] && error "请使用 root 用户运行此脚本"

info "[1/6] 检查系统环境..."

# 检查端口占用
for port in 80 443; do
    if ss -tlnp | grep -q ":${port} "; then
        warn "端口 ${port} 已被占用："
        ss -tlnp | grep ":${port} "
        read -p "是否继续？(y/N): " confirm
        [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && exit 1
    fi
done

# ============================================================
# 安装 Docker
# ============================================================
info "[2/6] 安装 Docker..."

if command -v docker &> /dev/null; then
    ok "Docker 已安装：$(docker --version)"
else
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker 安装完成"
fi

# 确认 docker compose 可用
if ! docker compose version &> /dev/null; then
    error "docker compose 不可用，请检查 Docker 安装"
fi

# ============================================================
# 创建目录结构
# ============================================================
info "[3/6] 创建目录结构..."

WEB_DIR="/home/web"
mkdir -p ${WEB_DIR}/{conf.d,stream.d,certs,html,letsencrypt,log/nginx}

# ============================================================
# 生成默认自签名证书（用于拦截未知域名）
# ============================================================
info "[4/6] 生成默认证书和配置文件..."

# 生成自签名证书
if [ ! -f "${WEB_DIR}/certs/default_server.crt" ]; then
    openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${WEB_DIR}/certs/default_server.key" \
        -out "${WEB_DIR}/certs/default_server.crt" \
        -subj "/CN=default_server" 2>/dev/null
    ok "默认自签名证书已生成"
fi

# 生成 TLS Session Ticket Keys
openssl rand -out "${WEB_DIR}/certs/ticket12.key" 48 2>/dev/null
openssl rand -out "${WEB_DIR}/certs/ticket13.key" 80 2>/dev/null

# --- nginx.conf ---
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

    # gzip 压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # SSL 全局配置
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

# --- 默认站点配置 ---
cat > "${WEB_DIR}/conf.d/default.conf" << 'DEFAULT_CONF'
# 默认站点 - 拦截未绑定域名的请求
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

# 信任 Docker 网络
set_real_ip_from 172.0.0.0/8;
set_real_ip_from fd00::/8;
real_ip_header X-Forwarded-For;
real_ip_recursive on;

# WebSocket 支持
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      "";
}
DEFAULT_CONF

# --- docker-compose.yml ---
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

ok "配置文件已生成"

# ============================================================
# 安装管理脚本
# ============================================================
info "[5/6] 安装管理脚本..."

# --- add-site 脚本 ---
cat > /usr/local/bin/add-site << 'ADD_SITE'
#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

if [ $# -lt 2 ]; then
    echo "用法: add-site <域名> <后端端口>"
    echo "示例: add-site example.com 8080"
    echo "      add-site sub.example.com 8317"
    exit 1
fi

DOMAIN=$1
PORT=$2
CONF_DIR="/home/web/conf.d"
CERT_DIR="/home/web/certs"
WEBROOT="/home/web/letsencrypt"
UPSTREAM_NAME="backend_$(echo $DOMAIN | tr '.-' '_')"

# 检查是否已存在
if [ -f "${CONF_DIR}/${DOMAIN}.conf" ]; then
    read -p "域名 ${DOMAIN} 已配置，是否覆盖？(y/N): " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && exit 0
fi

# 检查 nginx 容器是否运行
docker ps --format '{{.Names}}' | grep -q '^nginx$' || error "nginx 容器未运行，请先执行 install.sh"

info "[1/4] 创建临时 HTTP 配置..."
cat > "${CONF_DIR}/${DOMAIN}.conf" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
docker exec nginx nginx -s reload
sleep 1

info "[2/4] 签发 Let's Encrypt 证书..."
# 使用 Docker 版 certbot，无需宿主机安装
docker run --rm \
    -v "/etc/letsencrypt:/etc/letsencrypt" \
    -v "${WEBROOT}:/var/www/letsencrypt" \
    certbot/certbot certonly \
    --webroot -w /var/www/letsencrypt \
    -d "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --key-type ecdsa \
    --cert-name "${DOMAIN}"

# 复制证书
cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem "${CERT_DIR}/${DOMAIN}_cert.pem"
cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem "${CERT_DIR}/${DOMAIN}_key.pem"
ok "证书签发成功"

info "[3/4] 生成 HTTPS 反代配置..."
cat > "${CONF_DIR}/${DOMAIN}.conf" << EOF
upstream ${UPSTREAM_NAME} {
    server 127.0.0.1:${PORT};
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 443 quic;
    listen [::]:443 quic;

    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/certs/${DOMAIN}_cert.pem;
    ssl_certificate_key /etc/nginx/certs/${DOMAIN}_key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    # HTTP/3
    add_header Alt-Svc 'h3=":443"; ma=86400';

    location / {
        proxy_pass http://${UPSTREAM_NAME};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
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
echo -e "   域名: https://${DOMAIN}"
echo -e "   反代: 127.0.0.1:${PORT}"
echo -e "   配置: ${CONF_DIR}/${DOMAIN}.conf"
echo -e "   证书: ${CERT_DIR}/${DOMAIN}_cert.pem"
ADD_SITE

chmod +x /usr/local/bin/add-site

# --- del-site 脚本 ---
cat > /usr/local/bin/del-site << 'DEL_SITE'
#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

if [ $# -lt 1 ]; then
    echo "用法: del-site <域名>"
    echo "示例: del-site example.com"
    exit 1
fi

DOMAIN=$1
CONF_DIR="/home/web/conf.d"
CERT_DIR="/home/web/certs"

if [ ! -f "${CONF_DIR}/${DOMAIN}.conf" ]; then
    error "域名 ${DOMAIN} 的配置不存在"
fi

read -p "确认删除 ${DOMAIN} 的配置和证书？(y/N): " confirm
[ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && exit 0

info "删除配置和证书..."
rm -f "${CONF_DIR}/${DOMAIN}.conf"
rm -f "${CERT_DIR}/${DOMAIN}_cert.pem"
rm -f "${CERT_DIR}/${DOMAIN}_key.pem"

# 删除 certbot 证书记录
docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$DOMAIN" -n 2>/dev/null || true

docker exec nginx nginx -s reload
ok "域名 ${DOMAIN} 已删除"
DEL_SITE

chmod +x /usr/local/bin/del-site

# --- 证书自动续签脚本 ---
cat > ~/auto_cert_renewal.sh << 'RENEW'
#!/bin/bash
# ============================================================
# SSL 证书自动续签脚本
# 每天由 cron 调用，检查所有证书，到期前 15 天自动续签
# ============================================================

certs_directory="/home/web/certs/"
days_before_expiry=15

for cert_file in $certs_directory*_cert.pem; do
    [ -f "$cert_file" ] || continue

    yuming=$(basename "$cert_file" "_cert.pem")

    # 跳过默认自签名证书
    [ "$yuming" = "default_server" ] && continue

    echo "检查证书过期日期： ${yuming}"

    expiration_date=$(openssl x509 -enddate -noout -in "${certs_directory}${yuming}_cert.pem" | cut -d "=" -f 2-)
    echo "过期日期： ${expiration_date}"

    expiration_timestamp=$(date -d "${expiration_date}" +%s)
    current_timestamp=$(date +%s)
    days_until_expiry=$(( ($expiration_timestamp - $current_timestamp) / 86400 ))

    if [ $days_until_expiry -le $days_before_expiry ]; then
        echo "证书将在${days_before_expiry}天内过期，正在进行自动续签。"

        # 检测环境
        docker exec nginx [ -d /var/www/letsencrypt ] && DIR_OK=true || DIR_OK=false
        docker exec nginx grep -q "letsencrypt" /etc/nginx/conf.d/$yuming.conf 2>/dev/null && CONF_OK=true || CONF_OK=false

        echo "--- 自动化环境检测报告 ---"
        [ "$DIR_OK" = true ] && echo "✅ 目录检测：/var/www/letsencrypt 存在" || echo "❌ 目录检测：/var/www/letsencrypt 不存在"
        [ "$CONF_OK" = true ] && echo "✅ 配置检测：$yuming.conf 已包含续签规则" || echo "❌ 配置检测：$yuming.conf 未发现 letsencrypt 字样"

        if [ "$DIR_OK" = true ] && [ "$CONF_OK" = true ]; then
            # webroot 模式续签（不停 nginx）
            docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n

            docker run --rm \
              -v "/etc/letsencrypt:/etc/letsencrypt" \
              -v "/home/web/letsencrypt:/var/www/letsencrypt" \
              certbot/certbot certonly \
              --webroot -w /var/www/letsencrypt \
              -d "$yuming" \
              --register-unsafely-without-email \
              --agree-tos --no-eff-email --key-type ecdsa --force-renewal

            cp /etc/letsencrypt/live/$yuming/fullchain.pem /home/web/certs/${yuming}_cert.pem > /dev/null 2>&1
            cp /etc/letsencrypt/live/$yuming/privkey.pem /home/web/certs/${yuming}_key.pem > /dev/null 2>&1

            openssl rand -out /home/web/certs/ticket12.key 48
            openssl rand -out /home/web/certs/ticket13.key 80

            docker exec nginx nginx -t && docker exec nginx nginx -s reload
        else
            # 降级：standalone 模式续签（需要停 nginx）
            docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$yuming" -n

            docker stop nginx > /dev/null 2>&1

            docker run --rm -p 80:80 -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot certonly \
              --standalone -d $yuming \
              --register-unsafely-without-email \
              --agree-tos --no-eff-email --force-renewal --key-type ecdsa

            cp /etc/letsencrypt/live/$yuming/fullchain.pem /home/web/certs/${yuming}_cert.pem > /dev/null 2>&1
            cp /etc/letsencrypt/live/$yuming/privkey.pem /home/web/certs/${yuming}_key.pem > /dev/null 2>&1

            openssl rand -out /home/web/certs/ticket12.key 48
            openssl rand -out /home/web/certs/ticket13.key 80

            docker start nginx > /dev/null 2>&1
        fi
        echo "证书已成功续签。"
    else
        echo "证书仍然有效，距离过期还有 ${days_until_expiry} 天。"
    fi
    echo "--------------------------"
done
RENEW

chmod +x ~/auto_cert_renewal.sh
ok "管理脚本已安装"

# ============================================================
# 配置定时任务
# ============================================================
info "[6/6] 配置定时任务..."

# 添加证书续签定时任务（避免重复添加）
if ! crontab -l 2>/dev/null | grep -q "auto_cert_renewal"; then
    (crontab -l 2>/dev/null; echo "0 0 * * * ~/auto_cert_renewal.sh >> /var/log/cert_renewal.log 2>&1") | crontab -
    ok "证书自动续签定时任务已添加（每天 0:00）"
else
    ok "证书自动续签定时任务已存在"
fi

# ============================================================
# 启动 Nginx
# ============================================================
info "启动 Nginx..."
cd ${WEB_DIR} && docker compose up -d

sleep 2
if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
    ok "Nginx 已成功启动"
else
    error "Nginx 启动失败，请检查日志：docker logs nginx"
fi

echo ""
echo "============================================"
echo -e "${GREEN}🎉 安装完成！${NC}"
echo "============================================"
echo ""
echo "使用方法："
echo "  添加域名反代:  add-site <域名> <端口>"
echo "  删除域名:      del-site <域名>"
echo ""
echo "示例："
echo "  add-site example.com 8080"
echo "  add-site api.example.com 3000"
echo ""
echo "配置目录: ${WEB_DIR}/"
echo "站点配置: ${WEB_DIR}/conf.d/"
echo "SSL 证书: ${WEB_DIR}/certs/"
echo "Nginx 日志: ${WEB_DIR}/log/nginx/"
echo "============================================"
