#!/bin/bash
# ============================================================
# sumingdk - Docker 通用迁移工具 · 备份脚本
# 在旧 VPS 上运行，自动检测并备份所有 Docker 服务
#
# 用法：
#   bash backup.sh                          # 交互模式
#   bash backup.sh --all                    # 备份所有
#   bash backup.sh --exclude web,komari     # 排除指定容器
#   bash backup.sh --raw                    # 数据库用文件级备份
#   bash backup.sh --output /path/to/dir    # 指定输出目录
#
# 功能：
#   - 自动检测 docker compose 项目和独立容器
#   - 支持 bind mount（tar 直接打包）和 named volume（busybox 打包）
#   - 数据库自动检测并原生导出（pg_dump/mysqldump/mongodump）
#   - 独立容器自动反向生成 docker-compose.yml
#   - 交互式选择要迁移的服务
#   - 完整日志记录
# ============================================================

set -euo pipefail

# ============================================================
# 全局变量
# ============================================================
VERSION="1.0.0"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)
BACKUP_NAME="sumingdk-backup-${TIMESTAMP}"
OUTPUT_DIR="/tmp"
BACKUP_DIR=""                    # 实际备份目录，在 main 中初始化
LOG_FILE=""                      # 日志文件路径
MANIFEST_FILE=""                 # 清单文件路径

# 参数默认值
MODE="interactive"               # interactive | all
EXCLUDE_LIST=""                  # 逗号分隔的排除容器名
DB_BACKUP_MODE="native"          # native | raw
STOP_BEFORE_BACKUP=false         # 是否在备份前停止容器
CRON_SCHEDULE=""                 # 定时任务表达式
KEEP_DAYS=0                      # 历史备份保留天数/份数
WEBHOOK_URL=""                   # Webhook 通知地址

# 存储检测结果的临时文件
COMPOSE_PROJECTS_FILE=""
STANDALONE_CONTAINERS_FILE=""
SELECTED_COMPOSE_FILE=""
SELECTED_STANDALONE_FILE=""

# ============================================================
# 颜色与输出工具
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# 带颜色的输出函数，同时写入日志
info()  { echo -e "${CYAN}>>> $1${NC}"; log "INFO" "$1"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; log "OK" "$1"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; log "WARN" "$1"; }
error() { echo -e "${RED}❌ $1${NC}"; log "ERROR" "$1"; }
fatal() { 
    error "$1"
    if [ -n "$WEBHOOK_URL" ]; then
        local payload="{\"text\": \"❌ 服务器 [${HOSTNAME}] Docker 备份失败\\n时间: $(date '+%Y-%m-%d %H:%M:%S')\\n错误: $1\"}"
        curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" > /dev/null || true
    fi
    exit 1
}

# 日志记录函数：写入日志文件，带时间戳和级别
log() {
    local level="$1"
    local msg="$2"
    if [ -n "$LOG_FILE" ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $msg" >> "$LOG_FILE"
    fi
}

# 分隔线
separator() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================================
# 参数解析
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)
                MODE="all"
                shift
                ;;
            --exclude)
                EXCLUDE_LIST="$2"
                shift 2
                ;;
            --raw)
                DB_BACKUP_MODE="raw"
                shift
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --stop)
                STOP_BEFORE_BACKUP=true
                shift
                ;;
            --cron)
                CRON_SCHEDULE="$2"
                shift 2
                ;;
            --keep)
                KEEP_DAYS="$2"
                shift 2
                ;;
            --webhook)
                WEBHOOK_URL="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                fatal "未知参数: $1，使用 --help 查看帮助"
                ;;
        esac
    done
}

show_help() {
    cat << EOF
${BOLD}sumingdk backup${NC} - Docker 服务一键备份工具 v${VERSION}

${BOLD}用法:${NC}
  bash backup.sh [选项]

${BOLD}选项:${NC}
  --all                    备份所有检测到的服务（跳过交互选择）
  --exclude name1,name2    排除指定的容器/项目名（逗号分隔）
  --raw                    数据库使用文件级备份而非原生导出
  --stop                   备份前先停止容器（保证数据一致性）
  --output /path           指定备份输出目录（默认 /tmp）
  --cron "表达式"          生成定时任务实现自动备份 (如 "0 3 * * *")
  --keep N                 自动清理旧文件, 只保留最近 N 份备份包
  --webhook URL            发送飞书/钉钉等 Webhook 成功或失败通知
  -h, --help               显示此帮助信息

${BOLD}示例:${NC}
  bash backup.sh                              # 交互模式，选择要备份的服务
  bash backup.sh --all                        # 备份全部
  bash backup.sh --all --exclude komari       # 备份全部，排除 komari
  bash backup.sh --all --raw --stop           # 全部 + 文件级数据库备份 + 先停容器

${BOLD}输出:${NC}
  生成 sumingdk-backup-时间戳.tar.gz 备份包，包含：
  - compose 项目目录
  - 独立容器数据和自动生成的 docker-compose.yml
  - 数据库导出文件
  - Named Volume 备份
  - manifest.json 清单文件
EOF
}

# ============================================================
# 环境检查
# ============================================================
check_environment() {
    info "检查系统环境..."

    # 必须是 root
    [ "$(id -u)" -ne 0 ] && fatal "请使用 root 用户运行此脚本"

    # 检查 Docker
    if ! command -v docker &> /dev/null; then
        fatal "Docker 未安装"
    fi

    # 检查 Docker 是否运行
    if ! docker info &> /dev/null 2>&1; then
        fatal "Docker 未运行，请先启动 Docker"
    fi

    # 检查 docker compose
    if ! docker compose version &> /dev/null 2>&1; then
        warn "docker compose 不可用，将只处理独立容器"
    fi

    # 检查输出目录磁盘空间
    local available_mb
    available_mb=$(df -m "$OUTPUT_DIR" | tail -1 | awk '{print $4}')
    if [ "$available_mb" -lt 500 ]; then
        warn "输出目录 ${OUTPUT_DIR} 可用空间仅 ${available_mb}MB，可能不足"
    fi

    ok "环境检查通过"
}

# ============================================================
# 检测 Docker Compose 项目
# 返回格式：每行一个 "项目名|配置文件路径|容器数"
# ============================================================
detect_compose_projects() {
    info "检测 Docker Compose 项目..."

    COMPOSE_PROJECTS_FILE=$(mktemp)

    # 使用 docker compose ls 获取所有项目
    if docker compose ls --format json 2>/dev/null | head -1 | grep -q '{'; then
        # JSON 格式输出
        docker compose ls --format json 2>/dev/null | while IFS= read -r line; do
            local name config_files status
            name=$(echo "$line" | sed 's/.*"Name":"\([^"]*\)".*/\1/')
            config_files=$(echo "$line" | sed 's/.*"ConfigFiles":"\([^"]*\)".*/\1/')
            status=$(echo "$line" | sed 's/.*"Status":"\([^"]*\)".*/\1/')
            # 提取容器数（从 "running(2)" 中取出 2）
            local count
            count=$(echo "$status" | grep -o '[0-9]*' | head -1)
            [ -z "$count" ] && count="?"
            echo "${name}|${config_files}|${count}" >> "$COMPOSE_PROJECTS_FILE"
        done
    else
        # 表格格式输出（fallback）
        docker compose ls 2>/dev/null | tail -n +2 | while IFS= read -r line; do
            local name status config
            name=$(echo "$line" | awk '{print $1}')
            status=$(echo "$line" | awk '{print $2}')
            config=$(echo "$line" | awk '{print $3}')
            local count
            count=$(echo "$status" | grep -o '[0-9]*' | head -1)
            [ -z "$count" ] && count="?"
            echo "${name}|${config}|${count}" >> "$COMPOSE_PROJECTS_FILE"
        done
    fi

    local project_count
    project_count=$(wc -l < "$COMPOSE_PROJECTS_FILE" 2>/dev/null || echo "0")
    ok "检测到 ${project_count} 个 Compose 项目"
}

# ============================================================
# 检测独立容器（不属于任何 compose 项目的容器）
# 返回格式：每行一个 "容器名|镜像名|端口|状态"
# ============================================================
detect_standalone_containers() {
    info "检测独立容器..."

    STANDALONE_CONTAINERS_FILE=$(mktemp)

    # 获取所有 compose 项目管理的容器名
    local compose_containers
    compose_containers=$(mktemp)
    while IFS='|' read -r name config count; do
        local dir
        dir=$(dirname "$config")
        cd "$dir" 2>/dev/null && docker compose ps --format '{{.Name}}' 2>/dev/null >> "$compose_containers" || true
    done < "$COMPOSE_PROJECTS_FILE"

    # 遍历所有容器，找出不在任何 compose 项目中的
    docker ps -a --format '{{.Names}}|{{.Image}}|{{.Ports}}|{{.Status}}' | while IFS='|' read -r name image ports status; do
        # 检查是否在 compose 管理中
        if ! grep -qx "$name" "$compose_containers" 2>/dev/null; then
            echo "${name}|${image}|${ports}|${status}" >> "$STANDALONE_CONTAINERS_FILE"
        fi
    done

    rm -f "$compose_containers"

    local standalone_count
    standalone_count=$(wc -l < "$STANDALONE_CONTAINERS_FILE" 2>/dev/null || echo "0")
    ok "检测到 ${standalone_count} 个独立容器"
}

# ============================================================
# 交互模式：让用户选择要备份的服务
# ============================================================
interactive_select() {
    SELECTED_COMPOSE_FILE=$(mktemp)
    SELECTED_STANDALONE_FILE=$(mktemp)

    separator
    echo -e "${BOLD}📋 检测到以下 Docker 服务：${NC}"
    echo ""

    local index=0
    local items=()

    # 列出 compose 项目
    if [ -s "$COMPOSE_PROJECTS_FILE" ]; then
        echo -e "${BOLD}  Compose 项目：${NC}"
        while IFS='|' read -r name config count; do
            index=$((index + 1))
            items+=("compose|${name}|${config}")
            echo -e "    ${GREEN}[${index}]${NC} ${BOLD}${name}${NC} (${count} 个容器) — ${config}"
        done < "$COMPOSE_PROJECTS_FILE"
        echo ""
    fi

    # 列出独立容器
    if [ -s "$STANDALONE_CONTAINERS_FILE" ]; then
        echo -e "${BOLD}  独立容器：${NC}"
        while IFS='|' read -r name image ports status; do
            index=$((index + 1))
            items+=("standalone|${name}|${image}")
            local port_display="${ports:-无端口}"
            echo -e "    ${GREEN}[${index}]${NC} ${BOLD}${name}${NC} (${image}) — ${port_display}"
        done < "$STANDALONE_CONTAINERS_FILE"
        echo ""
    fi

    if [ "$index" -eq 0 ]; then
        fatal "未检测到任何 Docker 服务"
    fi

    separator
    echo ""
    echo -e "输入要备份的编号（逗号或空格分隔，${BOLD}a${NC} = 全选，${BOLD}q${NC} = 取消）："
    read -p "> " selection

    [ "$selection" = "q" ] && exit 0

    # 解析用户选择
    local selected_indices=()
    if [ "$selection" = "a" ] || [ "$selection" = "A" ]; then
        # 全选
        for i in $(seq 1 $index); do
            selected_indices+=("$i")
        done
    else
        # 解析逗号和空格分隔的编号
        IFS=', ' read -ra selected_indices <<< "$selection"
    fi

    # 将选择写入对应文件
    for idx in "${selected_indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        [ -z "$idx" ] && continue
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$index" ] 2>/dev/null; then
            warn "忽略无效编号: $idx"
            continue
        fi
        local item="${items[$((idx - 1))]}"
        local type=$(echo "$item" | cut -d'|' -f1)
        local name=$(echo "$item" | cut -d'|' -f2)
        local extra=$(echo "$item" | cut -d'|' -f3)

        if [ "$type" = "compose" ]; then
            echo "${name}|${extra}" >> "$SELECTED_COMPOSE_FILE"
        else
            echo "${name}|${extra}" >> "$SELECTED_STANDALONE_FILE"
        fi
    done

    local sc=$(wc -l < "$SELECTED_COMPOSE_FILE" 2>/dev/null || echo "0")
    local ss=$(wc -l < "$SELECTED_STANDALONE_FILE" 2>/dev/null || echo "0")
    echo ""
    ok "已选择 ${sc} 个 Compose 项目 + ${ss} 个独立容器"
}

# ============================================================
# 应用排除列表
# ============================================================
apply_excludes() {
    if [ -z "$EXCLUDE_LIST" ]; then
        return
    fi

    info "应用排除列表: ${EXCLUDE_LIST}"

    IFS=',' read -ra excludes <<< "$EXCLUDE_LIST"
    for exclude in "${excludes[@]}"; do
        exclude=$(echo "$exclude" | tr -d ' ')
        # 从 compose 项目中排除
        if [ -f "$SELECTED_COMPOSE_FILE" ]; then
            sed -i "/^${exclude}|/d" "$SELECTED_COMPOSE_FILE"
        fi
        # 从独立容器中排除
        if [ -f "$SELECTED_STANDALONE_FILE" ]; then
            sed -i "/^${exclude}|/d" "$SELECTED_STANDALONE_FILE"
        fi
    done

    ok "排除完成"
}

# ============================================================
# 检测数据库类型：根据镜像名判断
# 参数: $1 = 镜像名
# 返回: postgresql / mysql / mariadb / mongodb / redis / none
# ============================================================
detect_db_type() {
    local image="$1"
    case "$image" in
        postgres*|pg*)       echo "postgresql" ;;
        mysql*)              echo "mysql" ;;
        mariadb*)            echo "mariadb" ;;
        mongo*)              echo "mongodb" ;;
        redis*)              echo "redis" ;;
        *)                   echo "none" ;;
    esac
}

# ============================================================
# 从容器环境变量中提取数据库凭据
# 参数: $1 = 容器名, $2 = 数据库类型
# 输出: user|password|dbname
# ============================================================
get_db_credentials() {
    local container="$1"
    local db_type="$2"
    local user="" password="" dbname=""

    # 获取容器所有环境变量
    local envs
    envs=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}')

    case "$db_type" in
        postgresql)
            user=$(echo "$envs" | grep '^POSTGRES_USER=' | cut -d= -f2-)
            password=$(echo "$envs" | grep '^POSTGRES_PASSWORD=' | cut -d= -f2-)
            dbname=$(echo "$envs" | grep '^POSTGRES_DB=' | cut -d= -f2-)
            [ -z "$user" ] && user="postgres"
            ;;
        mysql|mariadb)
            user="root"
            password=$(echo "$envs" | grep '^MYSQL_ROOT_PASSWORD=' | cut -d= -f2-)
            if [ -z "$password" ]; then
                password=$(echo "$envs" | grep '^MARIADB_ROOT_PASSWORD=' | cut -d= -f2-)
            fi
            ;;
        mongodb)
            user=$(echo "$envs" | grep '^MONGO_INITDB_ROOT_USERNAME=' | cut -d= -f2-)
            password=$(echo "$envs" | grep '^MONGO_INITDB_ROOT_PASSWORD=' | cut -d= -f2-)
            ;;
    esac

    echo "${user}|${password}|${dbname}"
}

# ============================================================
# 原生方式导出数据库
# 参数: $1 = 容器名, $2 = 数据库类型, $3 = 导出文件路径
# ============================================================
backup_database_native() {
    local container="$1"
    local db_type="$2"
    local dump_file="$3"

    local creds
    creds=$(get_db_credentials "$container" "$db_type")
    local user password dbname
    IFS='|' read -r user password dbname <<< "$creds"

    info "  导出 ${db_type} 数据库 (${container})..."
    log "INFO" "数据库凭据: user=${user}, db=${dbname}"

    case "$db_type" in
        postgresql)
            # -c: 生成 DROP 语句，还原时先清库再创建，避免冲突
            docker exec "$container" pg_dumpall -c -U "$user" > "$dump_file" 2>> "$LOG_FILE"
            ;;
        mysql)
            # --single-transaction: 保证 InnoDB 数据一致性（不锁表）
            # --routines --triggers: 导出存储过程和触发器
            local mysql_auth="-u${user}"
            [ -n "$password" ] && mysql_auth="${mysql_auth} -p${password}"
            docker exec "$container" mysqldump --all-databases \
                ${mysql_auth} --single-transaction --routines --triggers \
                > "$dump_file" 2>> "$LOG_FILE"
            ;;
        mariadb)
            local maria_auth="-u${user}"
            [ -n "$password" ] && maria_auth="${maria_auth} -p${password}"
            # mariadb-dump 可能不存在，fallback 到 mysqldump
            local dump_cmd="mariadb-dump"
            docker exec "$container" which mariadb-dump &>/dev/null || dump_cmd="mysqldump"
            docker exec "$container" $dump_cmd --all-databases \
                ${maria_auth} --single-transaction --routines --triggers \
                > "$dump_file" 2>> "$LOG_FILE"
            ;;
        mongodb)
            if [ -n "$user" ] && [ -n "$password" ]; then
                docker exec "$container" mongodump \
                    --username "$user" --password "$password" \
                    --authenticationDatabase admin --archive > "$dump_file" 2>> "$LOG_FILE"
            else
                docker exec "$container" mongodump --archive > "$dump_file" 2>> "$LOG_FILE"
            fi
            ;;
        redis)
            # Redis 触发持久化，等待完成后打包 data 目录
            docker exec "$container" redis-cli BGSAVE 2>> "$LOG_FILE" || true
            # 等待 BGSAVE 完成
            local bgsave_wait=0
            while [ $bgsave_wait -lt 30 ]; do
                local bg_status
                bg_status=$(docker exec "$container" redis-cli LASTSAVE 2>/dev/null || echo "")
                sleep 1
                local bg_status2
                bg_status2=$(docker exec "$container" redis-cli LASTSAVE 2>/dev/null || echo "")
                [ "$bg_status" != "$bg_status2" ] || break
                bgsave_wait=$((bgsave_wait + 1))
            done
            ;;
    esac

    if [ -f "$dump_file" ] && [ -s "$dump_file" ]; then
        local size
        size=$(du -h "$dump_file" | cut -f1)
        ok "  数据库导出完成: ${size}"
    elif [ "$db_type" = "redis" ]; then
        ok "  Redis BGSAVE 已触发"
    else
        warn "  数据库导出文件为空或不存在"
    fi
}

# ============================================================
# 备份 Bind Mount 目录
# 参数: $1 = 源目录, $2 = 目标 tar.gz 文件
# ============================================================
backup_bind_mount() {
    local source_dir="$1"
    local target_file="$2"

    if [ ! -d "$source_dir" ]; then
        warn "  目录不存在，跳过: ${source_dir}"
        return 1
    fi

    tar czf "$target_file" -C "$(dirname "$source_dir")" "$(basename "$source_dir")" 2>> "$LOG_FILE"

    local size
    size=$(du -h "$target_file" | cut -f1)
    log "INFO" "Bind mount 备份: ${source_dir} -> ${target_file} (${size})"
}

# ============================================================
# 备份 Named Volume（使用 busybox 容器）
# 参数: $1 = volume 名, $2 = 目标 tar.gz 文件
# ============================================================
backup_named_volume() {
    local volume_name="$1"
    local target_file="$2"
    local target_dir
    target_dir=$(dirname "$target_file")

    docker run --rm \
        -v "${volume_name}:/source:ro" \
        -v "${target_dir}:/backup" \
        busybox tar czf "/backup/$(basename "$target_file")" -C /source . 2>> "$LOG_FILE"

    if [ -f "$target_file" ]; then
        local size
        size=$(du -h "$target_file" | cut -f1)
        log "INFO" "Named volume 备份: ${volume_name} -> ${target_file} (${size})"
    fi
}

# ============================================================
# 从独立容器反向生成 docker-compose.yml
# 参数: $1 = 容器名, $2 = 输出文件路径
# ============================================================
generate_compose_from_container() {
    local container="$1"
    local output_file="$2"

    info "  反向生成 docker-compose.yml (${container})..."

    # 获取容器详细信息
    local image restart_policy network_mode
    image=$(docker inspect "$container" --format '{{.Config.Image}}')
    restart_policy=$(docker inspect "$container" --format '{{.HostConfig.RestartPolicy.Name}}')
    network_mode=$(docker inspect "$container" --format '{{.HostConfig.NetworkMode}}')

    # 获取 entrypoint 和 command（如果与镜像默认不同）
    local entrypoint command
    entrypoint=$(docker inspect "$container" --format '{{join .Config.Entrypoint " "}}' 2>/dev/null || true)
    command=$(docker inspect "$container" --format '{{join .Config.Cmd " "}}' 2>/dev/null || true)

    # 获取端口映射
    local ports
    ports=$(docker inspect "$container" --format '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{.HostPort}}:{{$p}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)

    # 获取环境变量（排除系统变量）
    local envs
    envs=$(docker inspect "$container" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -v '^PATH=' | grep -v '^HOME=' | grep -v '^HOSTNAME=' | grep -v '^LANG=' | grep -v '^LC_ALL=' || true)

    # 获取挂载（bind mount）
    local volumes
    volumes=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}:{{.Destination}}{{if not .RW}}:ro{{end}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)

    # 获取 named volume 挂载
    local named_volumes
    named_volumes=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}:{{.Destination}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)

    # 获取自定义网络
    local networks
    networks=$(docker inspect "$container" --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{"\n"}}{{end}}' 2>/dev/null || true)

    # 开始写 compose 文件
    cat > "$output_file" << EOF
# 由 sumingdk 从容器 ${container} 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
services:
  ${container}:
    image: ${image}
    container_name: ${container}
EOF

    # restart 策略
    if [ -n "$restart_policy" ] && [ "$restart_policy" != "no" ]; then
        echo "    restart: ${restart_policy}" >> "$output_file"
    fi

    # 网络模式
    if [ "$network_mode" = "host" ]; then
        echo "    network_mode: host" >> "$output_file"
    fi

    # entrypoint（如果自定义了）
    if [ -n "$entrypoint" ]; then
        echo "    entrypoint: ${entrypoint}" >> "$output_file"
    fi

    # command（如果自定义了）
    if [ -n "$command" ]; then
        echo "    command: ${command}" >> "$output_file"
    fi

    # 端口
    if [ -n "$ports" ] && [ "$network_mode" != "host" ]; then
        echo "    ports:" >> "$output_file"
        echo "$ports" | while IFS= read -r port; do
            [ -z "$port" ] && continue
            port=$(echo "$port" | sed 's|/tcp||;s|/udp|/udp|')
            echo "      - \"${port}\"" >> "$output_file"
        done
    fi

    # 环境变量
    if [ -n "$envs" ]; then
        echo "    environment:" >> "$output_file"
        echo "$envs" | while IFS= read -r env; do
            [ -z "$env" ] && continue
            echo "      - ${env}" >> "$output_file"
        done
    fi

    # 挂载卷
    if [ -n "$volumes" ] || [ -n "$named_volumes" ]; then
        echo "    volumes:" >> "$output_file"
        if [ -n "$volumes" ]; then
            echo "$volumes" | while IFS= read -r vol; do
                [ -z "$vol" ] && continue
                echo "      - ${vol}" >> "$output_file"
            done
        fi
        if [ -n "$named_volumes" ]; then
            echo "$named_volumes" | while IFS= read -r vol; do
                [ -z "$vol" ] && continue
                echo "      - ${vol}" >> "$output_file"
            done
        fi
    fi

    # 自定义网络（非 host、非 bridge、非 none）
    if [ -n "$networks" ] && [ "$network_mode" != "host" ]; then
        local custom_nets=""
        while IFS= read -r net; do
            [ -z "$net" ] && continue
            # 跳过默认网络
            case "$net" in bridge|host|none) continue ;; esac
            if [ -z "$custom_nets" ]; then
                echo "    networks:" >> "$output_file"
            fi
            echo "      - ${net}" >> "$output_file"
            custom_nets="${custom_nets}${net}\n"
        done <<< "$networks"
    fi

    # 顶层声明: named volumes
    if [ -n "$named_volumes" ]; then
        echo "" >> "$output_file"
        echo "volumes:" >> "$output_file"
        echo "$named_volumes" | while IFS= read -r vol; do
            [ -z "$vol" ] && continue
            local vol_name
            vol_name=$(echo "$vol" | cut -d: -f1)
            echo "  ${vol_name}:" >> "$output_file"
        done
    fi

    # 顶层声明: custom networks
    if [ -n "$custom_nets" ]; then
        echo "" >> "$output_file"
        echo "networks:" >> "$output_file"
        echo -e "$custom_nets" | while IFS= read -r net; do
            [ -z "$net" ] && continue
            echo "  ${net}:" >> "$output_file"
            echo "    external: true" >> "$output_file"
        done
    fi

    ok "  compose 文件已生成: ${output_file}"
}

# ============================================================
# 备份单个 Compose 项目
# 参数: $1 = 项目名, $2 = compose 配置文件路径
# ============================================================
backup_compose_project() {
    local project_name="$1"
    local config_file="$2"
    local project_dir
    project_dir=$(dirname "$config_file")

    separator
    info "备份 Compose 项目: ${BOLD}${project_name}${NC}"
    info "  目录: ${project_dir}"
    info "  配置: ${config_file}"

    local project_backup_dir="${BACKUP_DIR}/compose/${project_name}"
    mkdir -p "$project_backup_dir"

    # 关键顺序：先导出数据库（容器运行中才能导出），再停容器，再打包目录

    # 1. 检测项目中的数据库容器并导出（必须在容器运行时执行）
    local containers
    containers=$(cd "$project_dir" && docker compose ps --format '{{.Name}}|{{.Image}}' 2>/dev/null || true)

    if [ -n "$containers" ]; then
        while IFS='|' read -r cname cimage; do
            [ -z "$cname" ] && continue
            local db_type
            db_type=$(detect_db_type "$cimage")
            if [ "$db_type" != "none" ]; then
                mkdir -p "${project_backup_dir}/databases"
                if [ "$DB_BACKUP_MODE" = "native" ]; then
                    backup_database_native "$cname" "$db_type" \
                        "${project_backup_dir}/databases/${cname}_${db_type}.sql"
                fi
                log "INFO" "数据库容器: ${cname} (${db_type})"
            fi
        done <<< "$containers"
    fi

    # 2. 如果需要停止容器（在数据库导出完成后再停）
    if [ "$STOP_BEFORE_BACKUP" = true ]; then
        info "  停止容器（数据库已导出完成）..."
        cd "$project_dir" && docker compose stop 2>> "$LOG_FILE"
    fi

    # 3. 打包整个项目目录（包含配置文件和 bind mount 数据）
    info "  打包项目目录: ${project_dir}"
    tar czf "${project_backup_dir}/project.tar.gz" \
        -C "$(dirname "$project_dir")" "$(basename "$project_dir")" 2>> "$LOG_FILE"

    local size
    size=$(du -h "${project_backup_dir}/project.tar.gz" | cut -f1)
    ok "  项目备份完成: ${size}"

    # 4. 如果之前停了，重新启动
    if [ "$STOP_BEFORE_BACKUP" = true ]; then
        info "  重新启动容器..."
        cd "$project_dir" && docker compose start 2>> "$LOG_FILE"
    fi

    # 写入 manifest
    cat >> "$MANIFEST_FILE" << EOF
  {
    "type": "compose",
    "name": "${project_name}",
    "source_path": "${project_dir}",
    "config_file": "$(basename "$config_file")",
    "archive": "compose/${project_name}/project.tar.gz",
    "db_backup_mode": "${DB_BACKUP_MODE}"
  },
EOF
}

# ============================================================
# 备份单个独立容器
# 参数: $1 = 容器名, $2 = 镜像名
# ============================================================
backup_standalone_container() {
    local container="$1"
    local image="$2"

    separator
    info "备份独立容器: ${BOLD}${container}${NC}"
    info "  镜像: ${image}"

    local container_backup_dir="${BACKUP_DIR}/standalone/${container}"
    mkdir -p "$container_backup_dir"

    # 检查是否为数据库容器，先导出（必须在容器运行时执行）
    local db_type
    db_type=$(detect_db_type "$image")
    if [ "$db_type" != "none" ] && [ "$DB_BACKUP_MODE" = "native" ]; then
        mkdir -p "${container_backup_dir}/databases"
        backup_database_native "$container" "$db_type" \
            "${container_backup_dir}/databases/${container}_${db_type}.sql"
    fi

    # 如果需要停止容器（在数据库导出完成后再停）
    if [ "$STOP_BEFORE_BACKUP" = true ]; then
        info "  停止容器（数据库已导出）..."
        docker stop "$container" 2>> "$LOG_FILE"
    fi

    # 反向生成 docker-compose.yml（容器停止后也能 inspect）
    generate_compose_from_container "$container" "${container_backup_dir}/docker-compose.yml"

    # 备份 Bind Mount 数据
    local bind_mounts
    bind_mounts=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)

    if [ -n "$bind_mounts" ]; then
        info "  备份 Bind Mount 数据..."
        local mount_index=0
        while IFS= read -r mount_source; do
            [ -z "$mount_source" ] && continue
            mount_index=$((mount_index + 1))
            info "    [${mount_index}] ${mount_source}"
            backup_bind_mount "$mount_source" \
                "${container_backup_dir}/bind_mount_${mount_index}.tar.gz"
        done <<< "$bind_mounts"
    fi

    # 备份 Named Volume 数据
    local named_vols
    named_vols=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)

    if [ -n "$named_vols" ]; then
        info "  备份 Named Volume 数据..."
        while IFS= read -r vol_name; do
            [ -z "$vol_name" ] && continue
            info "    ${vol_name}"
            backup_named_volume "$vol_name" \
                "${container_backup_dir}/volume_${vol_name}.tar.gz"
        done <<< "$named_vols"
    fi

    # 如果之前停了，重新启动
    if [ "$STOP_BEFORE_BACKUP" = true ]; then
        info "  重新启动容器..."
        docker start "$container" 2>> "$LOG_FILE"
    fi

    # 写入 manifest
    local bind_list=""
    if [ -n "$bind_mounts" ]; then
        bind_list=$(echo "$bind_mounts" | tr '\n' ',' | sed 's/,$//')
    fi

    cat >> "$MANIFEST_FILE" << EOF
  {
    "type": "standalone",
    "name": "${container}",
    "image": "${image}",
    "compose_file": "standalone/${container}/docker-compose.yml",
    "bind_mounts": "${bind_list}",
    "db_type": "${db_type}",
    "db_backup_mode": "${DB_BACKUP_MODE}"
  },
EOF

    ok "  独立容器备份完成"
}

# ============================================================
# 生成最终备份包
# ============================================================
finalize_backup() {
    # 关闭 manifest JSON
    # 去掉最后一个逗号并关闭数组
    sed -i '$ s/,$//' "$MANIFEST_FILE"
    echo "]}" >> "$MANIFEST_FILE"

    info "生成最终备份包..."
    local final_archive="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"
    tar czf "$final_archive" -C "$OUTPUT_DIR" "$BACKUP_NAME" 2>> "$LOG_FILE"

    local size
    size=$(du -h "$final_archive" | cut -f1)

    separator
    echo ""
    echo -e "${GREEN}${BOLD}🎉 备份完成！${NC}"
    echo ""
    echo -e "  备份文件: ${BOLD}${final_archive}${NC}"
    echo -e "  文件大小: ${BOLD}${size}${NC}"
    echo -e "  日志文件: ${LOG_FILE}"
    echo ""
    echo -e "下一步：传输到新服务器"
    echo -e "  ${CYAN}bash transfer.sh ${final_archive} <新服务器IP> [--port 端口]${NC}"
    echo ""
    separator
}

# ============================================================
# 备份后清理与通知
# ============================================================
post_backup_tasks() {
    # 1. 自动清理旧备份
    if [ "$KEEP_DAYS" -gt 0 ] 2>/dev/null; then
        info "应用备份留存策略：保留最近 $KEEP_DAYS 份"
        local old_files
        old_files=$(ls -t "${OUTPUT_DIR}"/sumingdk-backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP_DAYS + 1)))
        if [ -n "$old_files" ]; then
            echo "$old_files" | while read -r f; do
                [ -z "$f" ] && continue
                rm -f "$f"
                log "INFO" "已清理旧备份: $f"
            done
            ok "旧备份清理完成"
        else
            info "没有需要清理的旧备份"
        fi
    fi

    # 2. 设置 Cron 定时任务
    if [ -n "$CRON_SCHEDULE" ]; then
        info "设置自动定时备份..."
        local script_path
        if [[ "$0" == *"/tmp/"* ]] || [ ! -f "$0" ]; then
            script_path="/usr/local/bin/sumingdk-backup"
            cp "$0" "$script_path" 2>/dev/null || curl -sL "https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/backup.sh" -o "$script_path"
            chmod +x "$script_path"
        else
            script_path="$(realpath "$0")"
        fi
        
        local cron_cmd="bash ${script_path} --all"
        [ -n "$EXCLUDE_LIST" ] && cron_cmd="${cron_cmd} --exclude ${EXCLUDE_LIST}"
        [ "$DB_BACKUP_MODE" = "raw" ] && cron_cmd="${cron_cmd} --raw"
        [ "$STOP_BEFORE_BACKUP" = true ] && cron_cmd="${cron_cmd} --stop"
        [ "$OUTPUT_DIR" != "/tmp" ] && cron_cmd="${cron_cmd} --output \"${OUTPUT_DIR}\""
        [ "$KEEP_DAYS" -gt 0 ] && cron_cmd="${cron_cmd} --keep ${KEEP_DAYS}"
        [ -n "$WEBHOOK_URL" ] && cron_cmd="${cron_cmd} --webhook \"${WEBHOOK_URL}\""
        
        local tmp_cron
        tmp_cron=$(mktemp)
        crontab -l 2>/dev/null | grep -v "# sumingdk auto backup" > "$tmp_cron" || true
        echo "${CRON_SCHEDULE} ${cron_cmd} > /dev/null 2>&1 # sumingdk auto backup" >> "$tmp_cron"
        crontab "$tmp_cron"
        rm -f "$tmp_cron"
        ok "Cron 定时任务已设置: ${CRON_SCHEDULE}"
    fi

    # 3. Webhook 通知
    if [ -n "$WEBHOOK_URL" ]; then
        info "发送 Webhook 通知..."
        local final_archive="${OUTPUT_DIR}/${BACKUP_NAME}.tar.gz"
        local size="Unknown"
        [ -f "$final_archive" ] && size=$(du -h "$final_archive" | cut -f1)
        
        local payload="{\"text\": \"✅ 服务器 [${HOSTNAME}] Docker 备份完成\\n时间: $(date '+%Y-%m-%d %H:%M:%S')\\n文件: ${BACKUP_NAME}.tar.gz\\n大小: ${size}\"}"
        if curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" > /dev/null; then
            ok "Webhook 通知发送成功"
        else
            warn "Webhook 通知发送失败"
        fi
    fi
}

# ============================================================
# 主流程
# ============================================================
main() {
    parse_args "$@"

    # 初始化备份目录和日志
    BACKUP_DIR="${OUTPUT_DIR}/${BACKUP_NAME}"
    mkdir -p "$BACKUP_DIR"
    LOG_FILE="${BACKUP_DIR}/backup.log"
    MANIFEST_FILE="${BACKUP_DIR}/manifest.json"

    # 写入 manifest 头部
    cat > "$MANIFEST_FILE" << EOF
{
  "version": "${VERSION}",
  "date": "$(date -Iseconds)",
  "hostname": "${HOSTNAME}",
  "db_backup_mode": "${DB_BACKUP_MODE}",
  "items": [
EOF

    echo ""
    separator
    echo -e "${BOLD}  sumingdk 备份工具 v${VERSION}${NC}"
    echo -e "  主机: ${HOSTNAME}"
    echo -e "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    separator
    echo ""

    # 1. 环境检查
    check_environment

    # 2. 检测服务
    detect_compose_projects
    detect_standalone_containers

    # 3. 选择要备份的服务
    if [ "$MODE" = "interactive" ]; then
        interactive_select
    else
        # all 模式：全选
        SELECTED_COMPOSE_FILE=$(mktemp)
        SELECTED_STANDALONE_FILE=$(mktemp)
        if [ -s "$COMPOSE_PROJECTS_FILE" ]; then
            while IFS='|' read -r name config count; do
                echo "${name}|${config}" >> "$SELECTED_COMPOSE_FILE"
            done < "$COMPOSE_PROJECTS_FILE"
        fi
        if [ -s "$STANDALONE_CONTAINERS_FILE" ]; then
            while IFS='|' read -r name image ports status; do
                echo "${name}|${image}" >> "$SELECTED_STANDALONE_FILE"
            done < "$STANDALONE_CONTAINERS_FILE"
        fi
    fi

    # 4. 应用排除列表
    apply_excludes

    # 5. 执行备份
    if [ -s "$SELECTED_COMPOSE_FILE" ]; then
        while IFS='|' read -r name config; do
            backup_compose_project "$name" "$config"
        done < "$SELECTED_COMPOSE_FILE"
    fi

    if [ -s "$SELECTED_STANDALONE_FILE" ]; then
        while IFS='|' read -r name image; do
            backup_standalone_container "$name" "$image"
        done < "$SELECTED_STANDALONE_FILE"
    fi

    # 6. 生成最终备份包
    finalize_backup

    # 7. 备份后清理与通知
    post_backup_tasks

    # 清理临时文件
    rm -f "$COMPOSE_PROJECTS_FILE" "$STANDALONE_CONTAINERS_FILE" \
          "$SELECTED_COMPOSE_FILE" "$SELECTED_STANDALONE_FILE"
}

main "$@"
