#!/bin/bash
# ============================================================
# Nginx Docker 一键安装 + 交互式管理脚本
# 作者：wsuming97
# ============================================================

# 注意：不在顶层使用 set -e，避免函数内预期失败的命令中断脚本
# 各函数内部自行处理错误

# ============================================================
# 全局变量和颜色
# ============================================================
WEB_DIR="/home/web"
CONF_DIR="${WEB_DIR}/conf.d"
CERT_DIR="${WEB_DIR}/certs"
WEBROOT="${WEB_DIR}/letsencrypt"
MANAGE_CMD="/usr/local/bin/nginx-proxy"

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
    echo -e "${CYAN}>>> 正在初始化 Nginx Proxy 环境，请稍候...${NC}"

    [ "$(id -u)" -ne 0 ] && die "请使用 root 用户运行此脚本"

    # 安装 Docker
    if ! command -v docker &> /dev/null; then
        info "正在为您自动安装 Docker..."
        curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
        systemctl enable --now docker > /dev/null 2>&1
    fi
    docker compose version &> /dev/null || die "docker compose 不可用，请检查环境"

    # 创建基础目录
    mkdir -p ${WEB_DIR}/{conf.d,stream.d,certs,html,letsencrypt,log/nginx}

    # 同步自身为管理脚本（仅当管理脚本不存在时才下载）
    if [ ! -f "${MANAGE_CMD}" ]; then
        curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/install.sh -o "${MANAGE_CMD}" 2>/dev/null || true
        chmod +x "${MANAGE_CMD}" 2>/dev/null || true
    fi

    # 检查 auto_cert_renewal.sh 是否存在，如果不存在且已安装 Nginx，则生成
    if [ ! -f ~/auto_cert_renewal.sh ]; then
        install_cert_renewal >/dev/null 2>&1 || true
    fi
}

# ============================================================
# 安装证书续签脚本功能核心代码（供调用）
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

if ! crontab -l 2>/dev/null | grep -q "auto_cert_renewal"; then
    (crontab -l 2>/dev/null; echo "0 0 * * * ~/auto_cert_renewal.sh >> /var/log/cert_renewal.log 2>&1") | crontab -
fi
}

# ============================================================
# 选项 1：安装反代生成配置环境
# ============================================================
cmd_install_nginx() {
    echo ""
    info "开始安装 Nginx 代理环境..."

    # 自签名证书
    if [ ! -f "${CERT_DIR}/default_server.crt" ]; then
        openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "${CERT_DIR}/default_server.key" \
            -out "${CERT_DIR}/default_server.crt" \
            -subj "/CN=default_server" 2>/dev/null
    fi

    openssl rand -out "${CERT_DIR}/ticket12.key" 48 2>/dev/null
    openssl rand -out "${CERT_DIR}/ticket13.key" 80 2>/dev/null

    # nginx.conf - 始终覆盖为最新版本，确保配置完整
    info "生成 nginx.conf..."
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

    # 静态文件反代缓存
    proxy_cache_path /var/cache/nginx/proxy levels=1:2 keys_zone=my_proxy_cache:20m max_size=1g inactive=30m;
    proxy_cache_key "$request_method$host$request_uri$is_args$args$http_accept_encoding";
    proxy_cache_methods GET HEAD;
    proxy_cache_valid 200 301 302 304 120m;
    proxy_cache_valid 404 10m;
    proxy_cache_valid 500 502 503 504 400 403 429 0;
    proxy_cache_lock on;
    proxy_cache_lock_timeout 5s;
    proxy_cache_background_update on;

    include /etc/nginx/conf.d/*.conf;
}

stream {
    include /etc/nginx/stream.d/*.conf;
}
NGINX_CONF

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
    fi

    # 安装续签脚本并配置计划任务
    install_cert_renewal

    info "启动 Nginx..."
    cd ${WEB_DIR} && docker compose up -d

    sleep 3
    if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
        ok "Nginx 环境安装且启动成功！"
    else
        error "Nginx 启动失败，请使用 docker logs nginx 查看日志"
    fi
}

# ============================================================
# 选项 2：添加域名反代并获取证书
# ============================================================
cmd_add() {
    local domain=$1
    local port=$2

    echo ""
    info "正在配置域名反代及证书..."

    if [ -z "$domain" ]; then
        read -p "请输入域名 (例如 my.example.com): " domain
        [ -z "$domain" ] && { error "域名不能为空"; return 1; }
    fi
    if [ -z "$port" ]; then
        read -p "请输入后端端口 (例如 8080): " port
        [ -z "$port" ] && { error "端口不能为空"; return 1; }
    fi

    local upstream_name="backend_$(echo $domain | tr '.-' '_')"

    if [ -f "${CONF_DIR}/${domain}.conf" ]; then
        warn "域名 ${domain} 已配置，将被覆盖"
    fi

    if ! docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
        error "nginx 容器未运行，请先执行选项 1 安装反代环境"
        return 1
    fi

    # 自动检查并补全 nginx.conf 中的 proxy_cache_path 配置
    if ! grep -q "proxy_cache_path" "${WEB_DIR}/nginx.conf" 2>/dev/null; then
        warn "检测到 nginx.conf 缺少缓存配置，正在自动补全..."
        sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/i \
    proxy_cache_path /var/cache/nginx/proxy levels=1:2 keys_zone=my_proxy_cache:20m max_size=1g inactive=30m;\n    proxy_cache_key "$request_method$host$request_uri$is_args$args$http_accept_encoding";\n    proxy_cache_methods GET HEAD;\n    proxy_cache_valid 200 301 302 304 120m;\n    proxy_cache_valid 404 10m;\n    proxy_cache_valid 500 502 503 504 400 403 429 0;\n    proxy_cache_lock on;\n    proxy_cache_lock_timeout 5s;\n    proxy_cache_background_update on;' "${WEB_DIR}/nginx.conf"
        docker restart nginx
        sleep 2
        ok "缓存配置已自动补全"
    fi

    info "创建 HTTP 验证配置..."
    cat > "${CONF_DIR}/${domain}.conf" << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

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
    sleep 2

    info "签发 Let's Encrypt 证书..."
    if ! docker run --rm \
        -v "/etc/letsencrypt:/etc/letsencrypt" \
        -v "${WEBROOT}:/var/www/letsencrypt" \
        certbot/certbot certonly \
        --webroot -w /var/www/letsencrypt \
        -d "${domain}" \
        --non-interactive \
        --agree-tos \
        --register-unsafely-without-email \
        --key-type ecdsa \
        --cert-name "${domain}"; then
        error "证书签发失败！请确认该域名的 DNS A 记录已指向本服务器 IP"
        rm -f "${CONF_DIR}/${domain}.conf"
        docker exec nginx nginx -s reload
        return 1
    fi

    cp /etc/letsencrypt/live/${domain}/fullchain.pem "${CERT_DIR}/${domain}_cert.pem"
    cp /etc/letsencrypt/live/${domain}/privkey.pem "${CERT_DIR}/${domain}_key.pem"
    ok "证书签发成功！"

    info "生成 HTTPS 完整反代配置..."
    cat > "${CONF_DIR}/${domain}.conf" << EOF
upstream ${upstream_name} {
    server 127.0.0.1:${port};
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

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

    server_name ${domain};

    ssl_certificate /etc/nginx/certs/${domain}_cert.pem;
    ssl_certificate_key /etc/nginx/certs/${domain}_key.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    add_header Alt-Svc 'h3=":443"; ma=86400';

    location / {
        proxy_pass http://${upstream_name};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    # 静态文件缓存：命中后直接从 Nginx 返回，无需回源后端
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|bmp|swf|eot|svg|ttf|woff|woff2|webp)\$ {
        proxy_pass http://${upstream_name};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_cache my_proxy_cache;                          # 开启缓存
        proxy_set_header Accept-Encoding "";
        proxy_set_header Connection "";
        add_header X-Cache \$upstream_cache_status;          # HIT/MISS 调试用
        add_header Cache-Control "public, max-age=2592000"; # 浏览器缓存 30 天
        add_header Alt-Svc 'h3=":443"; ma=86400';           # HTTP/3
        aio threads;                                         # 异步 IO，加快缓存文件读取
        log_not_found off;
        access_log off;
    }

    location ^~ /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/letsencrypt;
    }

    client_max_body_size 100m;
}
EOF

    docker exec nginx nginx -t && docker exec nginx nginx -s reload

    echo ""
    ok "配置完成！"
    echo -e "   域名: ${CYAN}https://${domain}${NC}"
    echo -e "   反代: ${CYAN}127.0.0.1:${port}${NC}"
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

    if [ ! -f "${CONF_DIR}/${domain}.conf" ]; then
        error "域名 ${domain} 的配置不存在"
        return 1
    fi

    read -p "确认彻底删除 ${domain} 的所有配置和证书？(y/N): " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 0

    rm -f "${CONF_DIR}/${domain}.conf"
    rm -f "${CERT_DIR}/${domain}_cert.pem"
    rm -f "${CERT_DIR}/${domain}_key.pem"
    docker run --rm -v /etc/letsencrypt/:/etc/letsencrypt certbot/certbot delete --cert-name "$domain" -n 2>/dev/null || true
    docker exec nginx nginx -s reload
    
    ok "域名 ${domain} 解析已删除"
}

# ============================================================
# 选项 4：手动续签证书
# ============================================================
cmd_renew() {
    echo ""
    info "手动检查并续签证书..."
    if [ -f ~/auto_cert_renewal.sh ]; then
        bash ~/auto_cert_renewal.sh
    else
        error "续签脚本未找到，请先确保 Nginx 环境已安装"
    fi
}

# ============================================================
# 查看已配域名辅助函数
# ============================================================
cmd_list_domains() {
    echo -e "${BOLD}当前已配置的域名：${NC}"
    local count=0
    for conf in ${CONF_DIR}/*.conf; do
        [ -f "$conf" ] || continue
        local name=$(basename "$conf" .conf)
        [ "$name" = "default" ] && continue
        
        local port=$(grep -oP 'server 127\.0\.0\.1:\K[0-9]+' "$conf" 2>/dev/null | head -1)
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
    # 跳过 IPv6 重复行以保持简洁，用户可选择查看完整版
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
            # 无对外端口映射（仅内部通信）
            printf "  %-22s ${YELLOW}%-50s${NC}\n" "$name" "(仅内部通信，无对外端口)"
        else
            # 简化显示：去掉冗余的 IPv6 重复映射
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
    echo -e "${GREEN}${BOLD}║        Nginx Docker 反向代理管理菜单         ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    if docker ps --format '{{.Names}}' | grep -q '^nginx$'; then
        echo -e "  Nginx 容器状态: ${GREEN}运行中${NC}"
    else
        echo -e "  Nginx 容器状态: ${RED}未运行 (请先执行 1 安装环境)${NC}"
    fi
    echo ""
    line
    echo -e "  ${GREEN}1.${NC} 安装反代生成配置环境"
    echo -e "  ${GREEN}2.${NC} 添加域名反代及获取证书"
    echo -e "  ${GREEN}3.${NC} 删除域名反代及证书"
    echo -e "  ${GREEN}4.${NC} 手动续签所有证书"
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
            1) cmd_install_nginx; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            2) cmd_add; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            3) cmd_del; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            4) cmd_renew; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            5) echo ""; cmd_list_domains; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            6) cmd_ports; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            0) echo "已退出！随时输入 nginx-proxy 重新进入菜单。"; exit 0 ;;
            *) warn "请输入正确的数字"; sleep 1 ;;
        esac
    done
}

# ============================================================
# 脚本入口点
# ============================================================
# 执行前置环境变量检查、Docker安装和目录创建
init_env

# 命令行直传参数快捷访问（兼容系统命令模式）
case "$1" in
    add)    cmd_add "$2" "$3" ;;
    del)    cmd_del "$2" ;;
    list)   cmd_list_domains ;;
    renew)  cmd_renew ;;
    install)cmd_install_nginx ;;
    ports)  cmd_ports ;;
    *)      menu_loop ;;
esac
