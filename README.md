# Automated SSL/TLS Certificate Installer (acme_ssl.sh)

这是一个 Bash 脚本，旨在完全自动化获取和安装 Let's Encrypt SSL/TLS 证书的过程。能够智能地处理 IPv4 和 IPv6。

## 主要特性

-   **自动依赖安装**: 自动检测并安装 `cron`, `curl`, `socat`, `dig` 等所有必需的系统工具。
-   **智能协议检测**: 脚本会自动检测你的域名解析记录。如果检测到 AAAA (IPv6) 记录，它会优先使用 IPv6进行验证，这对于纯 IPv6 或双栈网络环境至关重要[11][12]。
-   **动态防火墙管理**: 自动检测 `ufw`, `firewalld`, 或 `iptables`，并临时开放 80 端口进行验证。它会根据检测到的 IP 协议（IPv4/IPv6）智能地使用 `iptables` 和 `ip6tables`。
-   **一键式操作**: 从环境检查到证书安装，整个过程只需运行一个命令并输入你的域名。
-   **详细的输出与日志**: 提供了清晰的执行步骤输出，并在成功后显示证书和私钥的指纹信息，便于验证和记录[13]。

## 先决条件

1.  一台运行 Debian/Ubuntu 或 RHEL/CentOS 系列的 Linux 服务器。
2.  `root` 用户权限。
3.  一个已注册的域名。
4.  将你的域名（A 和/或 AAAA 记录）正确解析到你的服务器公网 IP 地址。

## 如何使用

通过一个命令即可下载并执行脚本。

```bash
wget -O acme_ssl.sh https://raw.githubusercontent.com/j2st1n/acme_ssl.sh/refs/heads/main/acme_ssl.sh && chmod +x acme_ssl.sh && ./acme_ssl.sh
```

脚本启动后，会提示你输入域名，然后会自动完成所有后续步骤。

## 脚本工作流程

1.  **环境检查**: 验证 `root` 权限并安装缺失的依赖。
2.  **ACME.sh 设置**: 安装或升级 `acme.sh` 客户端，并将其设置为默认的 Let's Encrypt CA。
3.  **DNS 解析与策略决策**:
    -   查询域名的 A 和 AAAA 记录。
    -   如果存在 AAAA 记录，则设定 `acme.sh` 在 IPv6 上监听 (`--listen-v6`)。
    -   否则，使用默认的 IPv4 监听。
4.  **防火墙操作**: 根据上一步的决策，临时为 IPv4 (`iptables`) 和/或 IPv6 (`ip6tables`) 开放 80 端口。
5.  **证书申请**: `acme.sh` 以 `standalone` 模式启动一个临时 Web 服务器来响应 Let's Encrypt 的验证请求。
6.  **安装与清理**:
    -   成功后，将证书 (`.crt`) 和私钥 (`.key`) 安装到 `/etc/ssl/` 目录。
    -   关闭之前临时开放的 80 端口。
    -   显示证书信息。

## 应用示例：配置 Web 服务

获取证书后，你可以用它来保护你的 Web 服务。

### Nginx 示例

```nginx
server {
    listen 80;
    server_name your.domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name your.domain.com;

    ssl_certificate      /etc/ssl/certs/your.domain.com.crt;
    ssl_certificate_key  /etc/ssl/private/your.domain.com.key;

    # ... 其他配置
}
```

## 故障排查

如果脚本执行失败，可以从以下几个方面检查：

-   **域名解析**: 确保你的域名已正确解析到服务器 IP，并且 DNS 记录已在全球生效。可以使用 `dig your.domain.com` 进行检查。
-   **端口访问**: 检查你的云服务商安全组或网络 ACL 是否允许 80 端口的入站流量。
-   **系统日志**: 对于更深层次的问题，可以使用 `journalctl` 查看系统服务的相关日志，这对于定位网络或权限问题非常有用[14]。

## License

This project is licensed under the MIT License.
