# Nginx & Caddy & Docker 一键管理工具

一键部署反向代理（自动签发和续签 SSL 证书）+ Docker & Compose 环境管理。提供 **Nginx (Docker)**、**Caddy (直装)** 和 **Docker 管理** 三种方案。

## 快速开始

一条命令，选择方案：

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/setup.sh)
```

## 方案对比

| 功能 | Nginx 方案 | Caddy 方案 | Docker 管理 |
|------|-----------|-----------|------------|
| 用途 | 反向代理 | 反向代理 | 容器环境管理 |
| 部署方式 | Docker 容器 | 直接安装到系统 | — |
| SSL 证书 | certbot 签发 | 内置自动签发 | — |
| 证书续签 | cron 定时任务 | 内置自动续签 | — |
| 静态缓存 | ✅ 内置 proxy_cache | ❌ 不支持 | — |
| HTTP/3 | ✅ 支持 | ✅ 支持 | — |
| WebSocket | ✅ 支持 | ✅ 支持 | — |
| 适合场景 | 需要精细控制、静态缓存 | 追求简单省心 | Docker 环境部署与运维 |

## 使用

安装后可随时通过命令进入管理菜单：

```bash
nginx-proxy      # Nginx 方案
caddy-proxy      # Caddy 方案
docker-manager   # Docker & Compose 管理
```

命令行快捷操作：

```bash
# Nginx
nginx-proxy add example.com 8080    # 添加域名
nginx-proxy del example.com          # 删除域名
nginx-proxy list                     # 查看域名列表

# Docker
docker-manager install-docker        # 安装 Docker
docker-manager install-compose       # 安装 Docker Compose
docker-manager manage                # 进入管理子菜单
docker-manager uninstall             # 卸载 Docker & Compose
docker-manager status                # 查看状态
```

## Docker 管理功能

| 功能 | 说明 |
|------|------|
| 安装 Docker | 通过官方脚本一键安装，支持国内镜像降级 |
| 安装 Compose | 优先 apt/yum 插件安装，失败自动下载二进制 |
| 管理面板 | 启动/停止/重启、容器列表、镜像列表、日志、磁盘占用 |
| 卸载清理 | 完整卸载 Docker & Compose，可选删除全部数据 |

## 要求

- Linux (Debian/Ubuntu 推荐)
- root 权限
- 端口 80 和 443 未被占用（反代方案）
- 域名 A 记录已指向服务器 IP（反代方案）

## 许可

MIT
