# Nginx & Caddy 一键反代 + 自动 SSL 证书

一键部署反向代理，自动签发和续签 SSL 证书。提供 **Nginx (Docker)** 和 **Caddy (直装)** 两种方案。

## 快速开始

一条命令，选择方案：

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/setup.sh)
```

## 方案对比

| 功能 | Nginx 方案 | Caddy 方案 |
|------|-----------|-----------|
| 部署方式 | Docker 容器 | 直接安装到系统 |
| SSL 证书 | certbot 签发 | 内置自动签发 |
| 证书续签 | cron 定时任务 | 内置自动续签 |
| 静态缓存 | ✅ 内置 proxy_cache | ❌ 不支持 |
| HTTP/3 | ✅ 支持 | ✅ 支持 |
| WebSocket | ✅ 支持 | ✅ 支持 |
| 适合场景 | 需要精细控制、静态缓存 | 追求简单省心 |

## 使用

安装后可随时通过命令进入管理菜单：

```bash
nginx-proxy    # Nginx 方案
caddy-proxy    # Caddy 方案
```

命令行快捷操作：

```bash
nginx-proxy add example.com 8080    # 添加域名
nginx-proxy del example.com          # 删除域名
nginx-proxy list                     # 查看域名列表
```

## 要求

- Linux (Debian/Ubuntu 推荐)
- root 权限
- 端口 80 和 443 未被占用
- 域名 A 记录已指向服务器 IP

## 许可

MIT
