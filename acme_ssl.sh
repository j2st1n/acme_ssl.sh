#!/bin/bash
set -e

# ===========================================
# 版本：v2.3
# 修正：2025-06-12
#       - v2.1: 修正 acme.sh 安装后 "command not found" 问题。
#       - v2.2: 增加对 IPv6 防火墙 (ip6tables) 的支持。
#       - v2.3: 实现智能协议监听，根据 DNS 解析结果动态选择监听模式。
# 说明：自动化申请及安装 Let's Encrypt SSL 证书
#       1. 自动检测和安装依赖（cron, curl, openssl, socat, dig 等）
#       2. 自动安装和升级 acme.sh
#       3. 自动配置 80 端口防火墙（根据解析结果智能选择 iptables/ip6tables）
#       4. 自动检测域名解析（支持 IPv4/IPv6）
#       5. 自动申请和安装证书
#       6. 自动输出证书摘要和私钥指纹
# ===========================================

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  echo "错误：请以 root 用户运行本脚本。"
  exit 1
fi

# 自动检测并安装依赖
echo "==== 1. 检查并安装依赖 ===="
# 对于 Debian/Ubuntu, dnsutils 提供 dig; 对于 RHEL/CentOS, bind-utils 提供 dig.
# iproute2(Debian) vs iproute(CentOS)
PACKAGES="cron curl openssl socat lsof"
if command -v apt-get >/dev/null 2>&1; then
    PACKAGES="$PACKAGES dnsutils iproute2"
elif command -v yum >/dev/null 2>&1; then
    PACKAGES="$PACKAGES bind-utils iproute"
fi

for pkg in $PACKAGES; do
  # 使用 'dig' 和 'ss' 来检查包是否提供了所需命令
  cmd=$pkg
  [ "$pkg" == "dnsutils" ] || [ "$pkg" == "bind-utils" ] && cmd="dig"
  [ "$pkg" == "iproute2" ] || [ "$pkg" == "iproute" ] && cmd="ss"
  
  if ! command -v $cmd >/dev/null 2>&1; then
    echo "检测到缺少依赖：$pkg，正在尝试安装..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update >/dev/null && apt-get install -y $pkg
    elif command -v yum >/dev/null 2>&1; then
      yum install -y $pkg
    else
      echo "错误：不支持的包管理器，请手动安装 $pkg"
      exit 1
    fi
  fi
done

# 定义 acme.sh 路径并检查安装
echo -e "\n==== 2. 安装与升级 acme.sh ===="
ACME_SH="$HOME/.acme.sh/acme.sh"
if [ ! -f "$ACME_SH" ]; then
  echo "acme.sh 未检测到，开始安装..."
  curl https://get.acme.sh | sh
fi

if [ ! -f "$ACME_SH" ]; then
  echo "错误：acme.sh 安装失败，请检查网络或安装日志。"
  exit 1
fi

echo "升级 acme.sh..."
"$ACME_SH" --upgrade --auto-upgrade
"$ACME_SH" --set-default-ca --server letsencrypt

# 域名读取与解析检测
echo -e "\n==== 3. 域名与解析检测 ===="
read -rp "请输入你的域名: " domain
if [ -z "$domain" ]; then
    echo "错误：域名不能为空。"
    exit 1
fi

echo "检测域名解析..."
ipv4=$(dig +short A "$domain" | head -n1)
ipv6=$(dig +short AAAA "$domain" | head -n1)

ACME_LISTEN_FLAG=""
if [ -n "$ipv6" ]; then
    echo "  - 检测到 AAAA 记录，将优先使用 IPv6 进行验证。"
    ACME_LISTEN_FLAG="--listen-v6"
elif [ -n "$ipv4" ]; then
    echo "  - 未检测到 AAAA 记录，将使用 IPv4 进行验证。"
else
    echo "错误：未检测到 $domain 的有效 A 或 AAAA 解析记录。"
    exit 1
fi
echo "  - A 记录: ${ipv4:-未找到}"
echo "  - AAAA 记录: ${ipv6:-未找到}"

# 检查端口与防火墙
echo -e "\n==== 4. 检查端口与防火墙 ===="
if lsof -i:80 | grep LISTEN; then
  echo "错误：端口 80 已被其他服务占用，请先释放端口后再运行脚本。"
  exit 1
fi

FIREWALL=""
if command -v firewall-cmd >/dev/null 2>&1; then FIREWALL="firewalld";
elif command -v ufw >/dev/null 2>&1; then FIREWALL="ufw";
elif command -v iptables >/dev/null 2>&1; then FIREWALL="iptables"; fi

open_port() {
  echo "  - 正在开放 80 端口..."
  case "$FIREWALL" in
    firewalld) firewall-cmd --add-port=80/tcp --permanent >/dev/null && firewall-cmd --reload >/dev/null || return 1 ;;
    ufw) ufw allow 80/tcp >/dev/null || return 1 ;;
    iptables)
      if [ -n "$ipv4" ]; then iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT || return 1; fi
      if [ -n "$ipv6" ] && command -v ip6tables >/dev/null 2>&1; then ip6tables -I INPUT 1 -p tcp --dport 80 -j ACCEPT || return 1; fi ;;
  esac
}

close_port() {
  echo "  - 正在关闭 80 端口..."
  case "$FIREWALL" in
    firewalld) firewall-cmd --remove-port=80/tcp --permanent >/dev/null && firewall-cmd --reload >/dev/null || return 1 ;;
    ufw) ufw delete allow 80/tcp >/dev/null || return 1 ;;
    iptables)
      if [ -n "$ipv4" ]; then iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true; fi
      if [ -n "$ipv6" ] && command -v ip6tables >/dev/null 2>&1; then ip6tables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true; fi ;;
  esac
}

if [ -n "$FIREWALL" ]; then
  echo "检测到 $FIREWALL 防火墙，将临时管理 80 端口。"
  open_port || { echo "错误：自动开放 80 端口失败，请手动检查防火墙规则。"; exit 1; }
  trap close_port EXIT
else
  echo "警告：未检测到已知防火墙，请确保 80 端口可从公网访问。"
fi

# 证书申请与安装
echo -e "\n==== 5. 申请与安装证书 ===="
echo "开始为域名 $domain 申请证书 (使用 ${ACME_LISTEN_FLAG:---listen-v4 (默认)}) ..."
if "$ACME_SH" --issue -d "$domain" --standalone $ACME_LISTEN_FLAG; then
  echo "证书申请成功！开始安装..."
  CERT_DIR="/etc/ssl/certs"
  KEY_DIR="/etc/ssl/private"
  mkdir -p "$CERT_DIR" "$KEY_DIR"
  
  "$ACME_SH" --install-cert -d "$domain" \
    --key-file       "$KEY_DIR/$domain.key" \
    --fullchain-file "$CERT_DIR/$domain.crt" \
    --reloadcmd      "echo '请根据需要手动重启 Web 服务 (例如: systemctl reload nginx)'"

  # 输出证书信息
  echo -e "\n==== 6. 证书信息摘要 ===="
  echo "证书摘要 (SHA256):"
  openssl x509 -in "$CERT_DIR/$domain.crt" -noout -fingerprint -sha256
  echo "私钥公钥指纹 (SHA256):"
  openssl pkey -in "$KEY_DIR/$domain.key" -pubout -outform DER | openssl dgst -sha256
  echo -e "\n证书已安装到 $CERT_DIR/$domain.crt"
  echo "私钥已安装到 $KEY_DIR/$domain.key"
else
  echo -e "\n错误：证书申请失败。"
  echo "可能原因：域名解析未生效、服务器无法从公网访问、80 端口被阻断等。"
  echo "建议尝试 DNS 验证方式（需配置 API）："
  echo "$ACME_SH --issue --dns dns_cf -d $domain"
  exit 1
fi

echo -e "\n脚本执行完毕。"
