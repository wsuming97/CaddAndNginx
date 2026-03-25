# Nginx Docker 一键反代 + 自动 SSL 证书

一键部署 Docker 化的 Nginx 反向代理，自动签发和续签 Let's Encrypt SSL 证书。

## 功能

- 🐳 Docker 化部署，不污染宿主机环境
- 🔒 自动签发 Let's Encrypt SSL 证书（ECDSA）
- 🔄 自动续签证书（每天检查，到期前 15 天自动续签）
- 🌐 支持 HTTP/2、HTTP/3 (QUIC)
- 🛡️ 默认拦截未绑定域名的请求（返回 444）
- ⚡ 一键添加域名反代，一条命令搞定

## 快速开始

### 1. 安装 Nginx

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/install.sh)
```

### 2. 添加域名反代

先将域名 A 记录指向服务器 IP，DNS 生效后执行：

```bash
add-site example.com 8080
```

参数说明：
- 第一个参数：域名
- 第二个参数：后端服务端口

### 3. 删除域名

```bash
del-site example.com
```

## 目录结构

安装后的文件结构：

```
/home/web/
├── docker-compose.yml    # Nginx Docker 配置
├── nginx.conf            # Nginx 主配置
├── conf.d/               # 站点配置目录
│   ├── default.conf      # 默认站点（拦截未知域名）
│   └── example.com.conf  # 域名反代配置（自动生成）
├── certs/                # SSL 证书目录
├── html/                 # 静态文件目录
├── letsencrypt/          # ACME challenge 目录
├── log/nginx/            # Nginx 日志
└── stream.d/             # TCP/UDP 流转发配置

/usr/local/bin/
├── add-site              # 添加域名脚本
└── del-site              # 删除域名脚本

~/auto_cert_renewal.sh    # 证书自动续签脚本（cron 每天 0 点执行）
```

## 要求

- Linux (Debian/Ubuntu 推荐)
- root 权限
- 端口 80 和 443 未被占用

## 许可

MIT
