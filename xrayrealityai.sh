#!/usr/bin/env bash
#=============================================================================
# Xray-core VLESS + REALITY 一键部署脚本
# 功能：自动网络检测、出口IP选择、IPv6优先、浏览器指纹、DDNS失效切换、
#       MTU调整、Socks5落地、SNI过滤器(sni-filter)、Systemd守护、管理命令
# 系统要求：Linux (Debian/Ubuntu/CentOS/RHEL/Fedora/Arch) + systemd + root
# 版本：3.0（集成 sni-filter）
#=============================================================================

set -e

# ---------- 颜色定义 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ---------- 全局变量 ----------
XRAY_CONFIG_SNI="/usr/local/etc/xray/sni_config.json"
XRAY_CONFIG_OLD="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
SNI_FILTER_BIN="/usr/local/bin/sni-filter"
XRAY_DDNS_SCRIPT="/usr/local/bin/xray-ddns-switch.sh"
XRAY_MTU_SCRIPT="/usr/local/bin/xray-mtu-set.sh"
XRAY_ENV_FILE="/etc/xray/env.conf"
XRAY_WORKDIR="/var/lib/xray"
XRAY_SOCKET_DIR="${XRAY_WORKDIR}/socket"
XRAY_SOCKET="${XRAY_SOCKET_DIR}/xray.sock"
XRAY_LISTEN_PORT=""
XRAY_SNI=""
XRAY_PRIVATE_KEY=""
XRAY_PUBLIC_KEY=""
XRAY_SHORT_ID=""
XRAY_UUID=""
XRAY_FINGERPRINT="chrome"
XRAY_OUTBOUND_MODE="freedom"
XRAY_SOCKS5_ADDR=""
XRAY_SOCKS5_PORT=""
XRAY_SOCKS5_USER=""
XRAY_SOCKS5_PASS=""
XRAY_SEND_THROUGH_IPV4=""
XRAY_SEND_THROUGH_IPV6=""
XRAY_IP_VERSION="ipv4"
XRAY_USE_IPV6_PRIORITY="no"
XRAY_MTU_VALUE=""
XRAY_MTU_IFACE=""
XRAY_ENABLE_DDNS="no"
XRAY_DDNS_TYPE=""
XRAY_DDNS_STRATEGY=""
XRAY_DDNS_TARGET_IP=""
XRAY_DDNS_CHECK_INTERVAL="60"
XRAY_USER="xrayuser"

# ---------- 检查root ----------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：请以 root 身份运行此脚本${NC}"
        exit 1
    fi
}

# ---------- 检测系统架构 ----------
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)    ARCH="64"; SNI_FILTER_ARCH="amd64" ;;
        i386|i686)       ARCH="32"; SNI_FILTER_ARCH="i386" ;;
        aarch64|arm64)   ARCH="arm64-v8a"; SNI_FILTER_ARCH="arm64" ;;
        *)               echo -e "${RED}不支持的架构: $(uname -m)${NC}"; exit 1 ;;
    esac
}

# ---------- 安装依赖 ----------
install_deps() {
    echo -e "${CYAN}[*] 安装依赖...${NC}"
    if command -v apt &>/dev/null; then
        apt update -y && apt install -y curl wget unzip jq iproute2 procps net-tools openssl
    elif command -v yum &>/dev/null; then
        yum install -y curl wget unzip jq iproute procps net-tools openssl
    elif command -v dnf &>/dev/null; then
        dnf install -y curl wget unzip jq iproute procps net-tools openssl
    elif command -v zypper &>/dev/null; then
        zypper install -y curl wget unzip jq iproute2 procps net-tools openssl
    elif command -v pacman &>/dev/null; then
        pacman -Syy --noconfirm curl wget unzip jq iproute2 procps net-tools openssl
    else
        echo -e "${RED}不支持的包管理器${NC}"; exit 1
    fi
}

# ---------- 检测公网IP ----------
detect_public_ips() {
    echo -e "${CYAN}[*] 检测系统公网 IP 地址...${NC}"
    
    # 获取所有非回环IPv4（排除私有地址）
    IPV4_LIST=($(ip -4 addr show | grep inet | awk '{print $2}' | cut -d/ -f1 | \
        grep -v '^127\.' | grep -v '^10\.' | grep -v '^172\.\(1[6-9]\|2[0-9]\|3[01]\)\.' | \
        grep -v '^192\.168\.' | grep -v '^169\.254\.'))
    
    # 获取所有非回环IPv6（全局单播，排除本地链路和ULA）
    IPV6_LIST=($(ip -6 addr show | grep inet6 | awk '{print $2}' | cut -d/ -f1 | \
        grep -v '^::1' | grep -v '^fe80:' | grep -v '^fd' | grep -v '^fc'))
    
    echo -e "${GREEN}检测到的 IPv4 地址：${NC}"
    if [[ ${#IPV4_LIST[@]} -eq 0 ]]; then
        echo "  未检测到公网IPv4"
    else
        for i in "${!IPV4_LIST[@]}"; do echo "  [$i] ${IPV4_LIST[$i]}"; done
    fi
    
    echo -e "${GREEN}检测到的 IPv6 地址：${NC}"
    if [[ ${#IPV6_LIST[@]} -eq 0 ]]; then
        echo "  未检测到公网IPv6"
    else
        for i in "${!IPV6_LIST[@]}"; do echo "  [$i] ${IPV6_LIST[$i]}"; done
    fi
    
    if [[ ${#IPV4_LIST[@]} -eq 0 && ${#IPV6_LIST[@]} -eq 0 ]]; then
        echo -e "${RED}未检测到公网IP！请检查网络配置。${NC}"
        exit 1
    fi
}

# ---------- 选择出口IP ----------
select_outbound_ips() {
    echo ""
    echo -e "${YELLOW}======== 出口 IP 配置 ========${NC}"
    
    # IPv6 优先选择
    read -rp "是否优先使用 IPv6 出口？(y/n, 默认 n): " ipv6_pri
    if [[ "$ipv6_pri" =~ ^[Yy]$ ]]; then
        XRAY_USE_IPV6_PRIORITY="yes"
        XRAY_IP_VERSION="ipv6"
    else
        XRAY_USE_IPV6_PRIORITY="no"
        XRAY_IP_VERSION="ipv4"
    fi
    
    # IPv4 出口选择
    if [[ ${#IPV4_LIST[@]} -gt 0 ]]; then
        echo -e "${CYAN}选择 IPv4 出口地址：${NC}"
        echo "  0) 不使用 IPv4 出口"
        for i in "${!IPV4_LIST[@]}"; do echo "  $((i+1))) ${IPV4_LIST[$i]}"; done
        echo "  m) 手动输入"
        read -rp "请选择 [0-${#IPV4_LIST[@]}/m] (默认 1): " v4_choice
        v4_choice=${v4_choice:-1}
        if [[ "$v4_choice" == "0" ]]; then
            XRAY_SEND_THROUGH_IPV4=""
        elif [[ "$v4_choice" == "m" ]]; then
            read -rp "输入 IPv4 地址: " XRAY_SEND_THROUGH_IPV4
        elif [[ "$v4_choice" =~ ^[0-9]+$ ]] && [[ $v4_choice -ge 1 ]] && [[ $v4_choice -le ${#IPV4_LIST[@]} ]]; then
            XRAY_SEND_THROUGH_IPV4="${IPV4_LIST[$((v4_choice-1))]}"
        fi
    else
        read -rp "未检测到 IPv4，手动输入（留空取消）: " XRAY_SEND_THROUGH_IPV4
    fi
    
    # IPv6 出口选择
    if [[ ${#IPV6_LIST[@]} -gt 0 ]]; then
        echo -e "${CYAN}选择 IPv6 出口地址：${NC}"
        echo "  0) 不使用 IPv6 出口"
        for i in "${!IPV6_LIST[@]}"; do echo "  $((i+1))) ${IPV6_LIST[$i]}"; done
        echo "  m) 手动输入"
        read -rp "请选择 [0-${#IPV6_LIST[@]}/m] (默认 1): " v6_choice
        v6_choice=${v6_choice:-1}
        if [[ "$v6_choice" == "0" ]]; then
            XRAY_SEND_THROUGH_IPV6=""
        elif [[ "$v6_choice" == "m" ]]; then
            read -rp "输入 IPv6 地址: " XRAY_SEND_THROUGH_IPV6
        elif [[ "$v6_choice" =~ ^[0-9]+$ ]] && [[ $v6_choice -ge 1 ]] && [[ $v6_choice -le ${#IPV6_LIST[@]} ]]; then
            XRAY_SEND_THROUGH_IPV6="${IPV6_LIST[$((v6_choice-1))]}"
        fi
    else
        read -rp "未检测到 IPv6，手动输入（留空取消）: " XRAY_SEND_THROUGH_IPV6
    fi
    
    echo -e "${GREEN}IPv4 出口: ${XRAY_SEND_THROUGH_IPV4:-未使用}${NC}"
    echo -e "${GREEN}IPv6 出口: ${XRAY_SEND_THROUGH_IPV6:-未使用}${NC}"
    echo -e "${GREEN}优先级: $([ "$XRAY_USE_IPV6_PRIORITY" == "yes" ] && echo 'IPv6 > IPv4' || echo 'IPv4 > IPv6')${NC}"
}

# ---------- 生成密钥和UUID ----------
generate_keys() {
    echo -e "${CYAN}[*] 生成 Xray 密钥对和 UUID...${NC}"
    KEY_JSON=$($XRAY_BIN x25519)
    XRAY_PRIVATE_KEY=$(echo "$KEY_JSON" | grep "Private key:" | awk '{print $3}')
    XRAY_PUBLIC_KEY=$(echo "$KEY_JSON" | grep "Public key:" | awk '{print $3}')
    XRAY_UUID=$($XRAY_BIN uuid)
    XRAY_SHORT_ID=$(openssl rand -hex 8)
    
    echo -e "  Private Key: ${GREEN}$XRAY_PRIVATE_KEY${NC}"
    echo -e "  Public Key:  ${GREEN}$XRAY_PUBLIC_KEY${NC}"
    echo -e "  UUID:        ${GREEN}$XRAY_UUID${NC}"
    echo -e "  Short ID:    ${GREEN}$XRAY_SHORT_ID${NC}"
}

# ---------- 交互配置 ----------
interactive_config() {
    echo ""
    echo -e "${YELLOW}======== VLESS + REALITY 基本配置 ========${NC}"
    
    # 监听端口
    read -rp "监听端口 (建议443, 默认443): " XRAY_LISTEN_PORT
    XRAY_LISTEN_PORT=${XRAY_LISTEN_PORT:-443}
    
    # SNI (目标网站)
    echo -e "${CYAN}推荐 SNI 列表（需支持 TLSv1.3 + H2）：${NC}"
    echo "  1) www.amd.com        (AMD)"
    echo "  2) www.apple.com      (Apple)"
    echo "  3) www.akamai.com    (Akamai)"
    echo "  4) www.tesla.com         (Tesla)"
    echo "  5) 自定义输入"
    read -rp "选择 SNI [1-5] (默认 1): " sni_choice
    case ${sni_choice:-1} in
        1) XRAY_SNI="www.amd.com" ;;
        2) XRAY_SNI="www.apple.com" ;;
        3) XRAY_SNI="www.akamai.com" ;;
        4) XRAY_SNI="www.tesla.com" ;;
        5|*) read -rp "输入 SNI 域名: " XRAY_SNI ;;
    esac
    echo -e "${GREEN}SNI: $XRAY_SNI${NC}"
    
    # 浏览器指纹
    echo -e "${CYAN}选择浏览器指纹:${NC}"
    echo "  1) chrome (Chrome, 默认)"
    echo "  2) firefox (Firefox)"
    echo "  3) safari (Safari)"
    echo "  4) ios (iOS/Safari)"
    echo "  5) edge (Edge)"
    echo "  6) random (随机)"
    read -rp "选择 [1-9] (默认 1): " fp_choice
    case ${fp_choice:-1} in
        1) XRAY_FINGERPRINT="chrome" ;;
        2) XRAY_FINGERPRINT="firefox" ;;
        3) XRAY_FINGERPRINT="safari" ;;
        4) XRAY_FINGERPRINT="ios" ;;
        5) XRAY_FINGERPRINT="edge" ;;
        6) XRAY_FINGERPRINT="random" ;;
    esac
    echo -e "${GREEN}指纹: $XRAY_FINGERPRINT${NC}"
    
    # 落地方式
    echo -e "${CYAN}选择落地方式:${NC}"
    echo "  1) 直接连接 (Freedom, 推荐)"
    echo "  2) 通过 Socks5 代理落地"
    read -rp "选择 [1-2] (默认 1): " ob_choice
    if [[ "${ob_choice:-1}" == "2" ]]; then
        XRAY_OUTBOUND_MODE="socks"
        read -rp "Socks5 服务器地址: " XRAY_SOCKS5_ADDR
        read -rp "Socks5 端口: " XRAY_SOCKS5_PORT
        read -rp "Socks5 用户名 (可选): " XRAY_SOCKS5_USER
        read -rp "Socks5 密码 (可选): " XRAY_SOCKS5_PASS
    else
        XRAY_OUTBOUND_MODE="freedom"
    fi
    
    # MTU 调整
    echo -e "${CYAN}MTU 调整（可选，解决部分网络环境 Reality 连接失败问题）:${NC}"
    read -rp "是否调整 MTU? (y/n, 默认 n): " mtu_yn
    if [[ "$mtu_yn" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}可用网卡:${NC}"
        ip -o link show | awk -F': ' '{print $2}'
        read -rp "输入网卡名 (如 eth0): " XRAY_MTU_IFACE
        read -rp "输入 MTU 值 (如 1390, 默认 1390): " XRAY_MTU_VALUE
        XRAY_MTU_VALUE=${XRAY_MTU_VALUE:-1390}
    fi
    
    # DDNS 自动切换
    echo -e "${CYAN}DDNS 自动切换（出口IP失效时自动扫描子网可用IP）:${NC}"
    read -rp "是否启用 DDNS 自动切换? (y/n, 默认 n): " ddns_yn
    if [[ "$ddns_yn" =~ ^[Yy]$ ]]; then
        XRAY_ENABLE_DDNS="yes"
        echo -e "${CYAN}选择要监控的 IP 类型:${NC}"
        echo "  1) IPv4"
        echo "  2) IPv6"
        read -rp "选择 [1-2]: " ddns_type_choice
        if [[ "$ddns_type_choice" == "2" ]]; then
            XRAY_DDNS_TYPE="ipv6"
            XRAY_DDNS_TARGET_IP="$XRAY_SEND_THROUGH_IPV6"
            if [[ -z "$XRAY_DDNS_TARGET_IP" ]]; then
                echo -e "${RED}未配置 IPv6 出口，DDNS 无法启用${NC}"
                XRAY_ENABLE_DDNS="no"
            else
                local prefix12=$(echo "$XRAY_DDNS_TARGET_IP" | cut -d: -f1):
                local prefix28=$(echo "$XRAY_DDNS_TARGET_IP" | cut -d: -f1-2):
                local prefix48=$(echo "$XRAY_DDNS_TARGET_IP" | cut -d: -f1-3):
                echo -e "${CYAN}选择匹配策略:${NC}"
                echo "  1) $prefix12 开头 (match12)"
                echo "  2) $prefix28 开头 (match28)"
                echo "  3) $prefix48 开头 (match48)"
                echo "  4) 任意不同 IPv6 (any)"
                read -rp "选择 [1-4] (默认 1): " strat_choice
                case ${strat_choice:-1} in
                    1) XRAY_DDNS_STRATEGY="match12" ;;
                    2) XRAY_DDNS_STRATEGY="match28" ;;
                    3) XRAY_DDNS_STRATEGY="match48" ;;
                    4) XRAY_DDNS_STRATEGY="any" ;;
                esac
            fi
        else
            XRAY_DDNS_TYPE="ipv4"
            XRAY_DDNS_TARGET_IP="$XRAY_SEND_THROUGH_IPV4"
            if [[ -z "$XRAY_DDNS_TARGET_IP" ]]; then
                echo -e "${RED}未配置 IPv4 出口，DDNS 无法启用${NC}"
                XRAY_ENABLE_DDNS="no"
            else
                IFS='.' read -r a b c d <<< "$XRAY_DDNS_TARGET_IP"
                echo -e "${CYAN}选择匹配策略:${NC}"
                echo "  1) $a. 开头 (match8)"
                echo "  2) $a.$b. 开头 (match16)"
                echo "  3) $a.$b.$c. 开头 (match24)"
                echo "  4) 任意不同 IPv4 (any)"
                read -rp "选择 [1-4] (默认 1): " strat_choice
                case ${strat_choice:-1} in
                    1) XRAY_DDNS_STRATEGY="match8" ;;
                    2) XRAY_DDNS_STRATEGY="match16" ;;
                    3) XRAY_DDNS_STRATEGY="match24" ;;
                    4) XRAY_DDNS_STRATEGY="any" ;;
                esac
            fi
        fi
        if [[ "$XRAY_ENABLE_DDNS" == "yes" ]]; then
            read -rp "健康检查间隔（秒，默认60）: " XRAY_DDNS_CHECK_INTERVAL
            XRAY_DDNS_CHECK_INTERVAL=${XRAY_DDNS_CHECK_INTERVAL:-60}
        fi
    fi
}

# ---------- 安装Xray ----------
install_xray() {
    echo -e "${CYAN}[*] 安装 Xray-core...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [[ ! -f "$XRAY_BIN" ]]; then
        echo -e "${RED}Xray 安装失败${NC}"
        exit 1
    fi
    echo -e "${GREEN}Xray 安装成功: $($XRAY_BIN -version | head -1)${NC}"
}

# ---------- 安装 sni-filter ----------
install_sni_filter() {
    echo -e "${CYAN}[*] 安装 sni-filter...${NC}"
    
    # 创建临时目录
    local tmpdir=$(mktemp -d)
    cd "$tmpdir"
    
    # 下载 sni-filter
    local url="https://github.com/oldfriendme/REALITY-sni-filter/releases/download/v0.2/autobuild.zip"
    echo -e "  下载 sni-filter..."
    if ! wget -q "$url" -O autobuild.zip; then
        echo -e "${RED}下载 sni-filter 失败${NC}"
        cd / && rm -rf "$tmpdir"
        return 1
    fi
    
    unzip -o autobuild.zip -d . &>/dev/null
    
    # 根据架构选择正确的二进制
    case "$SNI_FILTER_ARCH" in
        amd64)  cp sni-filter-amd64 sni-filter ;;
        i386)   cp sni-filter-i386 sni-filter ;;
        arm64)  cp sni-filter-arm64 sni-filter ;;
        *)      echo -e "${RED}不支持的 sni-filter 架构: $SNI_FILTER_ARCH${NC}"; cd / && rm -rf "$tmpdir"; return 1 ;;
    esac
    
    chmod 755 sni-filter
    cp sni-filter "$SNI_FILTER_BIN"
    
    # 设置 cap_net_bind_service 权限（允许非root绑定低端口）
    if command -v setcap &>/dev/null; then
        setcap 'cap_net_bind_service=+ep' "$SNI_FILTER_BIN" 2>/dev/null || true
    fi
    
    cd / && rm -rf "$tmpdir"
    echo -e "${GREEN}sni-filter 安装成功: $SNI_FILTER_BIN${NC}"
}

# ---------- 创建工作目录 ----------
setup_workdir() {
    echo -e "${CYAN}[*] 创建工作目录和 Unix Socket...${NC}"
    mkdir -p "$XRAY_WORKDIR"
    mkdir -p "$XRAY_SOCKET_DIR"
    
    # 创建 xrayuser 用户
    if ! id -u xrayuser &>/dev/null; then
        useradd -r -s /sbin/nologin xrayuser 2>/dev/null || true
    fi
    
    chown -R xrayuser:xrayuser "$XRAY_WORKDIR"
    echo -e "${GREEN}工作目录: $XRAY_WORKDIR${NC}"
}

# ---------- 生成出站配置 JSON ----------
generate_outbounds_json() {
    local json="["
    
    if [[ "$XRAY_OUTBOUND_MODE" == "socks" ]]; then
        # Socks5 出站
        local socks_settings="{\"servers\":[{\"address\":\"$XRAY_SOCKS5_ADDR\",\"port\":$XRAY_SOCKS5_PORT"
        if [[ -n "$XRAY_SOCKS5_USER" && -n "$XRAY_SOCKS5_PASS" ]]; then
            socks_settings+=",\"users\":[{\"user\":\"$XRAY_SOCKS5_USER\",\"pass\":\"$XRAY_SOCKS5_PASS\",\"level\":0}]"
        fi
        socks_settings+="}]}"
        
        if [[ -n "$XRAY_SEND_THROUGH_IPV6" ]]; then
            json+="{\"tag\":\"direct-ipv6\",\"protocol\":\"socks\",\"settings\":$socks_settings,\"sendThrough\":\"$XRAY_SEND_THROUGH_IPV6\"},"
        fi
        if [[ -n "$XRAY_SEND_THROUGH_IPV4" ]]; then
            json+="{\"tag\":\"direct-ipv4\",\"protocol\":\"socks\",\"settings\":$socks_settings,\"sendThrough\":\"$XRAY_SEND_THROUGH_IPV4\"},"
        fi
    else
        # Freedom 出站
        if [[ -n "$XRAY_SEND_THROUGH_IPV6" ]]; then
            json+="{\"protocol\":\"freedom\",\"tag\":\"direct-ipv6\",\"settings\":{\"domainStrategy\":\"UseIPv6\"},\"sendThrough\":\"$XRAY_SEND_THROUGH_IPV6\"},"
        fi
        if [[ -n "$XRAY_SEND_THROUGH_IPV4" ]]; then
            json+="{\"protocol\":\"freedom\",\"tag\":\"direct-ipv4\",\"settings\":{\"domainStrategy\":\"UseIPv4\"},\"sendThrough\":\"$XRAY_SEND_THROUGH_IPV4\"},"
        fi
    fi
    
    # 如果没有配置任何出口，使用默认
    if [[ -z "$XRAY_SEND_THROUGH_IPV4" && -z "$XRAY_SEND_THROUGH_IPV6" ]]; then
        json+="{\"protocol\":\"freedom\",\"tag\":\"direct\",\"settings\":{}},"
    fi
    
    json="${json%,}]"
    echo "$json"
}

# ---------- 生成路由配置 JSON ----------
generate_routing_json() {
    local routing=""
    
    if [[ -n "$XRAY_SEND_THROUGH_IPV6" && -n "$XRAY_SEND_THROUGH_IPV4" ]]; then
        if [[ "$XRAY_USE_IPV6_PRIORITY" == "yes" ]]; then
            routing='{
                "domainStrategy": "IPOnDemand",
                "rules": [
                    {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]},
                    {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]}
                ]
            }'
        else
            routing='{
                "domainStrategy": "IPOnDemand",
                "rules": [
                    {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]},
                    {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]}
                ]
            }'
        fi
    elif [[ -n "$XRAY_SEND_THROUGH_IPV6" ]]; then
        routing='{
            "domainStrategy": "IPIfNonMatch",
            "rules": [{"type": "field", "outboundTag": "direct-ipv6", "network": "tcp,udp"}]
        }'
    elif [[ -n "$XRAY_SEND_THROUGH_IPV4" ]]; then
        routing='{
            "domainStrategy": "IPIfNonMatch",
            "rules": [{"type": "field", "outboundTag": "direct-ipv4", "network": "tcp,udp"}]
        }'
    fi
    
    echo "$routing"
}

# ---------- 生成配置文件 ----------
generate_configs() {
    echo -e "${CYAN}[*] 生成 Xray 配置...${NC}"
    mkdir -p $(dirname "$XRAY_CONFIG_SNI") $(dirname "$XRAY_CONFIG_OLD")
    
    local outbounds=$(generate_outbounds_json)
    local routing=$(generate_routing_json)
    
    # 生成 sni_config.json (Xray 监听 Unix Socket)
    cat > "$XRAY_CONFIG_SNI" <<EOFCONFIG1
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://dns.google/dns-query",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "listen": "${XRAY_SOCKET}",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "level": 0,
            "email": "reality-user@xray.local",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$XRAY_SNI:443",
          "xver": 0,
          "serverNames": ["$XRAY_SNI", ""],
          "privateKey": "$XRAY_PRIVATE_KEY",
          "shortIds": ["$XRAY_SHORT_ID", ""],
          "fingerprint": "$XRAY_FINGERPRINT"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "fakedns"]
      }
    }
  ],
  "outbounds": $outbounds
  $( [[ -n "$routing" ]] && echo "," )
  $( [[ -n "$routing" ]] && echo "\"routing\": $routing" )
}
EOFCONFIG1

    echo -e "${GREEN}sni_config.json 已生成 (Xray 监听 Unix Socket): $XRAY_CONFIG_SNI${NC}"
    
    # 生成 old_config.json (传统 TCP 监听，用于兼容/参考)
    cat > "$XRAY_CONFIG_OLD" <<EOFCONFIG2
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://dns.google/dns-query",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $XRAY_LISTEN_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "level": 0,
            "email": "reality-user@xray.local",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": []
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$XRAY_SNI:443",
          "xver": 0,
          "serverNames": ["$XRAY_SNI", ""],
          "privateKey": "$XRAY_PRIVATE_KEY",
          "shortIds": ["$XRAY_SHORT_ID", ""],
          "fingerprint": "$XRAY_FINGERPRINT"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "fakedns"]
      }
    }
  ],
  "outbounds": $outbounds
  $( [[ -n "$routing" ]] && echo "," )
  $( [[ -n "$routing" ]] && echo "\"routing\": $routing" )
}
EOFCONFIG2

    echo -e "${GREEN}old_config.json 已生成 (传统 TCP 监听): $XRAY_CONFIG_OLD${NC}"
}

# ---------- 生成 DDNS 切换脚本（适配sni-filter方案） ----------
generate_ddns_script() {
    if [[ "$XRAY_ENABLE_DDNS" != "yes" ]]; then
        return
    fi
    echo -e "${CYAN}[*] 生成 DDNS 自动切换脚本...${NC}"
    
    cat > "$XRAY_DDNS_SCRIPT" <<'EOFDDNS'
#!/bin/bash
# Xray DDNS 出口IP失效自动切换脚本（适配 sni-filter 方案）
WORKDIR="__WORKDIR__"
CONFIG_SNI="${WORKDIR}/config/sni_config.json"
CONFIG_OLD="${WORKDIR}/config/config.json"
DDNS_CONFIG="${WORKDIR}/ddns/ddns.config"
BIN="${WORKDIR}/xray"
LOG_FILE="${WORKDIR}/ddns-switch.log"
DDNS_TYPE="__DDNS_TYPE__"
TARGET_IP="__TARGET_IP__"
STRATEGY="__STRATEGY__"
CHECK_INTERVAL=__CHECK_INTERVAL__

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# 获取当前系统IP列表
get_current_ips() {
    if [ "$DDNS_TYPE" == "ipv6" ]; then
        ip -6 addr show | grep -oP 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80:' | grep -v '^::1'
    else
        ip -4 addr show | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | awk '{print $2}'
    fi
}

# 检查目标IP是否仍在系统中
ip_exists() {
    local ip=$1
    if [ "$DDNS_TYPE" == "ipv6" ]; then
        ip -6 addr show | grep -q "$ip"
    else
        ip -4 addr show | grep -q "$ip"
    fi
    return $?
}

# 更新配置中的IP
update_config_ip() {
    local old_ip=$1
    local new_ip=$2
    
    log "切换出口IP: $old_ip -> $new_ip"
    
    # 更新两个配置文件
    sed -i "s/$old_ip/$new_ip/g" "$CONFIG_SNI"
    sed -i "s/$old_ip/$new_ip/g" "$CONFIG_OLD"
    
    # 更新 DDNS 配置文件
    echo "$DDNS_TYPE $new_ip $STRATEGY" > "$DDNS_CONFIG"
    
    # 重启 Xray
    killall xray &>/dev/null || true
    sleep 1
    setsid "$BIN" -c "$CONFIG_SNI" &
    log "Xray 已重启"
}

# 扫描可用IP
find_new_ip() {
    local current_ips=$(get_current_ips)
    local new_ip=""
    
    if [ "$STRATEGY" == "any" ]; then
        for ip in $current_ips; do
            [ "$ip" != "$TARGET_IP" ] && { new_ip="$ip"; break; }
        done
    else
        local prefix=""
        case "$STRATEGY" in
            match12) prefix=$(echo "$TARGET_IP" | cut -d: -f1): ;;
            match28) prefix=$(echo "$TARGET_IP" | cut -d: -f1-2): ;;
            match48) prefix=$(echo "$TARGET_IP" | cut -d: -f1-3): ;;
            match8)  prefix="$(echo $TARGET_IP | cut -d. -f1)." ;;
            match16) prefix="$(echo $TARGET_IP | cut -d. -f1-2)." ;;
            match24) prefix="$(echo $TARGET_IP | cut -d. -f1-3)." ;;
        esac
        
        for ip in $current_ips; do
            if [[ "$ip" == "$prefix"* ]] && [ "$ip" != "$TARGET_IP" ]; then
                new_ip="$ip"
                break
            fi
        done
    fi
    
    echo "$new_ip"
}

# 主循环
log "DDNS 自动切换脚本启动 (类型: $DDNS_TYPE, 目标: $TARGET_IP, 策略: $STRATEGY)"
while true; do
    if ! ip_exists "$TARGET_IP"; then
        log "当前出口IP $TARGET_IP 在系统中不存在，正在扫描备用IP..."
        new_ip=$(find_new_ip)
        if [ -n "$new_ip" ]; then
            update_config_ip "$TARGET_IP" "$new_ip"
            TARGET_IP="$new_ip"
        else
            log "错误：未找到可用IP，保持当前配置"
        fi
    fi
    sleep "$CHECK_INTERVAL"
done
EOFDDNS

    # 替换模板变量
    sed -i "s|__WORKDIR__|$XRAY_WORKDIR|g" "$XRAY_DDNS_SCRIPT"
    sed -i "s/__DDNS_TYPE__/$XRAY_DDNS_TYPE/g" "$XRAY_DDNS_SCRIPT"
    sed -i "s/__TARGET_IP__/$XRAY_DDNS_TARGET_IP/g" "$XRAY_DDNS_SCRIPT"
    sed -i "s/__STRATEGY__/$XRAY_DDNS_STRATEGY/g" "$XRAY_DDNS_SCRIPT"
    sed -i "s/__CHECK_INTERVAL__/$XRAY_DDNS_CHECK_INTERVAL/g" "$XRAY_DDNS_SCRIPT"
    
    chmod +x "$XRAY_DDNS_SCRIPT"
    
    # 创建 DDNS 配置目录
    mkdir -p "${XRAY_WORKDIR}/ddns"
    echo "$XRAY_DDNS_TYPE $XRAY_DDNS_TARGET_IP $XRAY_DDNS_STRATEGY" > "${XRAY_WORKDIR}/ddns/ddns.config"
    
    echo -e "${GREEN}DDNS 切换脚本已生成: $XRAY_DDNS_SCRIPT${NC}"
}

# ---------- 生成 MTU 设置脚本 ----------
generate_mtu_script() {
    if [[ -z "$XRAY_MTU_IFACE" || -z "$XRAY_MTU_VALUE" ]]; then
        return
    fi
    echo -e "${CYAN}[*] 生成 MTU 设置脚本...${NC}"
    
    cat > "$XRAY_MTU_SCRIPT" <<EOF
#!/usr/bin/env bash
# 设置网卡 MTU（在 Xray 启动前执行）
/sbin/ip link set dev $XRAY_MTU_IFACE mtu $XRAY_MTU_VALUE
echo "[$(date)] MTU for $XRAY_MTU_IFACE set to $XRAY_MTU_VALUE"
EOF
    chmod +x "$XRAY_MTU_SCRIPT"
    
    echo -e "${GREEN}MTU 脚本已生成: $XRAY_MTU_SCRIPT${NC}"
}

# ---------- 生成启动脚本 ----------
generate_startup_script() {
    echo -e "${CYAN}[*] 生成 xrayinit 启动脚本...${NC}"
    
    local init_script="${XRAY_WORKDIR}/xrayinit"
    
    cat > "$init_script" <<EOF
#!/bin/bash
# Xray + sni-filter 启动脚本

WORKDIR="$XRAY_WORKDIR"
SNI_FILTER="$SNI_FILTER_BIN"
XRAY_BIN="$XRAY_BIN"
CONFIG_SNI="$XRAY_CONFIG_SNI"
SOCKET_DIR="$XRAY_SOCKET_DIR"
LISTEN_ADDR="0.0.0.0"
LISTEN_PORT=$XRAY_LISTEN_PORT
SNI_DOMAIN="$XRAY_SNI"

# 确保 socket 目录存在
mkdir -p "\$SOCKET_DIR"
chown xrayuser:xrayuser "\$SOCKET_DIR"

# 清理旧 socket 文件
rm -f "\${SOCKET_DIR}/xray.sock"

# 启动 sni-filter（监听端口，根据 SNI 转发到 Unix Socket）
# -L: 监听地址:端口
# -F: 转发的 Unix Socket
# -S: 允许的 SNI 域名
echo "[xrayinit] 启动 sni-filter..."
setsid "\$SNI_FILTER" \\
    -L="tcp://\${LISTEN_ADDR}:\${LISTEN_PORT}" \\
    -F="unix://\${SOCKET_DIR}/xray.sock" \\
    -S="\$SNI_DOMAIN" &
SNI_PID=\$!
echo "[xrayinit] sni-filter 已启动 (PID: \$SNI_PID)"

# 等待 socket 就绪
sleep 1

# 启动 Xray（监听 Unix Socket）
echo "[xrayinit] 启动 Xray..."
setsid "\$XRAY_BIN" -c "\$CONFIG_SNI" &
XRAY_PID=\$!
echo "[xrayinit] Xray 已启动 (PID: \$XRAY_PID)"

# 保存 PID
echo "\$SNI_PID" > "\${WORKDIR}/sni-filter.pid"
echo "\$XRAY_PID" > "\${WORKDIR}/xray.pid"
echo "on" > "\${WORKDIR}/statusfilter"

echo "[xrayinit] 启动完成"
EOF
    
    chmod 755 "$init_script"
    chown xrayuser:xrayuser "$init_script"
    
    echo -e "${GREEN}启动脚本已生成: $init_script${NC}"
}

# ---------- 保存环境配置 ----------
save_env() {
    mkdir -p /etc/xray
    cat > "$XRAY_ENV_FILE" <<EOF
# Xray 部署环境配置
LISTEN_PORT=$XRAY_LISTEN_PORT
SNI=$XRAY_SNI
PRIVATE_KEY=$XRAY_PRIVATE_KEY
PUBLIC_KEY=$XRAY_PUBLIC_KEY
SHORT_ID=$XRAY_SHORT_ID
UUID=$XRAY_UUID
FINGERPRINT=$XRAY_FINGERPRINT
OUTBOUND_MODE=$XRAY_OUTBOUND_MODE
SEND_THROUGH_IPV4=$XRAY_SEND_THROUGH_IPV4
SEND_THROUGH_IPV6=$XRAY_SEND_THROUGH_IPV6
IP_VERSION=$XRAY_IP_VERSION
USE_IPV6_PRIORITY=$XRAY_USE_IPV6_PRIORITY
ENABLE_DDNS=$XRAY_ENABLE_DDNS
MTU_IFACE=$XRAY_MTU_IFACE
MTU_VALUE=$XRAY_MTU_VALUE
WORKDIR=$XRAY_WORKDIR
SNI_FILTER_BIN=$SNI_FILTER_BIN
CONFIG_SNI=$XRAY_CONFIG_SNI
CONFIG_OLD=$XRAY_CONFIG_OLD
EOF
    echo -e "${GREEN}环境配置已保存: $XRAY_ENV_FILE${NC}"
}

# ---------- 创建 Systemd 服务 ----------
create_systemd_services() {
    echo -e "${CYAN}[*] 创建 Systemd 服务...${NC}"
    
    # Xray 主服务
    cat > /etc/systemd/system/xray-reality.service << 'EOF'
[Unit]
Description=Xray Reality Service (with sni-filter)
After=network.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
Group=root
ExecStart=/bin/bash __WORKDIR__/xrayinit
ExecStop=/bin/bash -c 'kill $(cat __WORKDIR__/sni-filter.pid) 2>/dev/null; kill $(cat __WORKDIR__/xray.pid) 2>/dev/null; rm -f __WORKDIR__/statusfilter'
ExecReload=/bin/kill -HUP $(cat __WORKDIR__/xray.pid) 2>/dev/null
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # 设置 MTU ExecStartPre（如果启用）
    local mtu_line=""
    if [[ -n "$XRAY_MTU_IFACE" && -n "$XRAY_MTU_VALUE" ]]; then
        mtu_line="ExecStartPre=-/sbin/ip link set dev $XRAY_MTU_IFACE mtu $XRAY_MTU_VALUE"
    fi
    
    sed -i "s|__WORKDIR__|$XRAY_WORKDIR|g" /etc/systemd/system/xray-reality.service
    if [[ -n "$mtu_line" ]]; then
        sed -i "/^ExecStart=/a $mtu_line" /etc/systemd/system/xray-reality.service
    fi
    
    # DDNS 服务（如果启用）
    if [[ "$XRAY_ENABLE_DDNS" == "yes" ]]; then
        cat > /etc/systemd/system/xray-ddns.service << 'EOF'
[Unit]
Description=Xray DDNS Auto Switch
After=xray-reality.service
Requires=xray-reality.service

[Service]
Type=simple
User=root
ExecStart=__DDNS_SCRIPT__
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        sed -i "s|__DDNS_SCRIPT__|$XRAY_DDNS_SCRIPT|g" /etc/systemd/system/xray-ddns.service
    fi
    
    systemctl daemon-reload
    echo -e "${GREEN}Systemd 服务已创建${NC}"
}

# ---------- 生成管理命令 ----------
generate_management_commands() {
    echo -e "${CYAN}[*] 生成管理命令...${NC}"
    
    # 创建管理脚本目录
    local mgmt_dir="${XRAY_WORKDIR}/mgmt"
    mkdir -p "$mgmt_dir"
    
    # chaguuid - 更换 UUID
    cat > "${mgmt_dir}/chaguuid" <<'EOF'
#!/bin/bash
WORKDIR="__WORKDIR__"
BIN="$WORKDIR/xray"
CONFIG_SNI="__CONFIG_SNI__"
CONFIG_OLD="__CONFIG_OLD__"
OLD_UUID_FILE="$WORKDIR/uuid.txt"

# 读取旧 UUID
if [[ -f "$OLD_UUID_FILE" ]]; then
    olduuid=$(cat "$OLD_UUID_FILE")
else
    echo "UUID 记录文件不存在，请手动检查配置"
    exit 1
fi

# 生成新 UUID
newuuid=$($BIN uuid)
echo "新 UUID: $newuuid"

# 替换配置中的 UUID
sed -i "s/$olduuid/$newuuid/g" "$CONFIG_SNI" "$CONFIG_OLD"

# 保存新 UUID
echo -n "$newuuid" > "$OLD_UUID_FILE"

# 重启服务
systemctl restart xray-reality

# 输出分享链接
echo "UUID 已更新！"
EOF
    
    sed -i "s|__WORKDIR__|$XRAY_WORKDIR|g" "${mgmt_dir}/chaguuid"
    sed -i "s|__CONFIG_SNI__|$XRAY_CONFIG_SNI|g" "${mgmt_dir}/chaguuid"
    sed -i "s|__CONFIG_OLD__|$XRAY_CONFIG_OLD|g" "${mgmt_dir}/chaguuid"
    
    # delxray - 卸载
    cat > "${mgmt_dir}/delxray" <<'EOF'
#!/bin/bash
echo "正在卸载 Xray Reality 服务..."
systemctl stop xray-reality xray-ddns 2>/dev/null
systemctl disable xray-reality xray-ddns 2>/dev/null
rm -f /etc/systemd/system/xray-reality.service /etc/systemd/system/xray-ddns.service
systemctl daemon-reload
killall xray sni-filter 2>/dev/null
rm -f /usr/bin/xray.*
rm -rf __WORKDIR__
echo "卸载完成"
EOF
    sed -i "s|__WORKDIR__|$XRAY_WORKDIR|g" "${mgmt_dir}/delxray"
    
    # stop / start / restart
    for cmd in stop start restart; do
        cat > "${mgmt_dir}/xray${cmd}" <<EOF
#!/bin/bash
systemctl ${cmd} xray-reality
echo "Xray 已${cmd}"
EOF
    done
    
    # help
    cat > "${mgmt_dir}/xrayhelp" <<'EOF'
#!/bin/bash
echo "===== Xray 管理命令 ====="
echo "xray.chuuid   - 更换 UUID"
echo "xray.delxray  - 完全卸载"
echo "xray.stop     - 停止服务"
echo "xray.start    - 启动服务"
echo "xray.restart  - 重启服务"
echo "xray.status   - 查看状态"
echo "xray.log      - 查看日志"
echo "xray.info     - 显示连接信息"
echo "xray.help     - 显示此帮助"
EOF
    
    # info - 显示连接信息
    cat > "${mgmt_dir}/xrayinfo" <<'EOF'
#!/bin/bash
source /etc/xray/env.conf 2>/dev/null
echo "===== Xray 连接信息 ====="
LOCAL_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s6 ifconfig.me 2>/dev/null || echo "$SEND_THROUGH_IPV4")
echo "地址: $LOCAL_IP"
echo "端口: $LISTEN_PORT"
echo "UUID: $UUID"
echo "SNI: $SNI"
echo "Flow: xtls-rprx-vision"
echo "Security: reality"
echo "Fingerprint: $FINGERPRINT"
echo "PublicKey: $PUBLIC_KEY"
echo "ShortId: $SHORT_ID"
echo "出口IPv4: ${SEND_THROUGH_IPV4:-未使用}"
echo "出口IPv6: ${SEND_THROUGH_IPV6:-未使用}"
echo "MTU: ${MTU_IFACE:-未设置} ${MTU_VALUE:-}"
echo "DDNS: ${ENABLE_DDNS:-未启用}"
echo "=========================="
ENCODED_PK=$(echo -n "$PUBLIC_KEY" | sed 's/+/%2B/g' | sed 's/\//%2F/g' | sed 's/=/%3D/g')
echo "vless://$UUID@$LOCAL_IP:$LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=$FINGERPRINT&pbk=$ENCODED_PK&sid=$SHORT_ID&spx=%2F#VLESS-REALITY"
EOF
    
    chmod 755 "${mgmt_dir}"/*
    chown -R xrayuser:xrayuser "${mgmt_dir}"
    
    # 创建软链接到 /usr/bin
    ln -sf "${mgmt_dir}/chaguuid" /usr/bin/xray.chuuid
    ln -sf "${mgmt_dir}/delxray" /usr/bin/xray.delxray
    ln -sf "${mgmt_dir}/xraystop" /usr/bin/xray.stop
    ln -sf "${mgmt_dir}/xraystart" /usr/bin/xray.start
    ln -sf "${mgmt_dir}/xrayrestart" /usr/bin/xray.restart
    ln -sf "${mgmt_dir}/xrayhelp" /usr/bin/xray.help
    ln -sf "${mgmt_dir}/xrayinfo" /usr/bin/xray.info
    ln -sf "/usr/bin/systemctl" /usr/bin/xray.status 2>/dev/null || true
    
    echo -e "${GREEN}管理命令已安装:${NC}"
    echo -e "  ${CYAN}xray.chuuid${NC}    - 更换 UUID"
    echo -e "  ${CYAN}xray.delxray${NC}   - 完全卸载"
    echo -e "  ${CYAN}xray.stop${NC}      - 停止服务"
    echo -e "  ${CYAN}xray.start${NC}     - 启动服务"
    echo -e "  ${CYAN}xray.restart${NC}   - 重启服务"
    echo -e "  ${CYAN}xray.status${NC}    - 查看状态"
    echo -e "  ${CYAN}xray.info${NC}      - 显示连接信息"
    echo -e "  ${CYAN}xray.help${NC}      - 帮助"
}

# ---------- 启动服务 ----------
start_services() {
    echo -e "${CYAN}[*] 启动服务...${NC}"
    
    # 如果启用了 MTU，先执行一次
    if [[ -f "$XRAY_MTU_SCRIPT" ]]; then
        bash "$XRAY_MTU_SCRIPT"
    fi
    
    # 保存 UUID 记录
    echo -n "$XRAY_UUID" > "${XRAY_WORKDIR}/uuid.txt"
    chown xrayuser:xrayuser "${XRAY_WORKDIR}/uuid.txt"
    
    # 启用并启动主服务
    systemctl enable xray-reality
    systemctl start xray-reality
    sleep 3
    
    if systemctl is-active xray-reality &>/dev/null; then
        echo -e "${GREEN}Xray + sni-filter 运行正常${NC}"
    else
        echo -e "${RED}服务启动失败，请检查日志: journalctl -u xray-reality -n 50${NC}"
        exit 1
    fi
    
    # 启动 DDNS 服务
    if [[ "$XRAY_ENABLE_DDNS" == "yes" ]]; then
        systemctl enable xray-ddns
        systemctl start xray-ddns
        echo -e "${GREEN}DDNS 自动切换服务已启动${NC}"
    fi
}

# ---------- 输出客户端配置 ----------
print_client_info() {
    # 获取本机IP
    LOCAL_IP=""
    if [[ "$XRAY_USE_IPV6_PRIORITY" == "yes" && -n "$XRAY_SEND_THROUGH_IPV6" ]]; then
        LOCAL_IP=$(curl -s6 ifconfig.me 2>/dev/null || curl -s6 icanhazip.com 2>/dev/null || echo "$XRAY_SEND_THROUGH_IPV6")
    elif [[ -n "$XRAY_SEND_THROUGH_IPV4" ]]; then
        LOCAL_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null || echo "$XRAY_SEND_THROUGH_IPV4")
    else
        LOCAL_IP=$(curl -s ifconfig.me 2>/dev/null || echo "无法获取公网IP")
    fi
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  部署完成！客户端连接信息${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  ${YELLOW}VLESS + REALITY 客户端配置：${NC}"
    echo -e "  服务器地址: ${CYAN}$LOCAL_IP${NC}"
    echo -e "  端口: ${CYAN}$XRAY_LISTEN_PORT${NC}"
    echo -e "  UUID: ${CYAN}$XRAY_UUID${NC}"
    echo -e "  Flow: ${CYAN}xtls-rprx-vision${NC}"
    echo -e "  Security: ${CYAN}reality${NC}"
    echo -e "  SNI: ${CYAN}$XRAY_SNI${NC}"
    echo -e "  Fingerprint: ${CYAN}$XRAY_FINGERPRINT${NC}"
    echo -e "  PublicKey: ${CYAN}$XRAY_PUBLIC_KEY${NC}"
    echo -e "  ShortId: ${CYAN}$XRAY_SHORT_ID${NC}"
    echo ""
    echo -e "  ${YELLOW}分享链接 (vless):${NC}"
    ENCODED_PK=$(echo -n "$XRAY_PUBLIC_KEY" | sed 's/+/%2B/g' | sed 's/\//%2F/g' | sed 's/=/%3D/g')
    echo -e "  vless://$XRAY_UUID@$LOCAL_IP:$XRAY_LISTEN_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$XRAY_SNI&fp=$XRAY_FINGERPRINT&pbk=$ENCODED_PK&sid=$XRAY_SHORT_ID&spx=%2F#VLESS-REALITY-$(hostname)"
    echo ""
    echo -e "  ${YELLOW}管理命令:${NC}"
    echo -e "    ${CYAN}xray.info${NC}        - 显示连接信息"
    echo -e "    ${CYAN}xray.chuuid${NC}      - 更换 UUID"
    echo -e "    ${CYAN}xray.restart${NC}     - 重启服务"
    echo -e "    ${CYAN}xray.stop${NC}        - 停止服务"
    echo -e "    ${CYAN}xray.status${NC}      - 查看状态"
    echo -e "    ${CYAN}xray.delxray${NC}     - 完全卸载"
    echo ""
    echo -e "  ${YELLOW}架构说明:${NC}"
    echo -e "    sni-filter 监听端口 → 匹配 SNI → Unix Socket → Xray"
    echo -e "    非目标 SNI 的流量会被 sni-filter 直接拒绝"
    echo ""
    echo -e "${GREEN}========================================${NC}"
}

# ========== 主流程 ==========
main() {
    clear
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║     Xray-core VLESS + REALITY 一键部署脚本      ║"
    echo "║  集成 sni-filter · DDNS切换 · MTU调整 · 指纹   ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_root
    detect_arch
    install_deps
    detect_public_ips
    select_outbound_ips
    install_xray
    install_sni_filter
    setup_workdir
    generate_keys
    interactive_config
    generate_configs
    generate_ddns_script
    generate_mtu_script
    generate_startup_script
    save_env
    create_systemd_services
    generate_management_commands
    start_services
    print_client_info
    
    echo -e "${GREEN}✅ 全部部署完成！${NC}"
    echo -e "${YELLOW}提示：请使用 xray.info 查看连接信息，xray.help 查看所有命令。${NC}"
}

main "$@"