#!/bin/bash
# ============================================================
# sumingdk - Docker 通用迁移工具 · 还原脚本
# 在新 VPS 上运行，从备份包还原所有 Docker 服务
#
# 用法：
#   bash restore.sh <备份文件>
#   bash restore.sh /tmp/sumingdk-backup-xxx.tar.gz
#   bash restore.sh /tmp/sumingdk-backup-xxx.tar.gz --skip-docker
#
# 功能：
#   - 自动安装 Docker（如未安装）
#   - 还原 Compose 项目和独立容器
#   - 还原 Bind Mount 和 Named Volume 数据
#   - 导入数据库（pg_dumpall / mysql / mongorestore）
#   - 启动所有服务
#   - 迁移后自动验证
# ============================================================

set -euo pipefail

# ============================================================
# 全局变量
# ============================================================
VERSION="1.0.0"
BACKUP_FILE=""
BACKUP_DIR=""                    # 解压后的备份目录
LOG_FILE=""
MANIFEST_FILE=""

# 参数
SKIP_DOCKER=false                # 跳过 Docker 安装
SKIP_VERIFY=false                # 跳过迁移后验证

# ============================================================
# 颜色与输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}>>> $1${NC}"; log "INFO" "$1"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; log "OK" "$1"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; log "WARN" "$1"; }
error() { echo -e "${RED}❌ $1${NC}"; log "ERROR" "$1"; }
fatal() { error "$1"; exit 1; }

log() {
    local level="$1" msg="$2"
    if [ -n "$LOG_FILE" ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE"
    fi
}

separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    if [ $# -lt 1 ]; then
        show_help
        exit 1
    fi

    BACKUP_FILE="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-docker)
                SKIP_DOCKER=true
                shift
                ;;
            --skip-verify)
                SKIP_VERIFY=true
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
${BOLD}sumingdk restore${NC} - Docker 服务一键还原工具 v${VERSION}

${BOLD}用法:${NC}
  bash restore.sh <备份文件> [选项]

${BOLD}选项:${NC}
  --skip-docker     跳过 Docker 安装检查
  --skip-verify     跳过迁移后验证
  -h, --help        显示此帮助

${BOLD}示例:${NC}
  bash restore.sh /tmp/sumingdk-backup-20260325_120000.tar.gz
  bash restore.sh /tmp/sumingdk-backup-xxx.tar.gz --skip-docker
EOF
}

# ============================================================
# 安装 Docker
# ============================================================
install_docker() {
    if [ "$SKIP_DOCKER" = true ]; then
        info "跳过 Docker 安装检查"
        return
    fi

    if command -v docker &> /dev/null; then
        ok "Docker 已安装: $(docker --version | head -1)"
        # 确保 Docker 运行中
        if ! systemctl is-active --quiet docker 2>/dev/null; then
            systemctl enable --now docker
        fi
        return
    fi

    info "安装 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker 安装完成"

    # 验证 docker compose
    if docker compose version &> /dev/null; then
        ok "Docker Compose 可用"
    else
        fatal "Docker Compose 不可用"
    fi
}

# ============================================================
# 解压备份
# ============================================================
extract_backup() {
    info "解压备份文件..."

    if [ ! -f "$BACKUP_FILE" ]; then
        fatal "备份文件不存在: ${BACKUP_FILE}"
    fi

    local size
    size=$(du -h "$BACKUP_FILE" | cut -f1)
    echo -e "  备份文件: ${BOLD}${BACKUP_FILE}${NC} (${size})"

    # 解压到同目录
    local extract_dir
    extract_dir=$(dirname "$BACKUP_FILE")
    tar xzf "$BACKUP_FILE" -C "$extract_dir" 2>> /dev/null

    # 找到解压出的目录（名字以 sumingdk-backup- 开头）
    BACKUP_DIR=$(find "$extract_dir" -maxdepth 1 -type d -name "sumingdk-backup-*" | head -1)
    if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
        fatal "无法找到解压后的备份目录"
    fi

    MANIFEST_FILE="${BACKUP_DIR}/manifest.json"
    LOG_FILE="${BACKUP_DIR}/restore.log"

    if [ ! -f "$MANIFEST_FILE" ]; then
        fatal "备份目录中缺少 manifest.json"
    fi

    ok "备份已解压: ${BACKUP_DIR}"

    # 显示备份信息
    local backup_date backup_hostname
    backup_date=$(grep '"date"' "$MANIFEST_FILE" | head -1 | sed 's/.*": "\([^"]*\)".*/\1/')
    backup_hostname=$(grep '"hostname"' "$MANIFEST_FILE" | head -1 | sed 's/.*": "\([^"]*\)".*/\1/')
    echo -e "  备份时间: ${backup_date}"
    echo -e "  来源主机: ${backup_hostname}"
}

# ============================================================
# 从 manifest.json 解析项目（简易 JSON 解析，不依赖 jq）
# 返回格式取决于调用者需要
# ============================================================

# 获取所有 compose 项目信息
get_compose_items() {
    # 解析 manifest 中 type=compose 的条目
    # 输出: name|source_path|archive|db_backup_mode
    awk '
    BEGIN { in_item=0; type=""; name=""; path=""; archive=""; dbmode="" }
    /"type"/ { gsub(/[",]/, ""); type=$2 }
    /"name"/ { gsub(/[",]/, ""); name=$2 }
    /"source_path"/ { gsub(/[",]/, ""); path=$2 }
    /"archive"/ { gsub(/[",]/, ""); archive=$2 }
    /"db_backup_mode"/ && in_item { gsub(/[",]/, ""); dbmode=$2 }
    /\{/ { in_item=1; type=""; name=""; path=""; archive=""; dbmode="" }
    /\}/ {
        if (type == "compose" && name != "") {
            print name "|" path "|" archive "|" dbmode
        }
        in_item=0
    }
    ' "$MANIFEST_FILE"
}

# 获取所有独立容器信息
get_standalone_items() {
    # 输出: name|image|compose_file|bind_mounts|db_type|db_backup_mode
    awk '
    BEGIN { in_item=0 }
    /"type"/ { gsub(/[",]/, ""); type=$2 }
    /"name"/ { gsub(/[",]/, ""); name=$2 }
    /"image"/ { gsub(/[",]/, ""); image=$2 }
    /"compose_file"/ { gsub(/[",]/, ""); cf=$2 }
    /"bind_mounts"/ { gsub(/[",]/, ""); bm=$2 }
    /"db_type"/ { gsub(/[",]/, ""); dbt=$2 }
    /"db_backup_mode"/ && in_item { gsub(/[",]/, ""); dbm=$2 }
    /\{/ { in_item=1; type=""; name=""; image=""; cf=""; bm=""; dbt=""; dbm="" }
    /\}/ {
        if (type == "standalone" && name != "") {
            print name "|" image "|" cf "|" bm "|" dbt "|" dbm
        }
        in_item=0
    }
    ' "$MANIFEST_FILE"
}

# ============================================================
# 还原 Compose 项目
# ============================================================
restore_compose_project() {
    local name="$1"
    local source_path="$2"
    local archive="$3"
    local db_mode="$4"

    separator
    info "还原 Compose 项目: ${BOLD}${name}${NC}"
    info "  目标路径: ${source_path}"

    local archive_path="${BACKUP_DIR}/${archive}"
    if [ ! -f "$archive_path" ]; then
        error "  备份文件不存在: ${archive_path}"
        return 1
    fi

    # 还原项目目录
    info "  解压项目目录..."
    local parent_dir
    parent_dir=$(dirname "$source_path")
    mkdir -p "$parent_dir"
    tar xzf "$archive_path" -C "$parent_dir" 2>> "$LOG_FILE"
    ok "  目录已还原"

    # 检查是否有数据库导出需要导入
    local db_dir="${BACKUP_DIR}/compose/${name}/databases"
    if [ -d "$db_dir" ] && [ "$(ls -A "$db_dir" 2>/dev/null)" ]; then
        info "  检测到数据库导出，将在服务启动后导入"
    fi

    # 启动服务
    info "  启动服务..."
    cd "$source_path" && docker compose up -d 2>> "$LOG_FILE"

    # 等待容器就绪
    info "  等待容器就绪..."
    sleep 10

    # 导入数据库
    if [ -d "$db_dir" ] && [ "$db_mode" = "native" ]; then
        for dump_file in "$db_dir"/*; do
            [ -f "$dump_file" ] || continue
            local dump_name
            dump_name=$(basename "$dump_file")

            # 从文件名提取容器名和数据库类型
            # 格式: container_dbtype.sql
            local db_container db_type
            db_type=$(echo "$dump_name" | sed 's/.*_\(.*\)\.sql/\1/')
            db_container=$(echo "$dump_name" | sed "s/_${db_type}\.sql//")

            info "  导入 ${db_type} 数据库 (${db_container})..."

            # 等待数据库容器就绪（先检查 Running，再检查 Healthy）
            local wait_count=0
            while [ $wait_count -lt 60 ]; do
                local running health
                running=$(docker inspect "$db_container" --format '{{.State.Running}}' 2>/dev/null || echo "false")
                health=$(docker inspect "$db_container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' 2>/dev/null || echo "none")
                
                # 容器在运行且（无 healthcheck 或 healthy）就可以开始导入
                if [ "$running" = "true" ] && { [ "$health" = "healthy" ] || [ "$health" = "no-healthcheck" ]; }; then
                    break
                fi
                sleep 2
                wait_count=$((wait_count + 1))
            done
            
            if [ $wait_count -ge 60 ]; then
                warn "  等待容器 ${db_container} 就绪超时，尝试强制导入..."
            fi

            import_database "$db_container" "$db_type" "$dump_file"
        done
    fi

    ok "  Compose 项目 ${name} 还原完成"
}

# ============================================================
# 还原独立容器
# ============================================================
restore_standalone_container() {
    local name="$1"
    local image="$2"
    local compose_file="$3"
    local bind_mounts="$4"
    local db_type="$5"
    local db_mode="$6"

    separator
    info "还原独立容器: ${BOLD}${name}${NC}"
    info "  镜像: ${image}"

    local container_dir="${BACKUP_DIR}/standalone/${name}"

    # 还原 Bind Mount 数据
    if [ -n "$bind_mounts" ]; then
        info "  还原 Bind Mount 数据..."
        local mount_index=0
        IFS=',' read -ra mounts <<< "$bind_mounts"
        for mount_path in "${mounts[@]}"; do
            mount_path=$(echo "$mount_path" | tr -d ' ')
            [ -z "$mount_path" ] && continue
            mount_index=$((mount_index + 1))

            local bind_archive="${container_dir}/bind_mount_${mount_index}.tar.gz"
            if [ -f "$bind_archive" ]; then
                local parent_dir
                parent_dir=$(dirname "$mount_path")
                mkdir -p "$parent_dir"
                tar xzf "$bind_archive" -C "$parent_dir" 2>> "$LOG_FILE"
                ok "    已还原: ${mount_path}"
            else
                warn "    未找到备份: ${bind_archive}"
            fi
        done
    fi

    # 还原 Named Volume 数据
    local vol_files
    vol_files=$(find "$container_dir" -name "volume_*.tar.gz" 2>/dev/null || true)
    if [ -n "$vol_files" ]; then
        info "  还原 Named Volume 数据..."
        for vol_archive in $vol_files; do
            local vol_name
            vol_name=$(basename "$vol_archive" .tar.gz | sed 's/^volume_//')
            info "    创建并还原 volume: ${vol_name}"

            docker volume create "$vol_name" 2>> "$LOG_FILE"
            docker run --rm \
                -v "${vol_name}:/target" \
                -v "$(dirname "$vol_archive"):/backup:ro" \
                busybox sh -c "cd /target && tar xzf /backup/$(basename "$vol_archive")" 2>> "$LOG_FILE"

            ok "    已还原: ${vol_name}"
        done
    fi

    # 复制 compose 文件并启动
    local compose_path="${container_dir}/docker-compose.yml"
    if [ -f "$compose_path" ]; then
        local target_compose_dir="/root/${name}"
        mkdir -p "$target_compose_dir"
        cp "$compose_path" "${target_compose_dir}/docker-compose.yml"

        # 检查并创建 compose 文件中声明的 external 网络
        local ext_nets
        ext_nets=$(grep -B1 "external: true" "${target_compose_dir}/docker-compose.yml" 2>/dev/null | grep -v 'external' | sed 's/^[[:space:]]*//' | sed 's/:$//' | grep -v '^$' || true)
        if [ -n "$ext_nets" ]; then
            while IFS= read -r net; do
                [ -z "$net" ] && continue
                if ! docker network inspect "$net" &>/dev/null; then
                    info "  创建网络: ${net}"
                    docker network create "$net" 2>> "$LOG_FILE" || true
                fi
            done <<< "$ext_nets"
        fi

        info "  启动容器..."
        cd "$target_compose_dir" && docker compose up -d 2>> "$LOG_FILE"

        # 如果有数据库导出，导入
        local db_dir="${container_dir}/databases"
        if [ -d "$db_dir" ] && [ "$db_type" != "none" ] && [ "$db_mode" = "native" ]; then
            sleep 10
            for dump_file in "$db_dir"/*; do
                [ -f "$dump_file" ] || continue
                import_database "$name" "$db_type" "$dump_file"
            done
        fi

        ok "  独立容器 ${name} 还原完成"
    else
        error "  缺少 docker-compose.yml"
    fi
}

# ============================================================
# 导入数据库
# 参数: $1 = 容器名, $2 = 数据库类型, $3 = dump 文件路径
# ============================================================
import_database() {
    local container="$1"
    local db_type="$2"
    local dump_file="$3"

    info "  导入 ${db_type} 数据库..."

    # 从容器获取凭据
    local envs user password
    envs=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)

    case "$db_type" in
        postgresql)
            user=$(echo "$envs" | grep '^POSTGRES_USER=' | cut -d= -f2-)
            [ -z "$user" ] && user="postgres"
            # pg_dumpall 的输出需要通过 psql 还原，指定 -d postgres 作为初始连接库
            docker exec -i "$container" psql -U "$user" -d postgres < "$dump_file" 2>> "$LOG_FILE"
            ;;
        mysql)
            password=$(echo "$envs" | grep '^MYSQL_ROOT_PASSWORD=' | cut -d= -f2-)
            local mysql_auth="-uroot"
            [ -n "$password" ] && mysql_auth="${mysql_auth} -p${password}"
            docker exec -i "$container" mysql ${mysql_auth} < "$dump_file" 2>> "$LOG_FILE"
            ;;
        mariadb)
            password=$(echo "$envs" | grep '^MARIADB_ROOT_PASSWORD=' | cut -d= -f2-)
            [ -z "$password" ] && password=$(echo "$envs" | grep '^MYSQL_ROOT_PASSWORD=' | cut -d= -f2-)
            local maria_auth="-uroot"
            [ -n "$password" ] && maria_auth="${maria_auth} -p${password}"
            # mariadb 命令可能不存在，fallback 到 mysql
            local import_cmd="mariadb"
            docker exec "$container" which mariadb &>/dev/null || import_cmd="mysql"
            docker exec -i "$container" $import_cmd ${maria_auth} < "$dump_file" 2>> "$LOG_FILE"
            ;;
        mongodb)
            user=$(echo "$envs" | grep '^MONGO_INITDB_ROOT_USERNAME=' | cut -d= -f2-)
            password=$(echo "$envs" | grep '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d= -f2-)
            if [ -n "$user" ] && [ -n "$password" ]; then
                docker exec -i "$container" mongorestore \
                    --username "$user" --password "$password" \
                    --authenticationDatabase admin --archive < "$dump_file" 2>> "$LOG_FILE"
            else
                docker exec -i "$container" mongorestore --archive < "$dump_file" 2>> "$LOG_FILE"
            fi
            ;;
    esac

    ok "  数据库导入完成"
}

# ============================================================
# 迁移后验证
# ============================================================
verify_migration() {
    if [ "$SKIP_VERIFY" = true ]; then
        info "跳过迁移后验证"
        return
    fi

    separator
    info "开始迁移后验证..."
    echo ""

    local total=0 passed=0 failed=0

    # 检查所有容器状态
    echo -e "  ${BOLD}容器状态检查：${NC}"
    echo ""

    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""

    # 逐个检查容器是否正常运行
    local containers
    containers=$(docker ps -a --format '{{.Names}}|{{.Status}}|{{.Ports}}')

    while IFS='|' read -r name status ports; do
        [ -z "$name" ] && continue
        total=$((total + 1))

        if echo "$status" | grep -qiE "^Up"; then
            # 容器运行中
            if echo "$status" | grep -qi "unhealthy"; then
                echo -e "  ${YELLOW}⚠️  ${name}: 运行中但不健康${NC}"
                failed=$((failed + 1))
            else
                echo -e "  ${GREEN}✅ ${name}: 正常运行${NC}"
                passed=$((passed + 1))

                # 如果有暴露端口，尝试 curl 检测
                if [ -n "$ports" ]; then
                    # 提取第一个映射端口
                    local host_port
                    host_port=$(echo "$ports" | grep -o '0\.0\.0\.0:[0-9]*' | head -1 | sed 's/0\.0\.0\.0://')
                    if [ -n "$host_port" ]; then
                        local http_code
                        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                            --connect-timeout 5 \
                            "http://localhost:${host_port}" 2>/dev/null || echo "000")
                        if [ "$http_code" != "000" ]; then
                            echo -e "       端口 ${host_port}: HTTP ${http_code}"
                        fi
                    fi
                fi
            fi
        else
            echo -e "  ${RED}❌ ${name}: ${status}${NC}"
            failed=$((failed + 1))
        fi
    done <<< "$containers"

    # 汇总
    echo ""
    separator
    if [ $failed -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}验证结果: 全部通过 (${passed}/${total})${NC}"
    else
        echo -e "  ${YELLOW}${BOLD}验证结果: ${passed} 通过, ${failed} 失败 (共 ${total})${NC}"
        echo ""
        echo -e "  查看失败容器日志:"
        docker ps -a --filter "status=exited" --format '{{.Names}}' | while read -r name; do
            echo -e "    ${CYAN}docker logs ${name} --tail 20${NC}"
        done
    fi
    separator
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_args "$@"

    echo ""
    separator
    echo -e "${BOLD}  sumingdk 还原工具 v${VERSION}${NC}"
    echo -e "  主机: $(hostname)"
    echo -e "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    separator
    echo ""

    # 1. 安装 Docker
    install_docker

    # 2. 解压备份
    extract_backup

    # 3. 还原 Compose 项目
    local compose_items
    compose_items=$(get_compose_items)
    if [ -n "$compose_items" ]; then
        while IFS='|' read -r name source_path archive db_mode; do
            restore_compose_project "$name" "$source_path" "$archive" "$db_mode"
        done <<< "$compose_items"
    fi

    # 4. 还原独立容器
    local standalone_items
    standalone_items=$(get_standalone_items)
    if [ -n "$standalone_items" ]; then
        while IFS='|' read -r name image cf bm dbt dbm; do
            restore_standalone_container "$name" "$image" "$cf" "$bm" "$dbt" "$dbm"
        done <<< "$standalone_items"
    fi

    # 5. 等待所有服务稳定
    info "等待服务稳定..."
    sleep 10

    # 6. 迁移后验证
    verify_migration

    # 7. 完成
    echo ""
    echo -e "${GREEN}${BOLD}🎉 还原完成！${NC}"
    echo ""
    echo -e "  日志文件: ${LOG_FILE}"
    echo ""
    echo -e "  ${BOLD}后续操作提醒：${NC}"
    echo -e "  1. 如有域名，修改 DNS A 记录指向新 IP"
    echo -e "  2. 检查防火墙是否放行所需端口"
    echo -e "  3. 确认数据完整后再关停旧服务器"
    echo ""
}

main "$@"
