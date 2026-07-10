#!/bin/bash
# ============================================================================
# Xray REALITY / VLESS Encryption 二合一部署脚本 v20260710-r3
# 修复: set -e 下 ((i++)) 触发退出的问题
# ============================================================================
set -eo pipefail

# ============================================================================
# 常量
# ============================================================================
readonly SCRIPT_VER="v20260710-r3"
readonly XRAY_VER="v25.10.15"
readonly XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}"
readonly SNI_FILTER_URL="https://github.com/shirasawatop/REALITY-sni-filter/releases/download/v0.2/autobuild.zip"

readonly DEFAULT_PORT=443
readonly DEFAULT_LISTEN="0.0.0.0"
readonly DEFAULT_DOMAIN="tesla.com"
readonly DEFAULT_FP="chrome"
readonly DEFAULT_MTU=1390
readonly DEFAULT_MTU_IF="eth0"

readonly C_RED='\e[31m'; readonly C_GREEN='\e[32m'
readonly C_YELLOW='\e[33m'; readonly C_CYAN='\e[36m'; readonly C_NC='\e[0m'

# ============================================================================
# 全局变量
# ============================================================================
PROTOCOL=""
WORKDIR=""
ARCH=""
CONFIG_FILE=""
PIDFILE_XRAY=""; PIDFILE_SNI=""
SERVICE_NAME="xray_service"

IPADDR="$DEFAULT_LISTEN"; PORT="$DEFAULT_PORT"
IPV4_OUT=""; IPV6_OUT=""; IPV6_PRIORITY="yes"

REALITY_DOMAIN="$DEFAULT_DOMAIN"; REALITY_FP="$DEFAULT_FP"
REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""

ENC_KEY_MODE="mlkem768"; ENC_APPEARANCE="random"
ENC_RTT="0rtt"; ENC_TICKET="600s"
ENC_SERVER_KEY=""; ENC_CLIENT_KEY=""
ENC_DECRYPTION_STR=""; ENC_ENCRYPTION_STR=""

DDNS_ENABLED="no"; DDNS_TYPE=""; DDNS_TARGET_IP=""; DDNS_STRATEGY=""
MTU_ENABLED="no"; MTU_IF="$DEFAULT_MTU_IF"; MTU_VAL="$DEFAULT_MTU"

LANDING_TYPE="direct"
SOCKS_IP=""; SOCKS_PORT=""; SOCKS_USER=""; SOCKS_PASS=""
UUID=""

declare -A IPV4_MAP=()
declare -A IPV6_MAP=()

# ============================================================================
# 工具函数
# ============================================================================
die()  { echo -e "${C_RED}[错误] $*${C_NC}" >&2; exit 1; }
warn() { echo -e "${C_YELLOW}[警告] $*${C_NC}" >&2; }
info() { echo -e "${C_GREEN}[信息] $*${C_NC}"; }
line() { echo -e "${C_CYAN}$*${C_NC}"; }

check_cmd() { for c in "$@"; do command -v "$c" &>/dev/null || die "缺少命令: $c"; done; }
check_net() { ping -c 2 -W 3 8.8.8.8 &>/dev/null || ping -c 2 -W 3 1.1.1.1 &>/dev/null || die "无网络连接"; }
check_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行此脚本"; }
has_whiptail() { command -v whiptail &>/dev/null; }

urlencode() {
    local s="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "import urllib.parse; print(urllib.parse.quote('$s', safe=''))"
    elif command -v perl &>/dev/null; then
        perl -MURI::Escape -e "print uri_escape('$s');"
    else
        local result="" c i
        for ((i=0; i<${#s}; i++)); do
            c="${s:$i:1}"
            case "$c" in
                [a-zA-Z0-9.~_-]) result+="$c" ;;
                ' ') result+="%20" ;;
                '=') result+="%3D" ;;
                '/') result+="%2F" ;;
                '+') result+="%2B" ;;
                '&') result+="%26" ;;
                *) printf -v hex '%%%02X' "'$c"; result+="$hex" ;;
            esac
        done
        echo "$result"
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
    info "检测网络配置..."
    IPV4_MAP=(); IPV6_MAP=()
    while IFS= read -r iface ip; do
        [[ "$iface" =~ ^(lo|docker|br-|veth) ]] && continue
        IPV4_MAP["$iface"]="$ip"
    done < <(ip -4 addr show 2>/dev/null | awk '/inet /{print $NF, $2}' | sed 's|/.*||')
    while IFS= read -r iface ip; do
        [[ "$iface" =~ ^(lo|docker|br-|veth) ]] && continue
        [[ "$ip" =~ ^fe80: || "$ip" == "::1" ]] && continue
        IPV6_MAP["$iface"]="$ip"
    done < <(ip -6 addr show 2>/dev/null | awk '/inet6 /{print $NF, $2}' | sed 's|/.*||')

    echo ""; line "IPv4:"; local i=0
    for k in "${!IPV4_MAP[@]}"; do
        i=$((i+1)); echo "  [$i] $k: ${IPV4_MAP[$k]}"
    done
    [ $i -eq 0 ] && echo "  (无)"

    echo ""; line "IPv6:"; i=0
    for k in "${!IPV6_MAP[@]}"; do
        i=$((i+1)); echo "  [$i] $k: ${IPV6_MAP[$k]}"
    done
    [ $i -eq 0 ] && echo "  (无)"
    echo ""
}

# ============================================================================
# 交互式选择辅助
# ============================================================================
menu_or_read() {
    local title="$1" prompt="$2" default="$3"; shift 3
    if has_whiptail; then
        whiptail --title "$title" --menu "$prompt" 18 60 8 "$@" 3>&1 1>&2 2>&3 || echo "$default"
    else
        echo "$prompt"
        local keys=() i=1
        while [ $# -gt 0 ]; do
            keys+=("$1"); echo "  $i) $2"; shift 2; i=$((i+1))
        done
        read -rp "选择 (默认 ${default}): " c
        [ -z "$c" ] && { echo "$default"; return; }
        echo "${keys[$((c-1))]:-$default}"
    fi
}

yesno_or_read() {
    local title="$1" prompt="$2" default_yes="$3"
    if has_whiptail; then
        whiptail --title "$title" --yesno "$prompt" 12 50 && return 0 || return 1
    else
        read -rp "$prompt (y/n, 默认 $([ "$default_yes" = "yes" ] && echo "y" || echo "n")): " ans
        [ "$default_yes" = "yes" ] && [[ ! "$ans" =~ ^[Nn] ]] && return 0 || [[ "$ans" =~ ^[Yy] ]] && return 0
        return 1
    fi
}

# ============================================================================
# 配置阶段
# ============================================================================
choose_protocol() {
    echo -e "${C_YELLOW}╔══════════════════════════════════════════════════╗${C_NC}"
    echo -e "${C_YELLOW}║  REALITY 和 VLESS Encryption 不能在同一条 inbound 中共存 ║${C_NC}"
    echo -e "${C_YELLOW}║  • REALITY: 伪装知名网站，抗主动探测最强        ║${C_NC}"
    echo -e "${C_YELLOW}║  • Encryption: 自带加密+抗量子，适合CDN/中转    ║${C_NC}"
    echo -e "${C_YELLOW}╚══════════════════════════════════════════════════╝${C_NC}"
    PROTOCOL=$(menu_or_read "协议选择" "选择传输安全协议:" "reality" \
        "reality"    "REALITY - 伪装网站，抗主动探测" \
        "encryption" "VLESS Encryption - 自带加密，抗量子")
    [ -z "$PROTOCOL" ] && die "未选择协议"
    info "已选择: $([ "$PROTOCOL" = "reality" ] && echo "REALITY" || echo "VLESS Encryption")"
}

configure_network() {
    IPV6_PRIORITY="yes"
    yesno_or_read "IPv6优先" "是否优先使用 IPv6 出口？" "yes" || IPV6_PRIORITY="no"
    info "IPv6 优先: $IPV6_PRIORITY"

    if [ ${#IPV4_MAP[@]} -gt 0 ]; then
        local opts=()
        for k in "${!IPV4_MAP[@]}"; do opts+=("${IPV4_MAP[$k]}" "$k: ${IPV4_MAP[$k]}"); done
        opts+=("none" "不使用 IPv4 出口" "manual" "手动输入")
        IPV4_OUT=$(menu_or_read "IPv4出口" "选择 IPv4 出口:" "none" "${opts[@]}")
        [ "$IPV4_OUT" = "none" ] && IPV4_OUT=""
        [ "$IPV4_OUT" = "manual" ] && { read -rp "输入 IPv4: " IPV4_OUT; }
    else
        read -rp "未检测到 IPv4，手动输入 (留空跳过): " IPV4_OUT
    fi
    [ -n "$IPV4_OUT" ] && info "IPv4 出口: $IPV4_OUT" || info "不使用 IPv4"

    if [ ${#IPV6_MAP[@]} -gt 0 ]; then
        local opts=()
        for k in "${!IPV6_MAP[@]}"; do opts+=("${IPV6_MAP[$k]}" "$k: ${IPV6_MAP[$k]}"); done
        opts+=("none" "不使用 IPv6 出口" "manual" "手动输入")
        IPV6_OUT=$(menu_or_read "IPv6出口" "选择 IPv6 出口:" "none" "${opts[@]}")
        [ "$IPV6_OUT" = "none" ] && IPV6_OUT=""
        [ "$IPV6_OUT" = "manual" ] && { read -rp "输入 IPv6: " IPV6_OUT; }
    else
        read -rp "未检测到 IPv6，手动输入 (留空跳过): " IPV6_OUT
    fi
    [ -n "$IPV6_OUT" ] && info "IPv6 出口: $IPV6_OUT" || info "不使用 IPv6"
}

configure_ddns() {
    DDNS_ENABLED="no"
    yesno_or_read "DDNS" "开启出口 IP 丢失自动更换？" "no" || return

    local choices=()
    [ -n "$IPV6_OUT" ] && choices+=("ipv6" "IPv6 出口")
    [ -n "$IPV4_OUT" ] && choices+=("ipv4" "IPv4 出口")
    [ ${#choices[@]} -eq 0 ] && { warn "无出口 IP，跳过 DDNS"; return; }

    DDNS_TYPE=$(menu_or_read "DDNS类型" "监控类型:" "ipv6" "${choices[@]}")
    case "$DDNS_TYPE" in
        ipv6) DDNS_TARGET_IP="$IPV6_OUT"
              local p12="${IPV6_OUT%%:*}:"
              local p28="${IPV6_OUT%:*:*}:"
              local p48="${IPV6_OUT%:*:*:*}:"
              DDNS_STRATEGY=$(menu_or_read "匹配策略" "匹配策略:" "any" \
                  "match12" "$p12 开头" "match28" "$p28 开头" \
                  "match48" "$p48 开头" "any" "任意不同 IPv6") ;;
        ipv4) DDNS_TARGET_IP="$IPV4_OUT"
              local a8="${IPV4_OUT%%.*}." a16="${IPV4_OUT%.*.*}." a24="${IPV4_OUT%.*}."
              DDNS_STRATEGY=$(menu_or_read "匹配策略" "匹配策略:" "any" \
                  "match8" "$a8 开头" "match16" "$a16 开头" \
                  "match24" "$a24 开头" "any" "任意不同 IPv4") ;;
    esac
    DDNS_ENABLED="yes"
    info "DDNS 已启用: $DDNS_TYPE 策略=$DDNS_STRATEGY"
}

configure_mtu() {
    MTU_ENABLED="no"
    yesno_or_read "MTU" "开启 MTU 自动调整？(推荐 1390)" "no" || return
    MTU_ENABLED="yes"
    read -rp "网络接口 (默认 $DEFAULT_MTU_IF): " i; [ -n "$i" ] && MTU_IF="$i"
    read -rp "MTU 值 (默认 $DEFAULT_MTU): " i; [ -n "$i" ] && MTU_VAL="$i"
    info "MTU: $MTU_IF mtu $MTU_VAL"
}

configure_protocol_params() {
    read -rp "监听 IP (默认 $DEFAULT_LISTEN): " IPADDR; [ -z "$IPADDR" ] && IPADDR="$DEFAULT_LISTEN"
    read -rp "监听端口 (默认 $DEFAULT_PORT): " PORT; [ -z "$PORT" ] && PORT="$DEFAULT_PORT"

    if [ "$PROTOCOL" = "reality" ]; then
        read -rp "伪装域名 (默认 $DEFAULT_DOMAIN): " d; [ -n "$d" ] && REALITY_DOMAIN="$d"
        REALITY_FP=$(menu_or_read "浏览器指纹" "选择指纹:" "chrome" \
            "chrome" "Chrome" "firefox" "Firefox" "safari" "Safari" "ios" "iOS" "edge" "Edge")
        [ -z "$REALITY_FP" ] && REALITY_FP="$DEFAULT_FP"
        info "REALITY: $IPADDR:$PORT sni=$REALITY_DOMAIN fp=$REALITY_FP"
    else
        echo ""; line "VLESS Encryption 配置"
        ENC_KEY_MODE=$(menu_or_read "密钥模式" "选择密钥模式:" "mlkem768" \
            "mlkem768" "抗量子计算（推荐）" "x25519" "传统 Curve25519")
        ENC_APPEARANCE=$(menu_or_read "外观模式" "选择外观模式:" "random" \
            "native" "原生（性能最佳）" "xorpub" "XOR公钥（隐藏特征）" "random" "全随机（最隐蔽）")
        ENC_RTT=$(menu_or_read "RTT模式" "选择 RTT 模式:" "0rtt" \
            "0rtt" "零往返（更快）" "1rtt" "每次握手（更安全）")
        read -rp "Ticket 时长秒数 (默认 600): " t; [ -n "$t" ] && ENC_TICKET="${t}s"
        info "Encryption: $ENC_KEY_MODE / $ENC_APPEARANCE / $ENC_RTT / ticket=$ENC_TICKET"
    fi
}

configure_landing() {
    LANDING_TYPE=$(menu_or_read "落地方式" "选择出站方式:" "direct" \
        "direct" "直接落地 (freedom)" "socks" "SOCKS5 落地")
    if [ "$LANDING_TYPE" = "socks" ]; then
        read -rp "SOCKS5 IP: " SOCKS_IP
        read -rp "SOCKS5 端口: " SOCKS_PORT
        read -rp "SOCKS5 用户名: " SOCKS_USER
        read -rp "SOCKS5 密码: " SOCKS_PASS
    fi
}

# ============================================================================
# JSON 生成（使用 jq 构建）
# ============================================================================
build_config_json() {
    if ! command -v jq &>/dev/null; then
        info "安装 jq..."
        apt-get update -qq && apt-get install -y -qq jq 2>/dev/null || \
        yum install -y -q jq 2>/dev/null || \
        die "无法安装 jq，请手动安装后重试"
    fi

    local outbounds_json="[]"
    if [ -n "$IPV6_OUT" ]; then
        if [ "$LANDING_TYPE" = "socks" ]; then
            outbounds_json=$(echo "$outbounds_json" | jq --arg ip "$SOCKS_IP" --arg port "$SOCKS_PORT" \
                --arg user "$SOCKS_USER" --arg pass "$SOCKS_PASS" --arg through "$IPV6_OUT" \
                '. + [{"tag":"direct-ipv6","protocol":"socks","settings":{"servers":[{"address":$ip,"port":($port|tonumber),"users":[{"user":$user,"pass":$pass,"level":0}]}]},"sendThrough":$through}]')
        else
            outbounds_json=$(echo "$outbounds_json" | jq --arg through "$IPV6_OUT" \
                '. + [{"tag":"direct-ipv6","protocol":"freedom","settings":{"domainStrategy":"UseIPv6"},"sendThrough":$through}]')
        fi
    fi
    if [ -n "$IPV4_OUT" ]; then
        if [ "$LANDING_TYPE" = "socks" ]; then
            outbounds_json=$(echo "$outbounds_json" | jq --arg ip "$SOCKS_IP" --arg port "$SOCKS_PORT" \
                --arg user "$SOCKS_USER" --arg pass "$SOCKS_PASS" --arg through "$IPV4_OUT" \
                '. + [{"tag":"direct-ipv4","protocol":"socks","settings":{"servers":[{"address":$ip,"port":($port|tonumber),"users":[{"user":$user,"pass":$pass,"level":0}]}]},"sendThrough":$through}]')
        else
            outbounds_json=$(echo "$outbounds_json" | jq --arg through "$IPV4_OUT" \
                '. + [{"tag":"direct-ipv4","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"},"sendThrough":$through}]')
        fi
    fi
    if [ "$(echo "$outbounds_json" | jq 'length')" -eq 0 ]; then
        outbounds_json='[{"protocol":"freedom","tag":"direct"}]'
    fi

    local routing_json="null"
    if [ -n "$IPV6_OUT" ] && [ -n "$IPV4_OUT" ]; then
        if [ "$IPV6_PRIORITY" = "yes" ]; then
            routing_json=$(jq -n '{domainStrategy:"IPOnDemand",rules:[
                {type:"field",outboundTag:"direct-ipv6",ip:["2000::/3","::/0"]},
                {type:"field",outboundTag:"direct-ipv4",ip:["0.0.0.0/0"]}
            ]}')
        else
            routing_json=$(jq -n '{domainStrategy:"IPOnDemand",rules:[
                {type:"field",outboundTag:"direct-ipv4",ip:["0.0.0.0/0"]},
                {type:"field",outboundTag:"direct-ipv6",ip:["2000::/3","::/0"]}
            ]}')
        fi
    elif [ -n "$IPV6_OUT" ]; then
        routing_json=$(jq -n '{domainStrategy:"IPIfNonMatch",rules:[{type:"field",outboundTag:"direct-ipv6",network:"tcp,udp"}]}')
    elif [ -n "$IPV4_OUT" ]; then
        routing_json=$(jq -n '{domainStrategy:"IPIfNonMatch",rules:[{type:"field",outboundTag:"direct-ipv4",network:"tcp,udp"}]}')
    fi

    local inbound_json
    if [ "$PROTOCOL" = "reality" ]; then
        inbound_json=$(jq -n --arg listen "${WORKDIR}/socket/xray.friend,0600" \
            --arg id "$UUID" --arg domain "$REALITY_DOMAIN" \
            --arg pk "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" \
            '{
                listen: $listen,
                protocol: "vless",
                settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: "none"},
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {dest: "\($domain):443", serverNames: [$domain], privateKey: $pk, shortIds: [$sid]}
                }
            }')
    else
        inbound_json=$(jq -n --arg listen "$IPADDR" --argjson port "$PORT" \
            --arg id "$UUID" --arg dec "$ENC_DECRYPTION_STR" \
            '{
                port: $port,
                listen: $listen,
                protocol: "vless",
                settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: $dec},
                streamSettings: {network: "tcp", security: "none"}
            }')
    fi

    jq -n --argjson inbound "[$inbound_json]" \
        --argjson outbounds "$outbounds_json" \
        --argjson routing "$routing_json" \
        '{
            log: {loglevel: "warning"},
            inbounds: $inbound,
            outbounds: $outbounds
        }
        | if $routing != null then . + {routing: $routing} else . end'
}

# ============================================================================
# 密钥生成
# ============================================================================
generate_keys() {
    if [ "$PROTOCOL" = "reality" ]; then
        local out; out=$("${WORKDIR}/xray" x25519)
        REALITY_PRIVATE_KEY=$(echo "$out" | awk '/PrivateKey:/{print $2}')
        REALITY_PUBLIC_KEY=$(echo "$out" | awk '/Password:/{print $2}')
        REALITY_SHORT_ID=$(openssl rand -hex 6)
        info "REALITY 密钥已生成"
    else
        if [ "$ENC_KEY_MODE" = "mlkem768" ]; then
            local out; out=$("${WORKDIR}/xray" mlkem768)
            ENC_SERVER_KEY=$(echo "$out" | awk '/Seed:/{print $2}')
            ENC_CLIENT_KEY=$(echo "$out" | awk '/Client:/{print $2}')
        else
            local out; out=$("${WORKDIR}/xray" x25519)
            ENC_SERVER_KEY=$(echo "$out" | awk '/PrivateKey:/{print $2}')
            ENC_CLIENT_KEY=$(echo "$out" | awk '/Password:/{print $2}')
        fi
        ENC_DECRYPTION_STR="mlkem768x25519plus.${ENC_APPEARANCE}.${ENC_TICKET}.${ENC_SERVER_KEY}"
        ENC_ENCRYPTION_STR="mlkem768x25519plus.${ENC_APPEARANCE}.${ENC_RTT}.${ENC_CLIENT_KEY}"
        info "VLESS Encryption 密钥已生成"
    fi
}

# ============================================================================
# 安装
# ============================================================================
install_xray() {
    info "下载 Xray-core ${XRAY_VER}..."
    local zip
    case "$ARCH" in
        amd64)      zip="Xray-linux-64.zip";;
        386)        zip="Xray-linux-32.zip";;
        arm64-v8a)  zip="Xray-linux-arm64-v8a.zip";;
    esac
    wget -q "${XRAY_URL}/${zip}" -O "${WORKDIR}/xray.zip"
    unzip -o "${WORKDIR}/xray.zip" -d "$WORKDIR" >/dev/null
    rm -f "${WORKDIR}/xray.zip"
    chmod 755 "${WORKDIR}/xray"
    info "Xray 安装完成"
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

setup_user() {
    id xrayuser &>/dev/null || useradd xrayuser -s /sbin/nologin -M 2>/dev/null || true
    chown -R xrayuser:xrayuser "$WORKDIR"
    info "降权用户 xrayuser 已就绪"
}

# ============================================================================
# 启动器 & DDNS
# ============================================================================
generate_launcher() {
    if [ "$PROTOCOL" = "reality" ]; then
        cat > "${WORKDIR}/xrayinit" << LAUNCHER
#!/bin/bash
set -e
setsid ${WORKDIR}/sni-filter -L=tcp://${IPADDR}:${PORT} -F=unix://${WORKDIR}/socket/xray.friend -S=${REALITY_DOMAIN} &
echo \$! > ${PIDFILE_SNI}
setsid ${WORKDIR}/xray -c ${CONFIG_FILE} &
echo \$! > ${PIDFILE_XRAY}
echo "on" > ${WORKDIR}/statusfilter
LAUNCHER
    else
        cat > "${WORKDIR}/xrayinit" << LAUNCHER
#!/bin/bash
set -e
setsid ${WORKDIR}/xray -c ${CONFIG_FILE} &
echo \$! > ${PIDFILE_XRAY}
echo "on" > ${WORKDIR}/statusfilter
LAUNCHER
    fi

    if [ "$DDNS_ENABLED" = "yes" ]; then
        echo "while true; do sleep 60; ${WORKDIR}/ddns_check.sh; done" >> "${WORKDIR}/xrayinit"
    else
        echo "while true; do sleep 3600; done" >> "${WORKDIR}/xrayinit"
    fi
    chmod 755 "${WORKDIR}/xrayinit"
}

generate_ddns_script() {
    [ "$DDNS_ENABLED" != "yes" ] && return
    echo "$DDNS_TYPE $DDNS_TARGET_IP $DDNS_STRATEGY" > "${WORKDIR}/ddns.config"

    cat > "${WORKDIR}/ddns_check.sh" << 'EOSCRIPT'
#!/bin/bash
set -e
WORKDIR="__WORKDIR__"
PIDFILE_XRAY="__PIDFILE_XRAY__"; PIDFILE_SNI="__PIDFILE_SNI__"
CONFIG_FILE="__CONFIG_FILE__"; PROTOCOL="__PROTOCOL__"
IPADDR="__IPADDR__"; PORT="__PORT__"; REALITY_DOMAIN="__REALITY_DOMAIN__"

[ -f "${WORKDIR}/ddns.config" ] || exit 0
read -r ddns_type target_ip strategy < "${WORKDIR}/ddns.config"

check_alive() {
    if [ "$ddns_type" = "ipv6" ]; then
        ip -6 addr show 2>/dev/null | grep -qF "$target_ip"
    else
        ip -4 addr show 2>/dev/null | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | grep -qF "$target_ip"
    fi
}
check_alive && exit 0

get_ips() {
    if [ "$ddns_type" = "ipv6" ]; then
        ip -6 addr show 2>/dev/null | grep -oP 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80:' | grep -v '^::1'
    else
        ip -4 addr show 2>/dev/null | grep -oP 'inet \d+\.\d+\.\d+\.\d+'
    fi
}

new_ip=""; available=$(get_ips)
if [ "$strategy" = "any" ]; then
    for ip in $available; do [ "$ip" != "$target_ip" ] && { new_ip="$ip"; break; }; done
else
    case "$strategy" in
        match12) prefix="$(echo "$target_ip" | cut -d: -f1):" ;;
        match28) prefix="$(echo "$target_ip" | cut -d: -f1-2):" ;;
        match48) prefix="$(echo "$target_ip" | cut -d: -f1-3):" ;;
        match8)  prefix="$(echo "$target_ip" | cut -d. -f1)." ;;
        match16) prefix="$(echo "$target_ip" | cut -d. -f1-2)." ;;
        match24) prefix="$(echo "$target_ip" | cut -d. -f1-3)." ;;
    esac
    for ip in $available; do
        case "$ip" in "$prefix"*) [ "$ip" != "$target_ip" ] && { new_ip="$ip"; break; } ;; esac
    done
fi

[ -z "$new_ip" ] && exit 0

sed -i "s/\"sendThrough\":\"$target_ip\"/\"sendThrough\":\"$new_ip\"/g" "$CONFIG_FILE"
sed -i "s/\"listen\":\"$target_ip\"/\"listen\":\"$new_ip\"/g" "$CONFIG_FILE"
echo "$ddns_type $new_ip $strategy" > "${WORKDIR}/ddns.config"

do_kill() { [ -f "$1" ] && kill $(cat "$1") 2>/dev/null || true; rm -f "$1"; }
do_kill "$PIDFILE_XRAY"
if [ "$PROTOCOL" = "reality" ]; then
    do_kill "$PIDFILE_SNI"
    setsid ${WORKDIR}/sni-filter -L=tcp://${IPADDR}:${PORT} -F=unix://${WORKDIR}/socket/xray.friend -S=${REALITY_DOMAIN} &
    echo $! > "$PIDFILE_SNI"
fi
setsid ${WORKDIR}/xray -c "$CONFIG_FILE" &
echo $! > "$PIDFILE_XRAY"
EOSCRIPT

    sed -i \
        -e "s|__WORKDIR__|${WORKDIR}|g" \
        -e "s|__PIDFILE_XRAY__|${PIDFILE_XRAY}|g" \
        -e "s|__PIDFILE_SNI__|${PIDFILE_SNI}|g" \
        -e "s|__CONFIG_FILE__|${CONFIG_FILE}|g" \
        -e "s|__PROTOCOL__|${PROTOCOL}|g" \
        -e "s|__IPADDR__|${IPADDR}|g" \
        -e "s|__PORT__|${PORT}|g" \
        -e "s|__REALITY_DOMAIN__|${REALITY_DOMAIN}|g" \
        "${WORKDIR}/ddns_check.sh"
    chmod 755 "${WORKDIR}/ddns_check.sh"
    info "DDNS 检测脚本已生成"
}

# ============================================================================
# 管理脚本
# ============================================================================
generate_management() {
    echo -n "$UUID" > "${WORKDIR}/uuid.txt"
    echo "$PROTOCOL" > "${WORKDIR}/protocol.txt"
    [ "$PROTOCOL" = "encryption" ] && echo -n "$ENC_ENCRYPTION_STR" > "${WORKDIR}/encryption_key.txt"

    local r4 r6
    r4=$(wget -q4 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || echo "")
    r6=$(wget -q6 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || echo "")

    local sub_params
    if [ "$PROTOCOL" = "reality" ]; then
        sub_params="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=${REALITY_FP}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none&host=${REALITY_DOMAIN}"
    else
        sub_params="encryption=$(urlencode "$ENC_ENCRYPTION_STR")&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none"
    fi

    # chaguuid
    cat > "${WORKDIR}/chaguuid" << MGMT
#!/bin/bash
set -e
WORKDIR="${WORKDIR}"; CONFIG="${CONFIG_FILE}"
PIDFILE_XRAY="${PIDFILE_XRAY}"; PIDFILE_SNI="${PIDFILE_SNI}"
PROTOCOL_FILE="${WORKDIR}/protocol.txt"; UUID_FILE="${WORKDIR}/uuid.txt"

newuuid=\$("${WORKDIR}/xray" uuid)
olduuid=\$(cat "\$UUID_FILE")
proto=\$(cat "\$PROTOCOL_FILE" 2>/dev/null || echo "reality")

sed -i "s/\$olduuid/\$newuuid/g" "\$CONFIG"
echo -n "\$newuuid" > "\$UUID_FILE"

do_kill() { [ -f "\$1" ] && kill \$(cat "\$1") 2>/dev/null; rm -f "\$1"; }
do_kill "\$PIDFILE_XRAY"
if [ "\$proto" = "reality" ]; then
    do_kill "\$PIDFILE_SNI"
    setsid ${WORKDIR}/sni-filter -L=tcp://${IPADDR}:${PORT} -F=unix://${WORKDIR}/socket/xray.friend -S=${REALITY_DOMAIN} &
    echo \$! > "\$PIDFILE_SNI"
fi
setsid ${WORKDIR}/xray -c "\$CONFIG" &
echo \$! > "\$PIDFILE_XRAY"

echo "UUID 已更换: \$newuuid"
[ -n "$r4" ] && echo "IPv4: vless://\${newuuid}@${r4}:${PORT}?${sub_params}"
[ -n "$r6" ] && echo "IPv6: vless://\${newuuid}@[${r6}]:${PORT}?${sub_params}"
MGMT
    chmod 755 "${WORKDIR}/chaguuid"

    # delxray
    cat > "${WORKDIR}/delxray" << MGMT
#!/bin/bash
systemctl stop ${SERVICE_NAME} 2>/dev/null || true
systemctl disable ${SERVICE_NAME} 2>/dev/null || true
do_kill() { [ -f "\$1" ] && kill \$(cat "\$1") 2>/dev/null; rm -f "\$1"; }
do_kill "${PIDFILE_XRAY}"; do_kill "${PIDFILE_SNI}"
userdel xrayuser 2>/dev/null || true
rm -f /usr/local/bin/xray.* /usr/bin/xray.*
rm -rf "${WORKDIR}"
echo "卸载完成"
MGMT
    chmod 755 "${WORKDIR}/delxray"

    for action in stop start restart; do
        cat > "${WORKDIR}/xray${action}" << MGMT
#!/bin/bash
systemctl ${action} ${SERVICE_NAME}
MGMT
        chmod 755 "${WORKDIR}/xray${action}"
    done

    local label; [ "$PROTOCOL" = "reality" ] && label="REALITY" || label="VLESS Encryption"
    cat > "${WORKDIR}/xrayhelp" << MGMT
#!/bin/bash
echo "========================================"
echo "  Xray 管理命令 (${label})"
echo "========================================"
echo "xray.chuuid   更换 UUID"
echo "xray.delxray  卸载"
echo "xray.stop     停止"
echo "xray.start    启动"
echo "xray.restart  重启"
echo "xray.help     帮助"
echo "========================================"
MGMT
    chmod 755 "${WORKDIR}/xrayhelp"

    for cmd in chaguuid delxray xraystop xraystart xrayrestart xrayhelp; do
        local linkname="${cmd#xray}"
        [ "$linkname" = "$cmd" ] && linkname="$cmd"
        ln -sf "${WORKDIR}/${cmd}" "/usr/local/bin/xray.${linkname}" 2>/dev/null || true
    done
    info "管理命令已安装到 /usr/local/bin/"
}

# ============================================================================
# systemd
# ============================================================================
install_service() {
    local mtu_line=""
    [ "$MTU_ENABLED" = "yes" ] && mtu_line="ExecStartPre=-/usr/sbin/ip link set dev ${MTU_IF} mtu ${MTU_VAL}"
    local label; [ "$PROTOCOL" = "reality" ] && label="REALITY" || label="VLESS Encryption"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Xray Service (${label})
After=network.target

[Service]
Type=simple
${mtu_line}
ExecStart=/usr/bin/sh ${WORKDIR}/xrayinit
User=xrayuser
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ============================================================================
# 最终输出
# ============================================================================
print_info() {
    local r4 r6
    r4=$(wget -q4 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || echo "")
    r6=$(wget -q6 -O- https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}' || echo "")

    echo ""; line "========================================"
    line "  安装完成！"; line "========================================"
    info "协议: $([ "$PROTOCOL" = "reality" ] && echo "REALITY" || echo "VLESS Encryption")"
    info "端口: $PORT"

    if [ "$PROTOCOL" = "reality" ]; then
        local p="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=${REALITY_FP}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none&host=${REALITY_DOMAIN}"
        [ -n "$r4" ] && echo -e "${C_GREEN}IPv4: vless://${UUID}@${r4}:${PORT}?${p}#xray_REALITY${C_NC}"
        [ -n "$r6" ] && echo -e "${C_GREEN}IPv6: vless://${UUID}@[${r6}]:${PORT}?${p}#xray_REALITY${C_NC}"
    else
        local e; e=$(urlencode "$ENC_ENCRYPTION_STR")
        [ -n "$r4" ] && echo -e "${C_GREEN}IPv4: vless://${UUID}@${r4}:${PORT}?encryption=${e}&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption${C_NC}"
        [ -n "$r6" ] && echo -e "${C_GREEN}IPv6: vless://${UUID}@[${r6}]:${PORT}?encryption=${e}&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption${C_NC}"
    fi

    [ "$MTU_ENABLED" = "yes" ] && info "MTU: ${MTU_IF} mtu ${MTU_VAL}"
    [ "$DDNS_ENABLED" = "yes" ] && info "DDNS: ${DDNS_TYPE} (${DDNS_STRATEGY})"
    echo ""
    info "管理命令: xray.start | xray.stop | xray.restart | xray.chuuid | xray.delxray | xray.help"
}

# ============================================================================
# 清理
# ============================================================================
cleanup() {
    local ec=$?
    if [ $ec -ne 0 ] && [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
        warn "安装失败 (退出码: $ec)，正在清理..."
        pgrep -f "${WORKDIR}/xray" 2>/dev/null | xargs -r kill 2>/dev/null || true
        pgrep -f "${WORKDIR}/sni-filter" 2>/dev/null | xargs -r kill 2>/dev/null || true
        rm -rf "$WORKDIR"
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    exit $ec
}

# ============================================================================
# 主入口
# ============================================================================
main() {
    trap cleanup EXIT

    echo -e "${C_GREEN}欢迎使用 REALITY / VLESS Encryption 二合一脚本 ${SCRIPT_VER}${C_NC}"
    echo ""
    echo "         _      _   __        _                   _ "
    echo "   ___  | |  __| | / _| _ __ (_)  ___  _ __    __| |"
    echo "  / _ \\ | | / _\` || |_ | '__|| | / _ \\| '_ \\  / _\` |"
    echo " | (_) || || (_| ||  _|| |   | ||  __/| | | || (_| |"
    echo "  \\___/ |_| \\__,_||_|  |_|   |_| \\___||_| |_| \\__,_|"
    echo ""
    sleep 1

    check_root
    check_net
    check_cmd wget openssl unzip
    detect_arch

    WORKDIR="/var/xray"
    mkdir -p "${WORKDIR}/socket"
    CONFIG_FILE="${WORKDIR}/config.json"
    PIDFILE_XRAY="${WORKDIR}/xray.pid"
    PIDFILE_SNI="${WORKDIR}/sni-filter.pid"

    choose_protocol
    detect_ips
    configure_network
    configure_ddns
    configure_mtu
    configure_protocol_params
    configure_landing

    install_xray
    install_sni_filter

    UUID=$("${WORKDIR}/xray" uuid)
    generate_keys

    build_config_json > "$CONFIG_FILE"
    info "配置文件: $CONFIG_FILE"

    setup_user
    generate_launcher
    generate_ddns_script
    generate_management

    install_service
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "服务运行中 ✓"
    else
        warn "服务可能未正常启动，请检查: systemctl status ${SERVICE_NAME}"
        warn "或查看日志: journalctl -u ${SERVICE_NAME} -n 30"
    fi

    print_info
    trap - EXIT
}

main "$@"
