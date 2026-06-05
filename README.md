# Nginx & Caddy & Docker 一键管理工具

一键部署反向代理（自动签发和续签 SSL 证书）+ Docker & Compose 环境管理 + Docker 服务迁移。

## 快速开始

一条命令，选择方案：

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/setup.sh)
```

## 功能总览

| 方案 | 功能 | 入口命令 |
|------|------|---------|
| **Nginx** | Docker 反代 + certbot 证书 + 静态缓存 | `nginx-proxy` |
| **Caddy** | 直装反代 + 自动 HTTPS + 零配置 | `caddy-proxy` |
| **Docker 管理** | 安装/管理/卸载 Docker & Compose | `docker-manager` |
| **Docker 迁移** | 备份/传输/还原 Docker 服务到新 VPS | `docker-manager migrate` |

## Nginx vs Caddy 对比

| 功能 | Nginx 方案 | Caddy 方案 |
|------|-----------|-----------|
| 部署方式 | Docker 容器 | 直接安装到系统 |
| SSL 证书 | certbot 签发 | 内置自动签发 |
| 证书续签 | cron 定时任务 | 内置自动续签 |
| 静态缓存 | ✅ 内置 proxy_cache | ❌ 不支持 |
| HTTP/3 | ✅ 支持 | ✅ 支持 |
| WebSocket | ✅ 支持 | ✅ 支持 |
| 适合场景 | 需要精细控制、静态缓存 | 追求简单省心 |

## Docker 管理功能

```bash
docker-manager                  # 进入管理菜单
docker-manager install-docker   # 安装 Docker
docker-manager install-compose  # 安装 Docker Compose
docker-manager manage           # 进入管理子菜单
docker-manager migrate          # 进入迁移工具
docker-manager uninstall        # 卸载 Docker & Compose
docker-manager status           # 查看状态
```

### 安装能力

| 功能 | 说明 |
|------|------|
| Docker 安装 | 3 级降级：官方源 → 阿里云 → DaoCloud |
| Compose 安装 | apt/yum 插件 → GitHub 二进制 → DaoCloud 镜像 |
| 镜像加速 | 安装后自动配置：腾讯云/DaoCloud/网易/官方CN |

### 管理面板（12 项）

| 编号 | 功能 | 说明 |
|------|------|------|
| 1-4 | 状态/启动/停止/重启 | Docker 服务控制 |
| 5-6 | 运行中/所有容器 | 容器列表查看 |
| 7 | 镜像列表 | 本地镜像管理 |
| 8-9 | 日志/磁盘占用 | 运维诊断 |
| **10** | **清理系统垃圾** | 分级清理：普通/深度/完全 |
| **11** | **修复 Docker 网络** | 清理残留网络 + 重建网桥 |
| **12** | **自愈 Docker** | 自动重启 exited/unhealthy 容器 |

## Docker 迁移工具

一键迁移 Docker 服务到新 VPS，三步完成：

```text
旧 VPS                          新 VPS
┌──────────────┐    传输    ┌──────────────┐
│  backup.sh   │ ───────► │  restore.sh  │
│  备份打包     │  transfer │  还原验证     │
└──────────────┘           └──────────────┘
```

### 第 1 步：旧 VPS 上备份

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/backup.sh)

# 或全部备份
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/backup.sh) --all

# 排除不需要的容器
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/backup.sh) --all --exclude komari,watchtower
```

### 第 2 步：传输到新 VPS

```bash
curl -sLO https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/transfer.sh
bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 新IP --port 22
```

> **⚠️ 目标服务器未安装 rsync？**
>
> 默认传输方式为 rsync（支持断点续传），如果目标服务器未安装 rsync，会报错 `rsync: command not found`。
> 解决方式（二选一）：
> ```bash
> # 方式 1：在目标服务器上安装 rsync（推荐）
> ssh 新IP "sudo apt-get update -qq && sudo apt-get install -y rsync"    # Debian/Ubuntu
> ssh 新IP "sudo yum install -y rsync"                                   # CentOS/RHEL
>
> # 方式 2：降级为 scp 传输（无需安装额外软件）
> bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 新IP --method scp
> ```

> **⚠️ 云服务器使用密钥登录（如 AWS / GCP / Azure）？**
>
> 云服务器通常不允许密码登录，且默认用户不是 `root`（如 AWS Debian 用 `admin`，Ubuntu 用 `ubuntu`，Amazon Linux 用 `ec2-user`）。
> 需要先在旧 VPS 上配置 SSH config：
> ```bash
> # 1. 将密钥文件传到旧 VPS 上并设置权限
> chmod 600 /root/.ssh/你的密钥.pem
>
> # 2. 配置 SSH 别名
> cat >> /root/.ssh/config << 'EOF'
> Host 目标别名
>     HostName 目标公网IP
>     User admin          # 改为目标服务器实际用户名
>     Port 22
>     IdentityFile /root/.ssh/你的密钥.pem
>     StrictHostKeyChecking no
> EOF
>
> # 3. 测试连接
> ssh 目标别名 "echo ok"
>
> # 4. 使用别名传输
> bash transfer.sh /tmp/sumingdk-backup-xxx.tar.gz 目标别名
> ```
>
> | 云服务商 | 默认用户名 |
> |---------|-----------|
> | AWS (Debian) | `admin` |
> | AWS (Ubuntu) | `ubuntu` |
> | AWS (Amazon Linux) | `ec2-user` |
> | GCP | 自定义用户名 |
> | Azure | `azureuser` |

### 第 3 步：新 VPS 上还原

```bash
curl -sLO https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/restore.sh
bash restore.sh /tmp/sumingdk-backup-xxx.tar.gz
```

### 迁移支持能力

| 功能 | 说明 |
|------|------|
| 自动检测 | 扫描所有 Compose 项目和独立容器 |
| 全量打包 | Bind Mount + Named Volume 数据 |
| 数据库导出 | PostgreSQL / MySQL / MariaDB / MongoDB / Redis |
| 反向生成 | 独立容器自动生成 docker-compose.yml |
| 多种传输 | rsync（断点续传）/ scp / tar+ssh 管道 |
| 迁移验证 | 还原后自动检查容器状态和端口可达性 |

## Nginx 命令行

```bash
nginx-proxy add example.com 8080    # 添加域名反代
nginx-proxy del example.com          # 删除域名
nginx-proxy list                     # 查看域名列表
nginx-proxy renew                    # 手动续签证书
```

## 要求

- Linux (Debian/Ubuntu 推荐)
- root 权限
- 端口 80 和 443 未被占用（反代方案）
- 域名 A 记录已指向服务器 IP（反代方案）

## 许可

MIT
