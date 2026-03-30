#!/bin/bash
# ============================================================
# Docker & Docker Compose 一键安装 + 管理 + 卸载脚本
# 作者：wsuming97
# ============================================================

# 注意：不在顶层使用 set -e，避免函数内预期失败的命令中断脚本
# 各函数内部自行处理错误

# ============================================================
# 全局变量和颜色
# ============================================================
MANAGE_CMD="/usr/local/bin/docker-manager"

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
# 初始化：权限检查 + 同步管理脚本
# ============================================================
init_env() {
    echo -e "${CYAN}>>> 正在初始化 Docker Manager 环境，请稍候...${NC}"

    [ "$(id -u)" -ne 0 ] && die "请使用 root 用户运行此脚本"

    # 同步自身为管理脚本（仅当管理脚本不存在时才下载）
    if [ ! -f "${MANAGE_CMD}" ]; then
        curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/docker-install.sh -o "${MANAGE_CMD}" 2>/dev/null || true
        chmod +x "${MANAGE_CMD}" 2>/dev/null || true
    fi
}

# ============================================================
# 获取 Docker 状态信息（内部辅助函数）
# ============================================================
get_docker_status() {
    if command -v docker &> /dev/null; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "not_installed"
    fi
}

get_compose_status() {
    if docker compose version &> /dev/null; then
        echo "installed"
    elif command -v docker-compose &> /dev/null; then
        echo "standalone"
    else
        echo "not_installed"
    fi
}

# ============================================================
# 选项 1：安装 Docker
# ============================================================
cmd_install_docker() {
    echo ""
    info "开始安装 Docker..."

    if command -v docker &> /dev/null; then
        local ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        ok "Docker 已安装：v${ver}"
        read -p "是否重新安装/更新？(y/N): " confirm
        [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 0
    fi

    # 检测系统类型
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        local os_id="${ID}"
    else
        die "无法检测操作系统类型"
    fi

    info "检测到系统：${os_id}"

    # 多源降级安装：官方源 → 阿里云 → DaoCloud
    local installed=false

    # 1. 官方源
    info "[1/3] 尝试官方源安装 Docker..."
    if curl -fsSL https://get.docker.com | sh > /dev/null 2>&1; then
        ok "Docker 安装成功（官方源）"
        installed=true
    else
        warn "官方源安装失败"
    fi

    # 2. 阿里云镜像
    if [ "$installed" = false ]; then
        info "[2/3] 尝试阿里云镜像安装 Docker..."
        if curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun > /dev/null 2>&1; then
            ok "Docker 安装成功（阿里云镜像）"
            installed=true
        else
            warn "阿里云镜像安装失败"
        fi
    fi

    # 3. DaoCloud 镜像
    if [ "$installed" = false ]; then
        info "[3/3] 尝试 DaoCloud 镜像安装 Docker..."
        if curl -fsSL https://get.daocloud.io/docker | sh > /dev/null 2>&1; then
            ok "Docker 安装成功（DaoCloud 镜像）"
            installed=true
        else
            warn "DaoCloud 镜像安装失败"
        fi
    fi

    if [ "$installed" = false ]; then
        die "所有安装源均失败，请检查网络连接"
    fi

    # 启动并设置开机自启
    systemctl enable docker > /dev/null 2>&1
    systemctl start docker > /dev/null 2>&1

    sleep 2
    if systemctl is-active --quiet docker; then
        local ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        ok "Docker 已启动：v${ver}"
    else
        error "Docker 启动失败，请检查日志：journalctl -u docker --no-pager -n 20"
    fi

    # 自动配置镜像加速源
    configure_registry_mirrors
}

# ============================================================
# 选项 2：安装 Docker Compose
# ============================================================
cmd_install_compose() {
    echo ""
    info "开始安装 Docker Compose..."

    # 检查 Docker 是否已安装
    if ! command -v docker &> /dev/null; then
        error "Docker 未安装，请先执行选项 1 安装 Docker"
        return 1
    fi

    # 检查 Compose 插件是否已存在
    if docker compose version &> /dev/null; then
        local ver=$(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        ok "Docker Compose 已安装：v${ver}"
        read -p "是否重新安装/更新？(y/N): " confirm
        [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return 0
    fi

    # 优先安装 docker-compose-plugin（新版推荐方式）
    info "正在安装 Docker Compose 插件..."

    # 检测包管理器并安装
    if command -v apt-get &> /dev/null; then
        apt-get update -qq > /dev/null 2>&1
        if apt-get install -y -qq docker-compose-plugin > /dev/null 2>&1; then
            ok "Docker Compose 插件安装成功"
        else
            warn "apt 安装失败，尝试手动下载二进制..."
            install_compose_binary
        fi
    elif command -v yum &> /dev/null; then
        if yum install -y -q docker-compose-plugin > /dev/null 2>&1; then
            ok "Docker Compose 插件安装成功"
        else
            warn "yum 安装失败，尝试手动下载二进制..."
            install_compose_binary
        fi
    elif command -v dnf &> /dev/null; then
        if dnf install -y -q docker-compose-plugin > /dev/null 2>&1; then
            ok "Docker Compose 插件安装成功"
        else
            warn "dnf 安装失败，尝试手动下载二进制..."
            install_compose_binary
        fi
    else
        info "未检测到已知包管理器，尝试手动下载二进制..."
        install_compose_binary
    fi

    # 验证安装结果
    if docker compose version &> /dev/null; then
        local ver=$(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        ok "Docker Compose 可用：v${ver}"
    else
        error "Docker Compose 安装失败"
        return 1
    fi
}

# ============================================================
# 配置 Docker 镜像加速源
# 优先级：阿里云 → DaoCloud → 网易 → 腾讯云 → 官方
# ============================================================
configure_registry_mirrors() {
    info "配置 Docker 镜像加速源..."

    mkdir -p /etc/docker

    # 如果已有自定义配置，合并而非覆盖
    if [ -f /etc/docker/daemon.json ] && grep -q '"registry-mirrors"' /etc/docker/daemon.json 2>/dev/null; then
        warn "检测到已有镜像加速配置，跳过覆盖"
        return 0
    fi

    # 保留已有配置中的其他字段，仅追加 registry-mirrors
    if [ -f /etc/docker/daemon.json ] && [ -s /etc/docker/daemon.json ]; then
        # 已有配置文件但无 registry-mirrors，使用 sed 注入
        # 简单起见：备份后重写（保留其他字段较复杂，此处覆盖安全）
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
        warn "已备份原配置到 /etc/docker/daemon.json.bak"
    fi

    cat > /etc/docker/daemon.json << 'DAEMON_JSON'
{
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://docker.m.daocloud.io",
        "https://hub-mirror.c.163.com",
        "https://registry.docker-cn.com"
    ],
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "3"
    }
}
DAEMON_JSON

    # 重载 Docker 使配置生效
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true

    sleep 2
    if systemctl is-active --quiet docker; then
        ok "镜像加速源配置完成"
        echo -e "  加速源列表："
        echo -e "    1. ${CYAN}腾讯云${NC}  mirror.ccs.tencentyun.com"
        echo -e "    2. ${CYAN}DaoCloud${NC} docker.m.daocloud.io"
        echo -e "    3. ${CYAN}网易${NC}    hub-mirror.c.163.com"
        echo -e "    4. ${CYAN}官方CN${NC}  registry.docker-cn.com"
    else
        warn "Docker 重启失败，镜像加速配置可能未生效"
    fi
}

# ============================================================
# 手动下载 Compose 二进制文件的降级方案
# 下载源：GitHub → DaoCloud 镜像
# ============================================================
install_compose_binary() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="aarch64" ;;
        armv7l)  arch="armv7" ;;
        *)       die "不支持的架构：${arch}" ;;
    esac

    # 获取最新版本号
    local latest_ver
    latest_ver=$(curl -sL "https://api.github.com/repos/docker/compose/releases/latest" | grep '"tag_name"' | grep -oP '\d+\.\d+\.\d+' | head -1)
    if [ -z "$latest_ver" ]; then
        warn "无法获取最新版本号，使用 v2.32.4"
        latest_ver="2.32.4"
    fi

    info "下载 Docker Compose v${latest_ver}..."
    local plugin_dir="/usr/local/lib/docker/cli-plugins"
    mkdir -p "${plugin_dir}"

    local downloaded=false

    # 1. GitHub 官方源
    info "[1/2] 尝试从 GitHub 下载..."
    if curl -fsSL --connect-timeout 15 \
        "https://github.com/docker/compose/releases/download/v${latest_ver}/docker-compose-linux-${arch}" \
        -o "${plugin_dir}/docker-compose" 2>/dev/null; then
        downloaded=true
        ok "从 GitHub 下载成功"
    else
        warn "GitHub 下载失败"
    fi

    # 2. DaoCloud 镜像
    if [ "$downloaded" = false ]; then
        info "[2/2] 尝试从 DaoCloud 镜像下载..."
        if curl -fsSL --connect-timeout 15 \
            "https://get.daocloud.io/docker/compose/releases/download/v${latest_ver}/docker-compose-linux-${arch}" \
            -o "${plugin_dir}/docker-compose" 2>/dev/null; then
            downloaded=true
            ok "从 DaoCloud 镜像下载成功"
        else
            warn "DaoCloud 镜像下载失败"
        fi
    fi

    if [ "$downloaded" = false ]; then
        die "所有下载源均失败，请检查网络连接"
    fi

    chmod +x "${plugin_dir}/docker-compose"
    ok "Docker Compose 二进制安装成功"
}

# ============================================================
# 选项 3：管理 Docker & Compose
# ============================================================
cmd_manage() {
    while true; do
        echo ""
        echo -e "${BOLD}Docker 管理操作：${NC}"
        line
        echo -e "  ${GREEN} 1.${NC} 查看 Docker 状态"
        echo -e "  ${GREEN} 2.${NC} 启动 Docker"
        echo -e "  ${GREEN} 3.${NC} 停止 Docker"
        echo -e "  ${GREEN} 4.${NC} 重启 Docker"
        echo -e "  ${GREEN} 5.${NC} 查看运行中的容器"
        echo -e "  ${GREEN} 6.${NC} 查看所有容器"
        echo -e "  ${GREEN} 7.${NC} 查看镜像列表"
        echo -e "  ${GREEN} 8.${NC} 查看 Docker 日志（最近 50 行）"
        echo -e "  ${GREEN} 9.${NC} 查看 Docker 磁盘占用"
        echo -e "  ${GREEN}10.${NC} 清理 Docker 系统垃圾"
        echo -e "  ${GREEN}11.${NC} 修复 Docker 网络"
        echo -e "  ${GREEN}12.${NC} 自愈 Docker"
        echo -e "  ${GREEN} 0.${NC} 返回主菜单"
        line
        echo ""

        read -p "请输入数字 [0-12]: " mgmt_choice
        case $mgmt_choice in
            1)
                echo ""
                info "Docker 服务状态："
                systemctl status docker --no-pager -l | head -15
                echo ""
                if docker compose version &> /dev/null; then
                    echo -e "  Compose 版本: ${CYAN}$(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)${NC}"
                fi
                ;;
            2)
                echo ""
                info "启动 Docker..."
                systemctl start docker
                sleep 2
                if systemctl is-active --quiet docker; then
                    ok "Docker 已启动"
                else
                    error "Docker 启动失败"
                fi
                ;;
            3)
                echo ""
                warn "停止 Docker 会同时停止所有运行中的容器"
                read -p "确认停止？(y/N): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    systemctl stop docker
                    ok "Docker 已停止"
                fi
                ;;
            4)
                echo ""
                info "重启 Docker..."
                systemctl restart docker
                sleep 2
                if systemctl is-active --quiet docker; then
                    ok "Docker 已重启"
                else
                    error "Docker 重启失败"
                fi
                ;;
            5)
                echo ""
                info "运行中的容器："
                docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || error "无法获取容器信息"
                ;;
            6)
                echo ""
                info "所有容器："
                docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || error "无法获取容器信息"
                ;;
            7)
                echo ""
                info "镜像列表："
                docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null || error "无法获取镜像信息"
                ;;
            8)
                echo ""
                info "Docker 服务日志（最近 50 行）："
                journalctl -u docker --no-pager -n 50
                ;;
            9)
                echo ""
                info "Docker 磁盘占用："
                docker system df 2>/dev/null || error "无法获取磁盘信息"
                ;;
            10)
                # 清理 Docker 系统垃圾：分级清理，避免误删
                echo ""
                info "清理 Docker 系统垃圾..."
                echo ""
                echo -e "  ${GREEN}a.${NC} 普通清理（悬空镜像 + 停止的容器 + 无用网络）"
                echo -e "  ${YELLOW}b.${NC} 深度清理（普通清理 + 所有未使用的镜像）"
                echo -e "  ${RED}c.${NC} 完全清理（深度清理 + 未使用的数据卷）${RED}⚠️ 可能丢失数据${NC}"
                echo ""
                read -p "选择清理级别 [a/b/c]: " clean_level
                case "$clean_level" in
                    a|A)
                        info "执行普通清理..."
                        docker system prune -f 2>/dev/null
                        ok "普通清理完成"
                        ;;
                    b|B)
                        info "执行深度清理..."
                        docker system prune -af 2>/dev/null
                        ok "深度清理完成"
                        ;;
                    c|C)
                        read -p "⚠️ 确认删除所有未使用的数据卷？(输入 YES): " vol_confirm
                        if [ "$vol_confirm" = "YES" ]; then
                            info "执行完全清理..."
                            docker system prune -af --volumes 2>/dev/null
                            ok "完全清理完成"
                        else
                            info "已取消"
                        fi
                        ;;
                    *) warn "已取消" ;;
                esac
                echo ""
                info "当前磁盘占用："
                docker system df 2>/dev/null || true
                ;;
            11)
                # 修复 Docker 网络：清理残留网络 + 重建 docker0 网桥
                echo ""
                info "修复 Docker 网络..."
                warn "将重建 Docker 网络，运行中的容器可能短暂断网"
                read -p "确认修复？(y/N): " confirm
                if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
                    info "清理残留网络..."
                    docker network prune -f 2>/dev/null || true
                    info "重启 Docker 重建网桥..."
                    systemctl restart docker
                    sleep 3
                    if systemctl is-active --quiet docker; then
                        ok "Docker 网络已修复"
                        echo ""
                        info "当前网络列表："
                        docker network ls 2>/dev/null
                    else
                        error "Docker 重启失败，请手动检查"
                    fi
                fi
                ;;
            12)
                # 自愈 Docker：自动重启异常容器（exited + unhealthy）
                echo ""
                info "自愈 Docker：检查并重启异常容器..."
                local healed=0

                # 重启所有 exited 状态的容器
                local exited_list
                exited_list=$(docker ps -a --filter "status=exited" --format '{{.Names}}' 2>/dev/null)
                if [ -n "$exited_list" ]; then
                    echo -e "  ${YELLOW}发现已退出的容器：${NC}"
                    echo "$exited_list" | while read -r cname; do
                        [ -z "$cname" ] && continue
                        echo -e "    ${YELLOW}${cname}${NC} → 正在重启..."
                        if docker restart "$cname" > /dev/null 2>&1; then
                            echo -e "    ${GREEN}✅ ${cname} 已重启${NC}"
                        else
                            echo -e "    ${RED}❌ ${cname} 重启失败${NC}"
                        fi
                    done
                    healed=1
                fi

                # 重启所有 unhealthy 状态的容器
                local unhealthy_list
                unhealthy_list=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null)
                if [ -n "$unhealthy_list" ]; then
                    echo -e "  ${YELLOW}发现不健康的容器：${NC}"
                    echo "$unhealthy_list" | while read -r cname; do
                        [ -z "$cname" ] && continue
                        echo -e "    ${YELLOW}${cname}${NC} → 正在重启..."
                        if docker restart "$cname" > /dev/null 2>&1; then
                            echo -e "    ${GREEN}✅ ${cname} 已重启${NC}"
                        else
                            echo -e "    ${RED}❌ ${cname} 重启失败${NC}"
                        fi
                    done
                    healed=1
                fi

                if [ "$healed" -eq 0 ]; then
                    ok "所有容器状态正常，无需自愈"
                else
                    sleep 3
                    echo ""
                    ok "自愈完成，当前容器状态："
                    docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null
                fi
                ;;
            0)
                return 0
                ;;
            *)
                warn "请输入正确的数字"
                sleep 1
                ;;
        esac
        echo ""
        read -p "$(echo -e ${CYAN}按回车继续...${NC})"
    done
}

# ============================================================
# 选项 4：卸载 Docker & Compose
# ============================================================
cmd_uninstall() {
    echo ""
    warn "此操作将完整卸载 Docker 和 Docker Compose！"
    echo ""

    # 展示当前容器和镜像概览
    if command -v docker &> /dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        local running=$(docker ps -q 2>/dev/null | wc -l)
        local total=$(docker ps -aq 2>/dev/null | wc -l)
        local images=$(docker images -q 2>/dev/null | wc -l)
        local volumes=$(docker volume ls -q 2>/dev/null | wc -l)
        echo -e "  当前环境："
        echo -e "    运行中容器: ${CYAN}${running}${NC}"
        echo -e "    全部容器:   ${CYAN}${total}${NC}"
        echo -e "    镜像数量:   ${CYAN}${images}${NC}"
        echo -e "    数据卷数量: ${CYAN}${volumes}${NC}"
        echo ""
    fi

    echo -e "  ${RED}${BOLD}⚠ 警告：卸载将删除 Docker 引擎和 Compose 插件${NC}"
    echo -e "  ${YELLOW}可选择是否同时清理所有容器、镜像、卷和数据${NC}"
    echo ""

    read -p "确认卸载 Docker & Compose？(输入 YES 确认): " confirm
    [ "$confirm" != "YES" ] && { info "已取消卸载"; return 0; }

    echo ""
    read -p "是否同时删除所有容器、镜像、卷和数据？(y/N): " clean_data

    # 停止所有容器
    if command -v docker &> /dev/null; then
        info "停止所有运行中的容器..."
        docker stop $(docker ps -q 2>/dev/null) 2>/dev/null || true

        # 清理数据（如用户确认）
        if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
            info "删除所有容器..."
            docker rm -f $(docker ps -aq 2>/dev/null) 2>/dev/null || true
            info "删除所有镜像..."
            docker rmi -f $(docker images -q 2>/dev/null) 2>/dev/null || true
            info "删除所有数据卷..."
            docker volume rm $(docker volume ls -q 2>/dev/null) 2>/dev/null || true
            info "清理网络..."
            docker network prune -f 2>/dev/null || true
        fi
    fi

    # 停止 Docker 服务
    info "停止 Docker 服务..."
    systemctl stop docker 2>/dev/null || true
    systemctl stop docker.socket 2>/dev/null || true
    systemctl disable docker 2>/dev/null || true
    systemctl disable docker.socket 2>/dev/null || true

    # 卸载 Docker 软件包
    info "卸载 Docker 软件包..."
    if command -v apt-get &> /dev/null; then
        apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        apt-get autoremove -y 2>/dev/null || true
    elif command -v yum &> /dev/null; then
        yum remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    elif command -v dnf &> /dev/null; then
        dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    fi

    # 删除 Compose 二进制文件（手动安装的情况）
    rm -f /usr/local/lib/docker/cli-plugins/docker-compose 2>/dev/null || true
    rm -f /usr/local/bin/docker-compose 2>/dev/null || true

    # 清理数据目录（如用户确认）
    if [ "$clean_data" = "y" ] || [ "$clean_data" = "Y" ]; then
        info "清理 Docker 数据目录..."
        rm -rf /var/lib/docker
        rm -rf /var/lib/containerd
        rm -rf /etc/docker
        ok "Docker 数据已清理"
    else
        warn "Docker 数据目录已保留在 /var/lib/docker"
    fi

    # 删除管理脚本自身
    rm -f "${MANAGE_CMD}" 2>/dev/null || true

    echo ""
    ok "Docker & Docker Compose 已卸载完成！"
}

# ============================================================
# 选项 4：Docker 迁移工具
# 在线拉取 backup.sh / transfer.sh / restore.sh 执行
# ============================================================
cmd_migrate() {
    local REPO="https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main"

    while true; do
        echo ""
        echo -e "${BOLD}Docker 迁移工具：${NC}"
        line
        echo -e "  ${GREEN}1.${NC} 备份（在旧 VPS 上运行）"
        echo -e "  ${GREEN}2.${NC} 传输（将备份发送到新 VPS）"
        echo -e "  ${GREEN}3.${NC} 还原（在新 VPS 上运行）"
        echo -e "  ${GREEN}0.${NC} 返回主菜单"
        line
        echo ""
        echo -e "  ${BOLD}迁移流程：${NC} 旧VPS备份 → 传输 → 新VPS还原"
        echo ""

        read -p "请输入数字 [0-3]: " migrate_choice
        case $migrate_choice in
            1)
                echo ""
                info "下载并运行备份脚本..."
                curl -sL "${REPO}/backup.sh" -o /tmp/sumingdk-backup.sh 2>/dev/null
                chmod +x /tmp/sumingdk-backup.sh
                echo ""
                echo -e "  ${BOLD}备份模式：${NC}"
                echo -e "  ${GREEN}a.${NC} 交互模式（选择要备份的服务）"
                echo -e "  ${GREEN}b.${NC} 全部备份"
                echo ""
                read -p "选择模式 [a/b]: " bmode
                case "$bmode" in
                    b|B) bash /tmp/sumingdk-backup.sh --all ;;
                    *)   bash /tmp/sumingdk-backup.sh ;;
                esac
                ;;
            2)
                echo ""
                info "下载并运行传输脚本..."
                curl -sL "${REPO}/transfer.sh" -o /tmp/sumingdk-transfer.sh 2>/dev/null
                chmod +x /tmp/sumingdk-transfer.sh
                echo ""
                # 自动检测最新备份文件
                local bf=""
                local latest_backup
                latest_backup=$(ls -t /tmp/sumingdk-backup-*.tar.gz 2>/dev/null | head -1)
                if [ -n "$latest_backup" ]; then
                    local bsize
                    bsize=$(du -h "$latest_backup" 2>/dev/null | cut -f1)
                    echo -e "  检测到最新备份: ${CYAN}${latest_backup}${NC} (${bsize})"
                    read -p "使用此备份？(Y/n): " use_latest
                    if [ "$use_latest" != "n" ] && [ "$use_latest" != "N" ]; then
                        bf="$latest_backup"
                    else
                        read -p "请输入备份文件路径: " bf
                    fi
                else
                    read -p "请输入备份文件路径: " bf
                fi
                [ -z "$bf" ] && { error "路径不能为空"; continue; }
                read -p "请输入目标服务器 IP: " tip
                [ -z "$tip" ] && { error "IP 不能为空"; continue; }
                read -p "SSH 端口（默认 22）: " sport
                [ -z "$sport" ] && sport="22"
                bash /tmp/sumingdk-transfer.sh "$bf" "$tip" --port "$sport"
                ;;
            3)
                echo ""
                info "下载并运行还原脚本..."
                curl -sL "${REPO}/restore.sh" -o /tmp/sumingdk-restore.sh 2>/dev/null
                chmod +x /tmp/sumingdk-restore.sh
                echo ""
                # 自动检测最新备份文件
                local rf=""
                local latest_restore
                latest_restore=$(ls -t /tmp/sumingdk-backup-*.tar.gz 2>/dev/null | head -1)
                if [ -n "$latest_restore" ]; then
                    local rsize
                    rsize=$(du -h "$latest_restore" 2>/dev/null | cut -f1)
                    echo -e "  检测到最新备份: ${CYAN}${latest_restore}${NC} (${rsize})"
                    read -p "使用此备份？(Y/n): " use_latest
                    if [ "$use_latest" != "n" ] && [ "$use_latest" != "N" ]; then
                        rf="$latest_restore"
                    else
                        read -p "请输入备份文件路径: " rf
                    fi
                else
                    read -p "请输入备份文件路径: " rf
                fi
                [ -z "$rf" ] && { error "路径不能为空"; continue; }
                bash /tmp/sumingdk-restore.sh "$rf"
                ;;
            0) return 0 ;;
            *) warn "请输入正确的数字"; sleep 1 ;;
        esac
        echo ""
        read -p "$(echo -e ${CYAN}按回车继续...${NC})"
    done
}

# ============================================================
# 交互式主菜单
# ============================================================
show_menu() {
    clear
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║      Docker & Compose 管理菜单               ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    # Docker 状态
    local docker_status=$(get_docker_status)
    case "$docker_status" in
        running)
            local ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
            echo -e "  Docker 状态:  ${GREEN}运行中${NC} (v${ver})"
            ;;
        stopped)
            echo -e "  Docker 状态:  ${YELLOW}已安装但未运行${NC}"
            ;;
        not_installed)
            echo -e "  Docker 状态:  ${RED}未安装${NC}"
            ;;
    esac

    # Compose 状态
    local compose_status=$(get_compose_status)
    case "$compose_status" in
        installed)
            local cver=$(docker compose version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
            echo -e "  Compose 状态: ${GREEN}已安装${NC} (v${cver})"
            ;;
        standalone)
            local cver=$(docker-compose --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
            echo -e "  Compose 状态: ${YELLOW}独立版${NC} (v${cver})"
            ;;
        not_installed)
            echo -e "  Compose 状态: ${RED}未安装${NC}"
            ;;
    esac

    # 运行中的容器数量
    if [ "$docker_status" = "running" ]; then
        local running=$(docker ps -q 2>/dev/null | wc -l)
        echo -e "  运行中容器:   ${CYAN}${running}${NC} 个"
    fi

    echo ""
    line
    echo -e "  ${GREEN}1.${NC} 安装 Docker"
    echo -e "  ${GREEN}2.${NC} 安装 Docker Compose"
    echo -e "  ${GREEN}3.${NC} 管理 Docker & Compose"
    echo -e "  ${GREEN}4.${NC} Docker 迁移工具"
    echo -e "  ${GREEN}5.${NC} 卸载 Docker & Compose"
    echo -e "  ${GREEN}0.${NC} 退出脚本"
    line
    echo ""
}

menu_loop() {
    while true; do
        show_menu
        read -p "请输入数字 [0-5]: " choice
        case $choice in
            1) cmd_install_docker; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            2) cmd_install_compose; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            3) cmd_manage ;;
            4) cmd_migrate ;;
            5) cmd_uninstall; read -p "$(echo -e ${CYAN}按回车继续...${NC})" ;;
            0) echo "已退出！随时输入 docker-manager 重新进入菜单。"; exit 0 ;;
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
    install-docker)   cmd_install_docker ;;
    install-compose)  cmd_install_compose ;;
    manage)           cmd_manage ;;
    migrate)          cmd_migrate ;;
    uninstall)        cmd_uninstall ;;
    status)
        echo ""
        echo -e "  Docker:  $(get_docker_status)"
        echo -e "  Compose: $(get_compose_status)"
        ;;
    *)                menu_loop ;;
esac
