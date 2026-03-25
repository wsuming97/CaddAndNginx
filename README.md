# Nginx Docker 一键反代 + 自动 SSL 证书

一键部署 Docker 化的 Nginx 反向代理，自动签发和续签 Let's Encrypt SSL 证书。

## 功能

- 🐳 Docker 化部署，不污染宿主机环境
- 🔒 自动签发 Let's Encrypt SSL 证书（ECDSA）
- 🔄 自动续签证书（每天检查，到期前 15 天自动续签）
- 🌐 支持 HTTP/2、HTTP/3 (QUIC)
- 🛡️ 默认拦截未绑定域名的请求（返回 444）
- 📋 交互式管理菜单 + 命令行快捷操作
- ⚡ 全自动安装，零交互

## 快速开始

### 安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/wsuming97/CaddAndNginx/main/install.sh)
```

### 管理

安装后输入 `nginx-proxy` 进入交互式管理菜单：

```
╔══════════════════════════════════════════════╗
║        Nginx Proxy 管理面板                  ║
╚══════════════════════════════════════════════╝

  操作菜单：
  1. 添加域名反代
  2. 删除域名
  3. 查看域名列表
  4. 手动续签证书
  5. 重启 Nginx
  6. 查看 Nginx 日志
  7. 更新脚本
  8. 卸载 Nginx
  0. 退出
```

### 命令行快捷操作

```bash
nginx-proxy                        # 打开交互式菜单
nginx-proxy add example.com 8080   # 直接添加域名反代
nginx-proxy del example.com        # 删除域名
nginx-proxy list                   # 查看域名列表
nginx-proxy status                 # 查看服务状态
nginx-proxy renew                  # 手动续签证书
nginx-proxy restart                # 重启 Nginx
nginx-proxy update                 # 更新脚本
nginx-proxy uninstall              # 卸载
```

## 目录结构

```
/home/web/
├── docker-compose.yml    # Nginx Docker 配置
├── nginx.conf            # Nginx 主配置
├── conf.d/               # 站点配置目录
├── certs/                # SSL 证书目录
├── html/                 # 静态文件目录
├── letsencrypt/          # ACME challenge 目录
├── log/nginx/            # Nginx 日志
└── stream.d/             # TCP/UDP 流转发配置
```

## 要求

- Linux (Debian/Ubuntu 推荐)
- root 权限
- 端口 80 和 443 未被占用

## 许可

MIT
