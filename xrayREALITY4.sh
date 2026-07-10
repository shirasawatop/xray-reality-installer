#!/bin/bash
# ============================================================================
# Xray REALITY / VLESS Encryption 二合一部署脚本 (重构版)
# 基于原版 v20260710 重构，增强健壮性与可维护性
# ============================================================================
set -eo pipefail
shopt -s nullglob

# ============================================================================
# 常量与默认值
# ============================================================================
readonly SCRIPT_VER="v20260710-r1"
readonly XRAY_VER="v25.10.15"
readonly XRAY_URL_BASE="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}"
readonly SNI_FILTER_URL="https://github.com/shirasawatop/REALITY-sni-filter/releases/download/v0.2/autobuild.zip"

readonly DEFAULT_PORT=443
readonly DEFAULT_LISTEN="0.0.0.0"
readonly DEFAULT_DOMAIN="tesla.com"
readonly DEFAULT_FP="chrome"
readonly DEFAULT_MTU=1390
readonly DEFAULT_MTU_IF="eth0"
readonly DEFAULT_TICKET="600s"
readonly DEFAULT_APPEARANCE="random"
readonly DEFAULT_KEY_MODE="mlkem768"
readonly DEFAULT_RTT="0rtt"

# 颜色
readonly C_RED='\e[31m'
readonly C_GREEN='\e[32m'
readonly C_YELLOW='\e[33m'
readonly C_CYAN='\e[36m'
readonly C_NC='\e[0m'

# 全局状态
PROTOCOL=""                     # "reality" | "encryption"
WORKDIR=""
ARCH=""
CONFIG_FILE=""                  # 实际使用的配置文件路径
PIDFILE_XRAY=""
PIDFILE_SNI=""
SERVICE_NAME="xray_service"

# REALITY 变量
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_DOMAIN="$DEFAULT_DOMAIN"
REALITY_FP="$DEFAULT_FP"

# Encryption 变量
ENC_KEY_MODE="$DEFAULT_KEY_MODE"
ENC_APPEARANCE="$DEFAULT_APPEARANCE"
ENC_RTT="$DEFAULT_RTT"
ENC_TICKET="$DEFAULT_TICKET"
ENC_SERVER_KEY=""
ENC_CLIENT_KEY=""
ENC_DECRYPTION_STR=""
ENC_ENCRYPTION_STR=""

# 网络变量
IPADDR="$DEFAULT_LISTEN"
PORT="$DEFAULT_PORT"
IPV4_OUT=""
IPV6_OUT=""
IPV6_PRIORITY="yes"

# DDNS 变量
DDNS_ENABLED="no"
DDNS_TYPE=""
DDNS_TARGET_IP=""
DDNS_STRATEGY=""

# MTU 变量
MTU_ENABLED="no"
MTU_IF="$DEFAULT_MTU_IF"
MTU_VAL="$DEFAULT_MTU"

# UUID
UUID=""

# ============================================================================
# 工具函数
# ============================================================================
die() { echo -e "${C_RED}[错误] $*${C_NC}" >&2; exit 1; }
warn() { echo -e "${C_YELLOW}[警告] $*${C_NC}" >&2; }
info() { echo -e "${C_GREEN}[信息] $*${C_NC}"; }
banner_line() { echo -e "${C_CYAN}$*${C_NC}"; }

check_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "缺少命令: $cmd，请先安装"
    done
}

check_net() {
    ping -c 2 -W 3 8.8.8.8 &>/dev/null || die "无网络连接，请检查网络后重试"
}

has_whiptail() { command -v whiptail &>/dev/null; }

# 安全停止进程（基于 pidfile）
safe_kill() {
    local pidfile="$1" name="$2"
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            # 等待最多 5 秒
            for _ in {1..10}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.5
            done
            # 仍未退出则强制
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
    # 兜底：仅清理当前 WORKDIR 下的残留进程
    pgrep -f "${WORKDIR}/xray" 2>/dev/null | xargs -r kill 2>/dev/null || true
}

# URL 编码（优先用 jq，回退到 perl/python）
urlencode() {
    local str="$1"
    if command -v jq &>/dev/null; then
        echo -n "$str" | jq -sRr @uri
    elif command -v python3 &>/dev/null; then
        python3 -c "import urllib.parse; print(urllib.parse.quote('$str', safe=''))"
    elif command -v perl &>/dev/null; then
        perl -MURI::Escape -e "print uri_escape('$str');"
    else
        # 简单回退
        echo -n "$str" | sed 's/+/%2B/g; s/\./%2E/g'
    fi
}

# ============================================================================
# 系统检测
# ============================================================================
detect_arch() {
    case "$(uname -m)" in
        x86_64)     ARCH="amd64";;
        i386|i686)  ARCH="386";;
        aarch64)    ARCH="arm64-v8a";;
        *)          die "不支持的架构: $(uname -m)";;
    esac
}

detect_ips() {
    info "正在检测系统网络配置..."
    echo ""

    banner_line "检测到的 IPv4 地址:"
    local count=0
    declare -gA IPV4_MAP=()
    while IFS= read -r line; do
        local iface="${line%% *}" ip="${line##* }"
        [[ "$iface" =~ ^(lo|docker|br-|veth) ]] && continue
        IPV4_MAP["$iface"]="$ip"
        count=$((count + 1))
        echo "  [$count] $iface: $ip"
    done < <(ip -4 addr show 2>/dev/null | awk '/inet /{print $NF, $2}' | sed 's|/.*||')
    if [ "$count" -eq 0 ]; then echo "  (未检测到)"; fi

    echo ""
    banner_line "检测到的 IPv6 地址:"
    count=0
    declare -gA IPV6_MAP=()
    while IFS= read -r line; do
        local iface="${line%% *}" ip="${line##* }"
        [[ "$iface" =~ ^(lo|docker|br-|veth) ]] && continue
        [[ "$ip" =~ ^fe80: ]] && continue
        [[ "$ip" == "::1" ]] && continue
        IPV6_MAP["$iface"]="$ip"
        count=$((count + 1))
        echo "  [$count] $iface: $ip"
    done < <(ip -6 addr show 2>/dev/null | awk '/inet6 /{print $NF, $2}' | sed 's|/.*||')
    if [ "$count" -eq 0 ]; then echo "  (未检测到)"; fi
    echo ""
}

# ============================================================================
# 用户交互
# ============================================================================
choose_protocol() {
    echo -e "${C_YELLOW}╔══════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_YELLOW}║          ⚠️  重要提示                          ║${C_NC}"
    echo -e "${C_YELLOW}║                                                ║${C_NC}"
    echo -e "${C_YELLOW}║  REALITY 和 VLESS Encryption 是两种不同的       ║${C_NC}"
    echo -e "${C_YELLOW}║  传输安全方案，不能在同一条 inbound 中共存！     ║${C_NC}"
    echo -e "${C_YELLOW}║                                                ║${C_NC}"
    echo -e "${C_YELLOW}║  • REALITY: 伪装成访问知名网站，抗主动探测最强  ║${C_NC}"
    echo -e "${C_YELLOW}║  • Encryption: 自带加密+抗量子，适合CDN/中转   ║${C_NC}"
    echo -e "${C_YELLOW}╚══════════════════════════════════════════════════╝${C_NC}"
    echo ""

    if has_whiptail; then
        PROTOCOL=$(whiptail --title "协议选择" --menu "请选择传输安全协议（两者不可共存）" \
            18 60 2 \
            "reality"    "REALITY - 伪装网站，抗主动探测" \
            "encryption" "VLESS Encryption - 自带加密，抗量子" \
            3>&1 1>&2 2>&3) || die "未选择协议，退出安装"
    else
        echo "请选择协议:"
        echo "  1) REALITY - 伪装网站，抗主动探测"
        echo "  2) VLESS Encryption - 自带加密，抗量子"
        read -rp "请输入 (1/2): " choice
        case "$choice" in
            1) PROTOCOL="reality";;
            2) PROTOCOL="encryption";;
            *) die "无效选择";;
        esac
    fi
    info "已选择: $([ "$PROTOCOL" = "reality" ] && echo "REALITY" || echo "VLESS Encryption")"
}

configure_network() {
    echo ""
    # IPv6 优先
    if has_whiptail; then
        whiptail --title "IPv6 优先" --yesno "是否优先使用 IPv6 出口？" 10 50 \
            && IPV6_PRIORITY="yes" || IPV6_PRIORITY="no"
    else
        read -rp "是否优先使用 IPv6 出口？(y/n): " ans
        [[ "$ans" =~ ^[Yy] ]] && IPV6_PRIORITY="yes" || IPV6_PRIORITY="no"
    fi
    info "IPv6 优先: $IPV6_PRIORITY"

    # IPv4 出口
    if [ ${#IPV4_MAP[@]} -gt 0 ]; then
        echo ""
        info "选择 IPv4 出口地址:"
        local choices=()
        for iface in "${!IPV4_MAP[@]}"; do choices+=("$iface" "${IPV4_MAP[$iface]}"); done
        choices+=("manual" "手动输入" "none" "不使用 IPv4")
        if has_whiptail; then
            IPV4_OUT=$(whiptail --title "IPv4 出口" --menu "选择 IPv4 出口" 15 60 0 \
                "${choices[@]}" 3>&1 1>&2 2>&3) || true
        else
            local i=1
            for iface in "${!IPV4_MAP[@]}"; do echo "  $i) $iface: ${IPV4_MAP[$iface]}"; ((i++)); done
            echo "  $i) 手动输入"; ((i++)); echo "  $i) 不使用 IPv4"
            read -rp "请选择: " c; local idx=1
            for iface in "${!IPV4_MAP[@]}"; do
                [ "$idx" -eq "$c" ] && { IPV4_OUT="${IPV4_MAP[$iface]}"; break; }; ((idx++))
            done
            [ "$idx" -eq "$c" ] && read -rp "输入地址: " IPV4_OUT
        fi
        case "$IPV4_OUT" in none|"") IPV4_OUT="";; manual) read -rp "输入 IPv4: " IPV4_OUT;; esac
    else
        read -rp "未检测到 IPv4，手动输入（留空跳过）: " IPV4_OUT
    fi
    [ -n "$IPV4_OUT" ] && info "IPv4 出口: $IPV4_OUT" || info "不使用 IPv4 出口"

    # IPv6 出口
    if [ ${#IPV6_MAP[@]} -gt 0 ]; then
        echo ""
        info "选择 IPv6 出口地址:"
        local choices=()
        for iface in "${!IPV6_MAP[@]}"; do choices+=("$iface" "${IPV6_MAP[$iface]}"); done
        choices+=("manual" "手动输入" "none" "不使用 IPv6")
        if has_whiptail; then
            IPV6_OUT=$(whiptail --title "IPv6 出口" --menu "选择 IPv6 出口" 15 60 0 \
                "${choices[@]}" 3>&1 1>&2 2>&3) || true
        else
            local i=1
            for iface in "${!IPV6_MAP[@]}"; do echo "  $i) $iface: ${IPV6_MAP[$iface]}"; ((i++)); done
            echo "  $i) 手动输入"; ((i++)); echo "  $i) 不使用 IPv6"
            read -rp "请选择: " c; local idx=1
            for iface in "${!IPV6_MAP[@]}"; do
                [ "$idx" -eq "$c" ] && { IPV6_OUT="${IPV6_MAP[$iface]}"; break; }; ((idx++))
            done
            [ "$idx" -eq "$c" ] && read -rp "输入地址: " IPV6_OUT
        fi
        case "$IPV6_OUT" in none|"") IPV6_OUT="";; manual) read -rp "输入 IPv6: " IPV6_OUT;; esac
    else
        read -rp "未检测到 IPv6，手动输入（留空跳过）: " IPV6_OUT
    fi
    [ -n "$IPV6_OUT" ] && info "IPv6 出口: $IPV6_OUT" || info "不使用 IPv6 出口"
}

configure_ddns() {
    DDNS_ENABLED="no"
    if has_whiptail; then
        whiptail --title "DDNS" --yesno "是否开启出口 IP 丢失后自动更换功能？" 10 50 || return
    else
        read -rp "开启 DDNS 自动更换 IP？(y/n): " ans
        [[ "$ans" =~ ^[Yy] ]] || return
    fi

    local choices=()
    [ -n "$IPV6_OUT" ] && choices+=("ipv6" "IPv6 出口")
    [ -n "$IPV4_OUT" ] && choices+=("ipv4" "IPv4 出口")
    [ ${#choices[@]} -eq 0 ] && { warn "无可用出口，跳过 DDNS"; return; }

    local ddns_choice
    if has_whiptail; then
        ddns_choice=$(whiptail --title "DDNS 类型" --menu "选择监控类型" 15 50 2 \
            "${choices[@]}" 3>&1 1>&2 2>&3) || return
    else
        echo "选择监控类型:"
        local i=1
        for ((j=0; j<${#choices[@]}; j+=2)); do echo "  $i) ${choices[$j]}"; ((i++)); done
        read -rp "请选择: " c
        ddns_choice="${choices[$(( (c-1)*2 ))]}"
    fi

    case "$ddns_choice" in
        ipv6)
            DDNS_TYPE="ipv6"; DDNS_TARGET_IP="$IPV6_OUT"
            local p12="${IPV6_OUT%%:*}:"
            local p28="${IPV6_OUT%%:*:*}:"
            local p48="${IPV6_OUT%%:*:*:*}:"
            local strat_choices=("match12" "$p12 开头" "match28" "$p28 开头" "match48" "$p48 开头" "any" "任意不同 IPv6")
            ;;
        ipv4)
            DDNS_TYPE="ipv4"; DDNS_TARGET_IP="$IPV4_OUT"
            local a8="${IPV4_OUT%%.*}." a16="${IPV4_OUT%.*.*}." a24="${IPV4_OUT%.*}."
            local strat_choices=("match8" "$a8 开头" "match16" "$a16 开头" "match24" "$a24 开头" "any" "任意不同 IPv4")
            ;;
    esac

    if has_whiptail; then
        DDNS_STRATEGY=$(whiptail --title "匹配策略" --menu "选择匹配策略" 15 50 4 \
            "${strat_choices[@]}" 3>&1 1>&2 2>&3) || return
    else
        echo "选择匹配策略:"
        for ((j=0; j<${#strat_choices[@]}; j+=2)); do echo "  $((j/2+1)) ${strat_choices[$j]}"; done
        read -rp "请选择: " c
        DDNS_STRATEGY="${strat_choices[$(( (c-1)*2 ))]}"
    fi
    DDNS_ENABLED="yes"
    info "DDNS 已启用: $DDNS_TYPE, 策略=$DDNS_STRATEGY"
}

configure_mtu() {
    MTU_ENABLED="no"
    if has_whiptail; then
        whiptail --title "MTU" --yesno "是否开启 MTU 自动调整？\n（修复部分隧道环境下连接失败，推荐 1390）" 12 60 \
            || return
    else
        read -rp "开启 MTU 调整？(y/n): " ans
        [[ "$ans" =~ ^[Yy] ]] || return
    fi
    MTU_ENABLED="yes"
    read -rp "网络接口 (默认 $DEFAULT_MTU_IF): " input_if
    [ -n "$input_if" ] && MTU_IF="$input_if"
    read -rp "MTU 值 (默认 $DEFAULT_MTU): " input_mtu
    [ -n "$input_mtu" ] && MTU_VAL="$input_mtu"
    info "MTU: $MTU_IF mtu $MTU_VAL"
}

configure_protocol_params() {
    read -rp "监听 IP (默认 $DEFAULT_LISTEN): " IPADDR
    [ -z "$IPADDR" ] && IPADDR="$DEFAULT_LISTEN"
    read -rp "监听端口 (默认 $DEFAULT_PORT): " PORT
    [ -z "$PORT" ] && PORT="$DEFAULT_PORT"

    if [ "$PROTOCOL" = "reality" ]; then
        read -rp "伪装域名 (默认 $DEFAULT_DOMAIN): " REALITY_DOMAIN
        [ -z "$REALITY_DOMAIN" ] && REALITY_DOMAIN="$DEFAULT_DOMAIN"
        local fp_choices=("chrome" "Chrome" "firefox" "Firefox" "safari" "Safari" "ios" "iOS" "edge" "Edge")
        if has_whiptail; then
            REALITY_FP=$(whiptail --title "浏览器指纹" --menu "选择指纹" 15 50 5 \
                "${fp_choices[@]}" 3>&1 1>&2 2>&3) || REALITY_FP="$DEFAULT_FP"
        else
            echo "选择指纹: 1)chrome 2)firefox 3)safari 4)ios 5)edge"
            read -rp "请选择 (默认 chrome): " c
            case "$c" in 2) REALITY_FP="firefox";; 3) REALITY_FP="safari";; 4) REALITY_FP="ios";; 5) REALITY_FP="edge";; *) REALITY_FP="chrome";; esac
        fi
        [ -z "$REALITY_FP" ] && REALITY_FP="$DEFAULT_FP"
        info "REALITY: $IPADDR:$PORT sni=$REALITY_DOMAIN fp=$REALITY_FP"
    else
        echo ""
        echo -e "${C_YELLOW}VLESS Encryption 配置选项:${C_NC}"
        echo "  密钥模式: ① mlkem768 (抗量子)  ② x25519 (传统)"
        echo "  外观模式: ① native (最佳性能)  ② xorpub (隐藏特征)  ③ random (最隐蔽)"
        echo "  RTT模式:  ① 0rtt (更快)       ② 1rtt (更安全)"
        echo ""

        select km in "mlkem768（抗量子，推荐）" "x25519（传统）"; do
            case "$km" in
                "mlkem768"*) ENC_KEY_MODE="mlkem768"; break;;
                "x25519"*)   ENC_KEY_MODE="x25519"; break;;
            esac
        done

        select ap in "native（原生，性能最佳）" "xorpub（XOR公钥，隐藏特征）" "random（全随机，最隐蔽）"; do
            case "$ap" in
                "native"*) ENC_APPEARANCE="native"; break;;
                "xorpub"*) ENC_APPEARANCE="xorpub"; break;;
                "random"*) ENC_APPEARANCE="random"; break;;
            esac
        done

        select rtt in "0rtt（零往返，更快）" "1rtt（每次握手，更安全）"; do
            case "$rtt" in
                "0rtt"*) ENC_RTT="0rtt"; break;;
                "1rtt"*) ENC_RTT="1rtt"; break;;
            esac
        done

        read -rp "Ticket 时长秒数 (默认 600，仅 0rtt 生效): " input_ticket
        [ -n "$input_ticket" ] && ENC_TICKET="${input_ticket}s" || ENC_TICKET="$DEFAULT_TICKET"

        info "Encryption: $IPADDR:$PORT | key=$ENC_KEY_MODE | appearance=$ENC_APPEARANCE | rtt=$ENC_RTT | ticket=$ENC_TICKET"
    fi
}

choose_landing() {
    local choice
    if has_whiptail; then
        choice=$(whiptail --title "落地方式" --menu "选择出站方式" 15 50 2 \
            "direct" "直接落地 (freedom)" \
            "socks"  "SOCKS5 落地" 3>&1 1>&2 2>&3) || choice="direct"
    else
        read -rp "落地方式: 1) 直接落地  2) SOCKS5 (默认 1): " c
        [ "$c" = "2" ] && choice="socks" || choice="direct"
    fi

    if [ "$choice" = "socks" ]; then
        read -rp "SOCKS5 服务器 IP: " SOCKS_IP
        read -rp "SOCKS5 端口: " SOCKS_PORT
        read -rp "SOCKS5 用户名: " SOCKS_USER
        read -rp "SOCKS5 密码: " SOCKS_PASS
        LANDING_TYPE="socks"
    else
        LANDING_TYPE="direct"
    fi
}

# ============================================================================
# JSON 配置生成（使用 jq）
# ============================================================================
build_outbounds_json() {
    local out="" sep=""
    if [ -n "$IPV6_OUT" ]; then
        if [ "$LANDING_TYPE" = "socks" ]; then
            out+=$(cat <<OUT
{
  "tag": "direct-ipv6",
  "protocol": "socks",
  "settings": {
    "servers": [{"address": "$SOCKS_IP", "port": $SOCKS_PORT, "users": [{"user": "$SOCKS_USER", "pass": "$SOCKS_PASS", "level": 0}]}]
  },
  "sendThrough": "$IPV6_OUT"
}
OUT
)
        else
            out+=$(cat <<OUT
{
  "tag": "direct-ipv6",
  "protocol": "freedom",
  "settings": {"domainStrategy": "UseIPv6"},
  "sendThrough": "$IPV6_OUT"
}
OUT
)
        fi
        sep=","
    fi

    if [ -n "$IPV4_OUT" ]; then
        [ -n "$sep" ] && out+="$sep"
        if [ "$LANDING_TYPE" = "socks" ]; then
            out+=$(cat <<OUT
{
  "tag": "direct-ipv4",
  "protocol": "socks",
  "settings": {
    "servers": [{"address": "$SOCKS_IP", "port": $SOCKS_PORT, "users": [{"user": "$SOCKS_USER", "pass": "$SOCKS_PASS", "level": 0}]}]
  },
  "sendThrough": "$IPV4_OUT"
}
OUT
)
        else
            out+=$(cat <<OUT
{
  "tag": "direct-ipv4",
  "protocol": "freedom",
  "settings": {"domainStrategy": "UseIPv4"},
  "sendThrough": "$IPV4_OUT"
}
OUT
)
        fi
    fi

    # 如果都没有，加一个默认 freedom
    if [ -z "$out" ]; then
        out='{"protocol": "freedom", "tag": "direct"}'
    fi

    echo "[$out]"
}

build_routing_json() {
    local routing=""
    if [ -n "$IPV6_OUT" ] && [ -n "$IPV4_OUT" ]; then
        if [ "$IPV6_PRIORITY" = "yes" ]; then
            routing=$(cat <<ROUTE
{
  "domainStrategy": "IPOnDemand",
  "rules": [
    {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]},
    {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]}
  ]
}
ROUTE
)
        else
            routing=$(cat <<ROUTE
{
  "domainStrategy": "IPOnDemand",
  "rules": [
    {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]},
    {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]}
  ]
}
ROUTE
)
        fi
    elif [ -n "$IPV6_OUT" ]; then
        routing='{"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "outboundTag": "direct-ipv6", "network": "tcp,udp"}]}'
    elif [ -n "$IPV4_OUT" ]; then
        routing='{"domainStrategy": "IPIfNonMatch", "rules": [{"type": "field", "outboundTag": "direct-ipv4", "network": "tcp,udp"}]}'
    fi
    echo "$routing"
}

build_config_json() {
    local outbounds routing
    outbounds=$(build_outbounds_json)
    routing=$(build_routing_json)

    local routing_comma=""
    [ -n "$routing" ] && routing_comma=","

    if [ "$PROTOCOL" = "reality" ]; then
        # REALITY: 监听 unix socket（由 sni-filter 转发）
        cat <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "${WORKDIR}/socket/xray.friend,0600",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "$REALITY_DOMAIN:443",
        "serverNames": ["$REALITY_DOMAIN"],
        "privateKey": "$REALITY_PRIVATE_KEY",
        "shortIds": ["$REALITY_SHORT_ID"]
      }
    }
  }],
  "outbounds": $outbounds${routing_comma}
  $routing
}
EOF
    else
        # VLESS Encryption: 直接监听端口
        cat <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": $PORT,
    "listen": "$IPADDR",
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "$ENC_DECRYPTION_STR"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "none"
    }
  }],
  "outbounds": $outbounds${routing_comma}
  $routing
}
EOF
    fi
}

# ============================================================================
# 密钥生成
# ============================================================================
generate_keys() {
    if [ "$PROTOCOL" = "reality" ]; then
        local x25519_output
        x25519_output=$("${WORKDIR}/xray" x25519)
        REALITY_PRIVATE_KEY=$(echo "$x25519_output" | grep "PrivateKey:" | awk '{print $2}')
        REALITY_PUBLIC_KEY=$(echo "$x25519_output" | grep "Password:" | awk '{print $2}')
        REALITY_SHORT_ID=$(openssl rand -hex 6)
        info "REALITY 密钥已生成"
    else
        if [ "$ENC_KEY_MODE" = "mlkem768" ]; then
            local mlkem_output
            mlkem_output=$("${WORKDIR}/xray" mlkem768)
            ENC_SERVER_KEY=$(echo "$mlkem_output" | grep "Seed:" | head -1 | awk '{print $2}')
            ENC_CLIENT_KEY=$(echo "$mlkem_output" | grep "Client:" | head -1 | awk '{print $2}')
        else
            local x25519_output
            x25519_output=$("${WORKDIR}/xray" x25519)
            ENC_SERVER_KEY=$(echo "$x25519_output" | grep "PrivateKey:" | awk '{print $2}')
            ENC_CLIENT_KEY=$(echo "$x25519_output" | grep "Password:" | awk '{print $2}')
        fi
        ENC_DECRYPTION_STR="mlkem768x25519plus.${ENC_APPEARANCE}.${ENC_TICKET}.${ENC_SERVER_KEY}"
        ENC_ENCRYPTION_STR="mlkem768x25519plus.${ENC_APPEARANCE}.${ENC_RTT}.${ENC_CLIENT_KEY}"
        info "VLESS Encryption 密钥已生成"
    fi
}

# ============================================================================
# 下载与安装
# ============================================================================
install_xray() {
    info "下载 Xray-core ${XRAY_VER}..."
    local zip_name
    case "$ARCH" in
        amd64)      zip_name="Xray-linux-64.zip";;
        386)        zip_name="Xray-linux-32.zip";;
        arm64-v8a)  zip_name="Xray-linux-arm64-v8a.zip";;
    esac
    wget -q "${XRAY_URL_BASE}/${zip_name}" -O "${WORKDIR}/xray.zip"
    unzip -o "${WORKDIR}/xray.zip" -d "$WORKDIR" >/dev/null
    rm -f "${WORKDIR}/xray.zip"
    chmod 755 "${WORKDIR}/xray"
    info "Xray-core 安装完成"
}

install_sni_filter() {
    [ "$PROTOCOL" != "reality" ] && return
    info "下载 SNI Filter..."
    wget -q "$SNI_FILTER_URL" -O "${WORKDIR}/autobuild.zip"
    unzip -o "${WORKDIR}/autobuild.zip" -d "$WORKDIR" >/dev/null
    rm -f "${WORKDIR}/autobuild.zip"
    case "$ARCH" in
        amd64)     mv "${WORKDIR}/sni-filter-amd64" "${WORKDIR}/sni-filter";;
        386)       mv "${WORKDIR}/sni-filter-i386"  "${WORKDIR}/sni-filter";;
        arm64-v8a) mv "${WORKDIR}/sni-filter-arm64" "${WORKDIR}/sni-filter";;
    esac
    chmod 755 "${WORKDIR}/sni-filter"
    setcap 'cap_net_bind_service=+ep' "${WORKDIR}/sni-filter" 2>/dev/null || true
    info "SNI Filter 安装完成"
}

# ============================================================================
# 管理脚本生成
# ============================================================================
generate_management_scripts() {
    local UUID_FILE="${WORKDIR}/uuid.txt"
    echo -n "$UUID" > "$UUID_FILE"

    # 保存协议类型
    echo "$PROTOCOL" > "${WORKDIR}/protocol.txt"

    # 保存 encryption key（仅 encryption 模式）
    [ "$PROTOCOL" = "encryption" ] && echo -n "$ENC_ENCRYPTION_STR" > "${WORKDIR}/encryption_key.txt"

    # 获取真实出口 IP
    local realip4 realip6 sub_params
    realip4=$(wget -q4 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2 || echo "")
    realip6=$(wget -q6 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2 || echo "")

    # 构建订阅参数
    if [ "$PROTOCOL" = "reality" ]; then
        sub_params="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=${REALITY_FP}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none&host=${REALITY_DOMAIN}"
    else
        local enc_encoded
        enc_encoded=$(urlencode "$ENC_ENCRYPTION_STR")
        sub_params="encryption=${enc_encoded}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none"
    fi

    # --- chaguuid ---
    cat > "${WORKDIR}/chaguuid" << EOFSCRIPT
#!/bin/bash
set -e
WORKDIR="${WORKDIR}"
CONFIG="${CONFIG_FILE}"
UUID_FILE="\${WORKDIR}/uuid.txt"
PROTOCOL_FILE="\${WORKDIR}/protocol.txt"
PROTOCOL=\$(cat "\$PROTOCOL_FILE" 2>/dev/null || echo "reality")
newuuid=\$("\${WORKDIR}/xray" uuid)
olduuid=\$(cat "\$UUID_FILE")

# 替换 UUID
sed -i "s/\$olduuid/\$newuuid/g" "\$CONFIG"
echo -n "\$newuuid" > "\$UUID_FILE"

# 重启服务
safe_kill() {
    local pf="\$1"
    [ -f "\$pf" ] && { kill \$(cat "\$pf") 2>/dev/null; rm -f "\$pf"; }
}
XRAY_PIDFILE="${PIDFILE_XRAY}"
SNI_PIDFILE="${PIDFILE_SNI}"

safe_kill "\$XRAY_PIDFILE"
[ "\$PROTOCOL" = "reality" ] && safe_kill "\$SNI_PIDFILE"
sleep 1

if [ "\$PROTOCOL" = "reality" ]; then
    setsid "\${WORKDIR}/sni-filter" -L=tcp://${IPADDR}:${PORT} -F=unix://${WORKDIR}/socket/xray.friend -S=${REALITY_DOMAIN} &
    echo \$! > "\$SNI_PIDFILE"
fi
setsid "\${WORKDIR}/xray" -c "\$CONFIG" &
echo \$! > "\$XRAY_PIDFILE"

echo "UUID 已更换: \$newuuid"
[ -n "$realip4" ] && echo "IPv4: vless://\${newuuid}@${realip4}:${PORT}?${sub_params}"
[ -n "$realip6" ] && echo "IPv6: vless://\${newuuid}@[${realip6}]:${PORT}?${sub_params}"
EOFSCRIPT
    chmod 755 "${WORKDIR}/chaguuid"

    # --- delxray ---
    cat > "${WORKDIR}/delxray" << EOFSCRIPT
#!/bin/bash
systemctl stop ${SERVICE_NAME} 2>/dev/null || true
systemctl disable ${SERVICE_NAME} 2>/dev/null || true
safe_kill() { [ -f "\$1" ] && { kill \$(cat "\$1") 2>/dev/null; rm -f "\$1"; }; }
safe_kill "${PIDFILE_XRAY}"
safe_kill "${PIDFILE_SNI}"
pgrep -f "${WORKDIR}/xray" 2>/dev/null | xargs -r kill 2>/dev/null || true
pgrep -f "${WORKDIR}/sni-filter" 2>/dev/null | xargs -r kill 2>/dev/null || true
userdel xrayuser 2>/dev/null || true
rm -f /usr/local/bin/xray.chuuid /usr/local/bin/xray.delxray \\
      /usr/local/bin/xray.stop /usr/local/bin/xray.start \\
      /usr/local/bin/xray.restart /usr/local/bin/xray.help \\
      /usr/local/bin/xray.debug
rm -rf "${WORKDIR}"
echo "卸载完成"
EOFSCRIPT
    chmod 755 "${WORKDIR}/delxray"

    # --- xraystop ---
    cat > "${WORKDIR}/xraystop" << EOFSCRIPT
#!/bin/bash
systemctl stop ${SERVICE_NAME}
EOFSCRIPT
    chmod 755 "${WORKDIR}/xraystop"

    # --- xraystart ---
    cat > "${WORKDIR}/xraystart" << EOFSCRIPT
#!/bin/bash
systemctl start ${SERVICE_NAME}
EOFSCRIPT
    chmod 755 "${WORKDIR}/xraystart"

    # --- xrayrestart ---
    cat > "${WORKDIR}/xrayrestart" << EOFSCRIPT
#!/bin/bash
systemctl restart ${SERVICE_NAME}
EOFSCRIPT
    chmod 755 "${WORKDIR}/xrayrestart"

    # --- xrayhelp ---
    local proto_label
    [ "$PROTOCOL" = "reality" ] && proto_label="REALITY" || proto_label="VLESS Encryption"
    cat > "${WORKDIR}/xrayhelp" << EOFSCRIPT
#!/bin/bash
echo "========================================"
echo "  Xray 管理命令 (${proto_label})"
echo "========================================"
echo "xray.chuuid   更换 UUID"
echo "xray.delxray  卸载"
echo "xray.stop     停止"
echo "xray.start    启动"
echo "xray.restart  重启"
echo "xray.help     帮助"
echo "========================================"
EOFSCRIPT
    chmod 755 "${WORKDIR}/xrayhelp"

    # 创建符号链接
    for cmd in chaguuid delxray xraystop xraystart xrayrestart xrayhelp; do
        ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.${cmd#xray}" 2>/dev/null || true
        # 兼容旧命名
        case "$cmd" in
            chaguuid)   ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.chaguuid" 2>/dev/null || true;;
            delxray)    ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.delxray" 2>/dev/null || true;;
            xraystop)   ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.stop" 2>/dev/null || true;;
            xraystart)  ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.start" 2>/dev/null || true;;
            xrayrestart) ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.restart" 2>/dev/null || true;;
            xrayhelp)   ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.help" 2>/dev/null || true;;
        esac
    done
}

# ============================================================================
# 启动脚本与服务
# ============================================================================
generate_xrayinit() {
    if [ "$PROTOCOL" = "reality" ]; then
        cat > "${WORKDIR}/xrayinit" << EOFSCRIPT
#!/bin/bash
# REALITY 模式: sni-filter 监听公网端口 → unix socket → xray
setsid ${WORKDIR}/sni-filter -L=tcp://${IPADDR}:${PORT} -F=unix://${WORKDIR}/socket/xray.friend -S=${REALITY_DOMAIN} &
echo \$! > ${PIDFILE_SNI}
setsid ${WORKDIR}/xray -c ${CONFIG_FILE} &
echo \$! > ${PIDFILE_XRAY}
echo "on" > ${WORKDIR}/statusfilter
EOFSCRIPT
    else
        cat > "${WORKDIR}/xrayinit" << EOFSCRIPT
#!/bin/bash
# VLESS Encryption 模式: xray 直接监听端口
setsid ${WORKDIR}/xray -c ${CONFIG_FILE} &
echo \$! > ${PIDFILE_XRAY}
echo "on" > ${WORKDIR}/statusfilter
EOFSCRIPT
    fi

    # DDNS 循环
    if [ "$DDNS_ENABLED" = "yes" ]; then
        cat >> "${WORKDIR}/xrayinit" << EOFSCRIPT
while true; do
    sleep 60
    ${WORKDIR}/ddns_check.sh
done
EOFSCRIPT
    else
        echo 'while true; do sleep 3600; done' >> "${WORKDIR}/xrayinit"
    fi
    chmod 755 "${WORKDIR}/xrayinit"
}

generate_ddns_script() {
    [ "$DDNS_ENABLED" != "yes" ] && return

    # DDNS 配置文件
    echo "$DDNS_TYPE $DDNS_TARGET_IP $DDNS_STRATEGY" > "${WORKDIR}/ddns.config"

    cat > "${WORKDIR}/ddns_check.sh" << 'EODDNS'
#!/bin/bash
# DDNS: 检测出口 IP 丢失后自动更换
set -e

WORKDIR="__WORKDIR__"
CONFIG_FILE="__CONFIG_FILE__"
DDNS_CONFIG="${WORKDIR}/ddns.config"
PIDFILE_XRAY="__PIDFILE_XRAY__"
PIDFILE_SNI="__PIDFILE_SNI__"
PROTOCOL="__PROTOCOL__"

[ ! -f "$DDNS_CONFIG" ] && exit 0
read -r ddns_type target_ip strategy < "$DDNS_CONFIG"

# 检查当前 IP 是否仍存在
check_ip() {
    if [ "$ddns_type" = "ipv6" ]; then
        ip -6 addr show 2>/dev/null | grep -qF "$target_ip"
    else
        ip -4 addr show 2>/dev/null | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | grep -qF "$target_ip"
    fi
}
check_ip && exit 0

# 获取可用 IP 列表
get_available() {
    if [ "$ddns_type" = "ipv6" ]; then
        ip -6 addr show 2>/dev/null | grep -oP 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80:' | grep -v '^::1'
    else
        ip -4 addr show 2>/dev/null | grep -oP 'inet \d+\.\d+\.\d+\.\d+'
    fi
}

# 匹配新 IP
new_ip=""
available_ips=$(get_available)
if [ "$strategy" = "any" ]; then
    for ip in $available_ips; do
        [ "$ip" != "$target_ip" ] && { new_ip="$ip"; break; }
    done
else
    case "$strategy" in
        match12) prefix="$(echo "$target_ip" | cut -d: -f1):" ;;
        match28) prefix="$(echo "$target_ip" | cut -d: -f1-2):" ;;
        match48) prefix="$(echo "$target_ip" | cut -d: -f1-3):" ;;
        match8)  prefix="$(echo "$target_ip" | cut -d. -f1)." ;;
        match16) prefix="$(echo "$target_ip" | cut -d. -f1-2)." ;;
        match24) prefix="$(echo "$target_ip" | cut -d. -f1-3)." ;;
    esac
    for ip in $available_ips; do
        case "$ip" in
            "$prefix"*)
                [ "$ip" != "$target_ip" ] && { new_ip="$ip"; break; }
                ;;
        esac
    done
fi

[ -z "$new_ip" ] && exit 0

# 替换配置文件中的 IP（仅替换 sendThrough 和 listen 字段，避免误伤）
sed -i "s/\"sendThrough\":\"$target_ip\"/\"sendThrough\":\"$new_ip\"/g" "$CONFIG_FILE"
sed -i "s/\"listen\":\"$target_ip\"/\"listen\":\"$new_ip\"/g" "$CONFIG_FILE"

# 更新 DDNS 状态
echo "$ddns_type $new_ip $strategy" > "$DDNS_CONFIG"

# 重启服务
safe_kill() { [ -f "$1" ] && { kill $(cat "$1") 2>/dev/null; rm -f "$1"; }; }
safe_kill "$PIDFILE_XRAY"
if [ "$PROTOCOL" = "reality" ]; then
    safe_kill "$PIDFILE_SNI"
    setsid "${WORKDIR}/sni-filter" -L=tcp://__LISTEN_IP__:__PORT__ -F=unix://${WORKDIR}/socket/xray.friend -S=__SNI_DOMAIN__ &
    echo $! > "$PIDFILE_SNI"
fi
setsid "${WORKDIR}/xray" -c "$CONFIG_FILE" &
echo $! > "$PIDFILE_XRAY"
EODDNS

    # 替换占位符
    sed -i \
        -e "s|__WORKDIR__|${WORKDIR}|g" \
        -e "s|__CONFIG_FILE__|${CONFIG_FILE}|g" \
        -e "s|__PIDFILE_XRAY__|${PIDFILE_XRAY}|g" \
        -e "s|__PIDFILE_SNI__|${PIDFILE_SNI}|g" \
        -e "s|__PROTOCOL__|${PROTOCOL}|g" \
        -e "s|__LISTEN_IP__|${IPADDR}|g" \
        -e "s|__PORT__|${PORT}|g" \
        -e "s|__SNI_DOMAIN__|${REALITY_DOMAIN}|g" \
        "${WORKDIR}/ddns_check.sh"
    chmod 755 "${WORKDIR}/ddns_check.sh"
    info "DDNS 检测脚本已生成"
}

install_service() {
    local mtu_line=""
    [ "$MTU_ENABLED" = "yes" ] && mtu_line="ExecStartPre=-/usr/sbin/ip link set dev ${MTU_IF} mtu ${MTU_VAL}"

    local proto_label
    [ "$PROTOCOL" = "reality" ] && proto_label="REALITY" || proto_label="VLESS Encryption"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Xray Service (${proto_label})
After=network.target

[Service]
Type=simple
${mtu_line}
ExecStart=/usr/bin/sh ${WORKDIR}/xrayinit
User=xrayuser

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ============================================================================
# 降权用户
# ============================================================================
setup_user() {
    if [ "$(id -u)" -eq 0 ]; then
        useradd xrayuser -s /sbin/nologin -M 2>/dev/null || true
        chown -R xrayuser:xrayuser "$WORKDIR"
        info "已创建降权用户 xrayuser"
    fi
}

# ============================================================================
# 订阅链接
# ============================================================================
print_subscription() {
    local realip4 realip6
    realip4=$(wget -q4 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2 || echo "")
    realip6=$(wget -q6 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep ip= | cut -d= -f2 || echo "")

    echo ""
    banner_line "========================================"
    banner_line "  安装完成"
    banner_line "========================================"
    info "协议: $([ "$PROTOCOL" = "reality" ] && echo "REALITY" || echo "VLESS Encryption")"

    if [ "$PROTOCOL" = "reality" ]; then
        local params="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=${REALITY_FP}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none&host=${REALITY_DOMAIN}"
        [ -n "$realip4" ] && echo -e "${C_GREEN}IPv4: vless://${UUID}@${realip4}:${PORT}?${params}#xray_REALITY${C_NC}"
        [ -n "$realip6" ] && echo -e "${C_GREEN}IPv6: vless://${UUID}@[${realip6}]:${PORT}?${params}#xray_REALITY${C_NC}"
    else
        local enc_encoded
        enc_encoded=$(urlencode "$ENC_ENCRYPTION_STR")
        [ -n "$realip4" ] && echo -e "${C_GREEN}IPv4: vless://${UUID}@${realip4}:${PORT}?encryption=${enc_encoded}&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption${C_NC}"
        [ -n "$realip6" ] && echo -e "${C_GREEN}IPv6: vless://${UUID}@[${realip6}]:${PORT}?encryption=${enc_encoded}&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption${C_NC}"
    fi

    [ "$MTU_ENABLED" = "yes" ] && info "MTU: ${MTU_IF} mtu ${MTU_VAL}"
    [ "$DDNS_ENABLED" = "yes" ] && info "DDNS: ${DDNS_TYPE} (策略: ${DDNS_STRATEGY})"

    echo ""
    info "管理命令:"
    "${WORKDIR}/xrayhelp" 2>/dev/null || true
}

# ============================================================================
# 清理（失败时回滚）
# ============================================================================
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
        warn "安装过程中出错，正在清理..."
        pgrep -f "${WORKDIR}/xray" 2>/dev/null | xargs -r kill 2>/dev/null || true
        pgrep -f "${WORKDIR}/sni-filter" 2>/dev/null | xargs -r kill 2>/dev/null || true
        rm -rf "$WORKDIR"
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    exit $exit_code
}

# ============================================================================
# 主流程
# ============================================================================
main() {
    trap cleanup EXIT

    # 显示 banner
    echo -e "${C_GREEN}欢迎使用 REALITY / VLESS Encryption 二合一脚本 ${SCRIPT_VER}${C_NC}"
    echo ""
    echo "         _      _   __        _                   _ "
    echo "   ___  | |  __| | / _| _ __ (_)  ___  _ __    __| |"
    echo "  / _ \\ | | / _\` || |_ | '__|| | / _ \\| '_ \\  / _\` |"
    echo " | (_) || || (_| ||  _|| |   | ||  __/| | | || (_| |"
    echo "  \\___/ |_| \\__,_||_|  |_|   |_| \\___||_| |_| \\__,_|"
    echo ""
    sleep 1

    # --- 阶段 0: 环境检查 ---
    check_net
    check_cmd wget openssl unzip
    detect_arch

    # --- 阶段 1: 设置工作目录 ---
    if [ "$(id -u)" -eq 0 ]; then
        WORKDIR="/var/xray"
    else
        WORKDIR="${HOME}/.xray"
    fi
    mkdir -p "${WORKDIR}/socket"
    CONFIG_FILE="${WORKDIR}/config.json"
    PIDFILE_XRAY="${WORKDIR}/xray.pid"
    PIDFILE_SNI="${WORKDIR}/sni-filter.pid"

    # --- 阶段 2: 协议选择 ---
    choose_protocol

    # --- 阶段 3: 网络检测 ---
    detect_ips

    # --- 阶段 4: 网络配置 ---
    configure_network
    configure_ddns
    configure_mtu

    # --- 阶段 5: 协议参数 ---
    configure_protocol_params

    # --- 阶段 6: 落地方式 ---
    choose_landing

    # --- 阶段 7: 安装 ---
    install_xray
    install_sni_filter

    # --- 阶段 8: UUID 与密钥 ---
    UUID=$("${WORKDIR}/xray" uuid)
    generate_keys

    # --- 阶段 9: 生成配置 ---
    build_config_json > "$CONFIG_FILE"
    info "配置文件已生成: $CONFIG_FILE"

    # --- 阶段 10: 降权用户 ---
    setup_user

    # --- 阶段 11: 启动脚本 ---
    generate_xrayinit

    # --- 阶段 12: DDNS ---
    generate_ddns_script

    # --- 阶段 13: 管理脚本 ---
    generate_management_scripts

    # --- 阶段 14: systemd 服务 ---
    install_service

    # --- 阶段 15: 启动 ---
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"
    info "服务已启动"

    # --- 阶段 16: 输出订阅 ---
    print_subscription

    trap - EXIT  # 取消 trap，避免 cleanup 误删
    echo ""
    info "部署成功完成！"
}

# ============================================================================
# 入口
# ============================================================================
main "$@"
