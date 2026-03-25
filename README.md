# Nginx & Caddy 一键反代 + 自动 SSL 证书

一键部署反向代理，自动签发和续签 SSL 证书。提供 **Nginx (Docker)** 和 **Caddy (直装)** 两种方案。

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

---

## Nginx 方案

### 安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/install.sh)
```

### 使用

```bash
# 进入菜单
nginx-proxy

# 或命令行快捷操作
nginx-proxy add example.com 8080
nginx-proxy del example.com
nginx-proxy list
```

---

## Caddy 方案

### 安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/caddy-install.sh)
```

### 使用

```bash
# 进入菜单
caddy-proxy

# 或命令行快捷操作
caddy-proxy add example.com 8080
caddy-proxy del example.com
caddy-proxy list
```

---

## 要求

- Linux (Debian/Ubuntu 推荐)
- root 权限
- 端口 80 和 443 未被占用
- 域名 A 记录已指向服务器 IP

## 许可

MIT
