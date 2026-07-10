#!/bin/bash
echo -e "\e[32m欢迎使用REALITY / VLESS Encryption 二合一脚本,v20260710\e[0m"
echo ""
echo "         _      _   __        _                   _ "
echo "   ___  | |  __| | / _| _ __ (_)  ___  _ __    __| |"
echo "  / _ \ | | / _I || |_ | __|| |  / _ \| |_ \  / _| |"
echo " | (_) || || (_| ||  _|| |   | ||  __/| | | || (_| |"
echo "  \___/ |_| \__,_||_|  |_|   |_| \___||_| |_| \__,_|"
echo "                                                    "
sleep 1

# ============================================================
# 阶段 0：协议选择（核心新增）
# ============================================================
echo -e "\e[33m╔══════════════════════════════════════════════════╗\e[0m"
echo -e "\e[33m║          ⚠️  重要提示 ⚠️                        ║\e[0m"
echo -e "\e[33m║                                                ║\e[0m"
echo -e "\e[33m║  REALITY 和 VLESS Encryption 是两种不同的        ║\e[0m"
echo -e "\e[33m║  传输安全方案，不能在同一条 inbound 中共存！      ║\e[0m"
echo -e "\e[33m║                                                ║\e[0m"
echo -e "\e[33m║  • REALITY: 伪装成访问知名网站，抗主动探测最强   ║\e[0m"
echo -e "\e[33m║  • Encryption: 自带加密+抗量子，适合CDN/中转    ║\e[0m"
echo -e "\e[33m╚══════════════════════════════════════════════════╝\e[0m"
echo ""

protocol_choice=$(whiptail --title "协议选择" --menu "请选择传输安全协议（两者不可共存）" 18 60 2 \
    "reality" "REALITY - 伪装网站，抗主动探测" \
    "encryption" "VLESS Encryption - 自带加密，抗量子" 3>&1 1>&2 2>&3)

if [ -z "$protocol_choice" ]; then
    echo -e "\e[31m未选择协议，退出安装\e[0m"
    exit 1
fi

echo -e "\e[32m已选择: $([ "$protocol_choice" == "reality" ] && echo "REALITY 协议" || echo "VLESS Encryption 协议")\e[0m"
echo ""

# ============================================================
# 阶段 1：自动检测系统IP地址（继承脚本3）
# ============================================================
detect_ips() {
    echo -e "\e[32m正在检测系统网络配置...\e[0m"
    
    ipv4_addresses=()
    ipv4_interfaces=()
    interfaces=$(ip -o link show | awk -F': ' '{print $2}')
    
    for iface in $interfaces; do
        [[ "$iface" == "lo" || "$iface" == docker* || "$iface" == br-* || "$iface" == veth* ]] && continue
        ipv4_list=$(ip -4 addr show $iface 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        for ipv4 in $ipv4_list; do
            ipv4_addresses+=("$ipv4")
            ipv4_interfaces+=("$iface: $ipv4")
        done
    done
    
    ipv6_addresses=()
    ipv6_interfaces=()
    for iface in $interfaces; do
        [[ "$iface" == "lo" || "$iface" == docker* || "$iface" == br-* || "$iface" == veth* ]] && continue
        ipv6_list=$(ip -6 addr show $iface 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | grep -v '^::1')
        for ipv6 in $ipv6_list; do
            ipv6_addresses+=("$ipv6")
            ipv6_interfaces+=("$iface: $ipv6")
        done
    done
    
    echo -e "\e[32m检测到的IPv4地址:\e[0m"
    if [ ${#ipv4_interfaces[@]} -eq 0 ]; then
        echo "  未检测到IPv4地址"
    else
        for i in "${!ipv4_interfaces[@]}"; do
            echo "  [$((i+1))] ${ipv4_interfaces[$i]}"
        done
    fi
    
    echo -e "\e[32m检测到的IPv6地址:\e[0m"
    if [ ${#ipv6_interfaces[@]} -eq 0 ]; then
        echo "  未检测到IPv6地址"
    else
        for i in "${!ipv6_interfaces[@]}"; do
            echo "  [$((i+1))] ${ipv6_interfaces[$i]}"
        done
    fi
    echo ""
}

detect_ips

# ============================================================
# 阶段 2：基础变量
# ============================================================
ipaddr=""; portx=""; protocol="$protocol_choice"
fingerprint="chrome"
ipv4_outbound=""; ipv6_outbound=""; use_ipv6_priority="yes"
ddns_enabled="no"; ddns_type=""; ddns_target_ip=""; ddns_strategy=""
mtu_enabled="no"; mtu_interface="eth0"; mtu_value="1390"

# REALITY 特有变量
domain_s="tesla.com"

# VLESS Encryption 特有变量
vless_key_mode="mlkem768"
vless_appearance="random"
vless_rtt="0rtt"
vless_ticket="600s"

echo ""

# ============================================================
# 阶段 3：出口IP配置（继承脚本3）
# ============================================================
echo -e "\e[32m配置出口IP地址\e[0m"
ipv6_priority=$(whiptail --title "IPv6优先" --menu "是否优先使用IPv6出口？" 15 50 4 \
    "yes" "是，IPv6优先" "no" "否，IPv4优先" 3>&1 1>&2 2>&3)
[[ "$ipv6_priority" == "yes" ]] && use_ipv6_priority="yes" || use_ipv6_priority="no"
echo "已选择$([ "$use_ipv6_priority" == "yes" ] && echo "IPv6优先" || echo "IPv4优先")出口"

# IPv4出口
if [ ${#ipv4_addresses[@]} -gt 0 ]; then
    echo -e "\e[32m请选择IPv4出口地址:\e[0m"
    select opt in "使用检测到的地址" "手动输入地址" "不使用IPv4出口"; do
        case $opt in
            "使用检测到的地址")
                if [ ${#ipv4_addresses[@]} -eq 1 ]; then ipv4_outbound="${ipv4_addresses[0]}"
                else select addr in "${ipv4_addresses[@]}"; do ipv4_outbound="$addr"; break; done; fi
                break;;
            "手动输入地址") read -p "地址: " ipv4_outbound; break;;
            "不使用IPv4出口") break;;
        esac
    done
else
    read -p "未检测到IPv4，手动输入（留空取消）: " ipv4_outbound
fi

# IPv6出口
if [ ${#ipv6_addresses[@]} -gt 0 ]; then
    echo -e "\e[32m请选择IPv6出口地址:\e[0m"
    select opt in "使用检测到的地址" "手动输入地址" "不使用IPv6出口"; do
        case $opt in
            "使用检测到的地址")
                if [ ${#ipv6_addresses[@]} -eq 1 ]; then ipv6_outbound="${ipv6_addresses[0]}"
                else select addr in "${ipv6_addresses[@]}"; do ipv6_outbound="$addr"; break; done; fi
                break;;
            "手动输入地址") read -p "地址: " ipv6_outbound; break;;
            "不使用IPv6出口") break;;
        esac
    done
else
    read -p "未检测到IPv6，手动输入（留空取消）: " ipv6_outbound
fi

# ============================================================
# 阶段 4：DDNS 自动更换出口 IP（继承脚本3）
# ============================================================
if whiptail --yesno "是否开启当出口IP丢失后自动更换功能？" 10 50; then
    choice=$(whiptail --menu "选择监控类型" 15 50 2 "ipv6" "IPv6出口" "ipv4" "IPv4出口" 3>&1 1>&2 2>&3)
    case $choice in
        ipv6)
            if [ -z "$ipv6_outbound" ]; then echo "未配置IPv6出口，忽略"
            else
                ddns_type="ipv6"; ddns_target_ip="$ipv6_outbound"
                prefix12="$(echo $ddns_target_ip | cut -d: -f1):"
                prefix28="$(echo $ddns_target_ip | cut -d: -f1-2):"
                prefix48="$(echo $ddns_target_ip | cut -d: -f1-3):"
                strat=$(whiptail --menu "匹配策略" 15 50 4 \
                    "match12" "$prefix12 开头" "match28" "$prefix28 开头" \
                    "match48" "$prefix48 开头" "any" "任意不同IPv6" 3>&1 1>&2 2>&3)
                ddns_strategy="$strat"; ddns_enabled="yes"
            fi ;;
        ipv4)
            if [ -z "$ipv4_outbound" ]; then echo "未配置IPv4出口，忽略"
            else
                ddns_type="ipv4"; ddns_target_ip="$ipv4_outbound"
                IFS='.' read -r a b c d <<< "$ddns_target_ip"
                strat=$(whiptail --menu "匹配策略" 15 50 4 \
                    "match8" "$a. 开头" "match16" "$a.$b. 开头" \
                    "match24" "$a.$b.$c. 开头" "any" "任意不同IPv4" 3>&1 1>&2 2>&3)
                ddns_strategy="$strat"; ddns_enabled="yes"
            fi ;;
    esac
fi

# ============================================================
# 阶段 5：MTU 自动调整（继承脚本3）
# ============================================================
if whiptail --yesno "是否开启 MTU 自动调整？\n（用于修复部分隧道环境下 Reality/Encryption 连接失败，推荐值 1390）" 12 60; then
    mtu_enabled="yes"
    read -p "网络接口名（默认 eth0）: " input_if
    [ -n "$input_if" ] && mtu_interface="$input_if"
    read -p "MTU 值（默认 1390）: " input_mtu
    [ -n "$input_mtu" ] && mtu_value="$input_mtu"
    echo "MTU 将设置为: $mtu_interface mtu $mtu_value"
else
    mtu_enabled="no"
fi

echo ""

# ============================================================
# 阶段 6：协议专属配置
# ============================================================
echo -e "\e[32m配置 $([ "$protocol" == "reality" ] && echo "REALITY" || echo "VLESS Encryption") 参数\e[0m"

read -p "监听IP (默认0.0.0.0): " ipaddr; [ -z "$ipaddr" ] && ipaddr="0.0.0.0"
read -p "监听端口 (默认443): " portx; [ -z "$portx" ] && portx="443"

# --- REALITY 配置 ---
if [ "$protocol" == "reality" ]; then
    read -p "伪装域名 (默认tesla.com): " domain_s; [ -z "$domain_s" ] && domain_s="tesla.com"

    fp_choice=$(whiptail --title "浏览器指纹" --menu "选择指纹" 15 50 5 \
        "chrome" "Chrome" "firefox" "Firefox" "safari" "Safari" "ios" "iOS" "edge" "Edge" 3>&1 1>&2 2>&3)
    [ -n "$fp_choice" ] && fingerprint="$fp_choice"

    echo "配置: $ipaddr:$portx?sni=$domain_s&fp=$fingerprint"

# --- VLESS Encryption 配置 ---
else
    echo ""
    echo -e "\e[33m╔══════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[33m║     VLESS Encryption 配置选项                   ║\e[0m"
    echo -e "\e[33m║                                                ║\e[0m"
    echo -e "\e[33m║  密钥模式：                                     ║\e[0m"
    echo -e "\e[33m║    ① mlkem768 - 抗量子计算（推荐）              ║\e[0m"
    echo -e "\e[33m║    ② x25519   - 传统 Curve25519                ║\e[0m"
    echo -e "\e[33m║                                                ║\e[0m"
    echo -e "\e[33m║  外观模式：                                     ║\e[0m"
    echo -e "\e[33m║    ① native - 原生（性能最佳）                  ║\e[0m"
    echo -e "\e[33m║    ② xorpub - XOR公钥（隐藏特征）              ║\e[0m"
    echo -e "\e[33m║    ③ random - 全随机（最隐蔽）                 ║\e[0m"
    echo -e "\e[33m║                                                ║\e[0m"
    echo -e "\e[33m║  RTT模式：                                      ║\e[0m"
    echo -e "\e[33m║    ① 0rtt   - 零往返（更快）                   ║\e[0m"
    echo -e "\e[33m║    ② 1rtt   - 每次握手（更安全）               ║\e[0m"
    echo -e "\e[33m╚══════════════════════════════════════════════════╝\e[0m"
    echo ""

    # 密钥模式
    echo -e "\e[32m请选择密钥模式:\e[0m"
    select km in "mlkem768（抗量子，推荐）" "x25519（传统）"; do
        case $km in
            "mlkem768（抗量子，推荐）") vless_key_mode="mlkem768"; break;;
            "x25519（传统）") vless_key_mode="x25519"; break;;
        esac
    done

    # 外观模式
    echo -e "\e[32m请选择外观模式:\e[0m"
    select ap in "native（原生，性能最佳）" "xorpub（XOR公钥，隐藏特征）" "random（全随机，最隐蔽）"; do
        case $ap in
            "native（原生，性能最佳）") vless_appearance="native"; break;;
            "xorpub（XOR公钥，隐藏特征）") vless_appearance="xorpub"; break;;
            "random（全随机，最隐蔽）") vless_appearance="random"; break;;
        esac
    done

    # RTT模式
    echo -e "\e[32m请选择RTT模式:\e[0m"
    select rtt in "0rtt（零往返，更快）" "1rtt（每次握手，更安全）"; do
        case $rtt in
            "0rtt（零往返，更快）") vless_rtt="0rtt"; break;;
            "1rtt（每次握手，更安全）") vless_rtt="1rtt"; break;;
        esac
    done

    # Ticket时长（仅0rtt相关）
    read -p "Ticket 时长秒数（默认600，仅0rtt模式生效）: " input_ticket
    [ -n "$input_ticket" ] && vless_ticket="${input_ticket}s" || vless_ticket="600s"

    echo "配置: $ipaddr:$portx | key=$vless_key_mode | appearance=$vless_appearance | rtt=$vless_rtt"
fi

# ============================================================
# 阶段 7：检查和依赖
# ============================================================
ping -c 2 8.8.8.8 &>/dev/null || { echo "无网络连接"; exit 1; }
for cmd in wget openssl unzip; do
    command -v $cmd &>/dev/null || { echo "需要 $cmd，请先安装"; exit 1; }
done

# ============================================================
# 阶段 8：下载和安装 Xray
# ============================================================
[ "$(id -u)" -eq 0 ] && workdir=/var/xray || workdir=${HOME}/.xray
mkdir -p $workdir
cd $workdir
arch=$(uname -m)
case $arch in
    x86_64) url="https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-64.zip";;
    i386|i686) url="https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-32.zip";;
    aarch64) url="https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-arm64-v8a.zip";;
    *) echo "未知架构: $arch"; exit 1;;
esac
wget -q $url -O xray.zip
unzip -o xray.zip && rm xray.zip
chmod 755 xray
id_s=$(./xray uuid)
mkdir -p socket

# ============================================================
# 阶段 9：协议专属密钥生成
# ============================================================
if [ "$protocol" == "reality" ]; then
    # REALITY 密钥
    xray_x25519=$(./xray x25519)
    shortIds=$(openssl rand -hex 6)
    private_old=$(echo "$xray_x25519" | grep "PrivateKey:" | cut -d' ' -f2-)
    public_old=$(echo "$xray_x25519" | grep "Password:" | cut -d' ' -f2-)
    echo "REALITY 密钥已生成"
else
    # VLESS Encryption 密钥
    if [ "$vless_key_mode" == "mlkem768" ]; then
        enc_output=$(./xray mlkem768)
        enc_server_key=$(echo "$enc_output" | grep "Seed:" | head -1 | awk '{print $2}')
        enc_client_key=$(echo "$enc_output" | grep "Client:" | head -1 | awk '{print $2}')
    else
        x25519_output=$(./xray x25519)
        enc_server_key=$(echo "$x25519_output" | grep "PrivateKey:" | cut -d' ' -f2-)
        enc_client_key=$(echo "$x25519_output" | grep "Password:" | cut -d' ' -f2-)
    fi
    # 构建 decryption 和 encryption 字符串
    decryption_str="mlkem768x25519plus.${vless_appearance}.${vless_ticket}.${enc_server_key}"
    encryption_str="mlkem768x25519plus.${vless_appearance}.${vless_rtt}.${enc_client_key}"
    echo "VLESS Encryption 密钥已生成"
fi

# ============================================================
# 阶段 10：出站与路由函数（继承脚本3）
# ============================================================
generate_outbounds() {
    local type="$1" sip="$2" sport="$3" suser="$4" spass="$5"
    local json="["
    if [[ "$type" == "socks" ]]; then
        [[ -n "$ipv6_outbound" ]] && json+='{"tag":"direct-ipv6","protocol":"socks","settings":{"servers":[{"address":"'"$sip"'","port":'"$sport"',"users":[{"user":"'"$suser"'","pass":"'"$spass"'","level":0}]}]},"sendThrough":"'"$ipv6_outbound"'"},'
        [[ -n "$ipv4_outbound" ]] && json+='{"tag":"direct-ipv4","protocol":"socks","settings":{"servers":[{"address":"'"$sip"'","port":'"$sport"',"users":[{"user":"'"$suser"'","pass":"'"$spass"'","level":0}]}]},"sendThrough":"'"$ipv4_outbound"'"},'
    else
        [[ -n "$ipv6_outbound" ]] && json+='{"protocol":"freedom","tag":"direct-ipv6","settings":{"domainStrategy":"UseIPv6"},"sendThrough":"'"$ipv6_outbound"'"},'
        [[ -n "$ipv4_outbound" ]] && json+='{"protocol":"freedom","tag":"direct-ipv4","settings":{"domainStrategy":"UseIPv4"},"sendThrough":"'"$ipv4_outbound"'"},'
    fi
    json="${json%,}"; json+="]"
    echo "$json"
}

generate_routing() {
    local routing=""
    if [[ -n "$ipv6_outbound" && -n "$ipv4_outbound" ]]; then
        if [[ "$use_ipv6_priority" == "yes" ]]; then
            routing='
    "routing": {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]},
            {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]}
        ]
    }'
        else
            routing='
    "routing": {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]},
            {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]}
        ]
    }'
        fi
    elif [[ -n "$ipv6_outbound" ]]; then
        routing='
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [{"type": "field", "outboundTag": "direct-ipv6", "network": "tcp,udp"}]
    }'
    elif [[ -n "$ipv4_outbound" ]]; then
        routing='
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [{"type": "field", "outboundTag": "direct-ipv4", "network": "tcp,udp"}]
    }'
    fi
    echo "$routing"
}

# 落地方式
outlougt=$(whiptail --menu "落地设置" 15 50 4 "direct" "直接落地" "socks" "socks5落地" 3>&1 1>&2 2>&3)
if [[ "$outlougt" == "socks" ]]; then
    read -p "socks5 IP: " sip; read -p "端口: " sport; read -p "用户: " suser; read -p "密码: " spass
    outbounds_config=$(generate_outbounds "socks" "$sip" "$sport" "$suser" "$spass")
else
    outbounds_config=$(generate_outbounds "direct")
fi
routing_config=$(generate_routing)

# ============================================================
# 阶段 11：配置生成（协议分支）
# ============================================================
if [ "$protocol" == "reality" ]; then
    # --- REALITY 配置 ---
    cat > sni_config.json <<EOF
{"log": {"loglevel": "warning"},"inbounds": [{
    "listen": "${workdir}/socket/xray.friend,0600",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s","flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "$domain_s:443",
            "serverNames": ["$domain_s"],
            "privateKey": "$private_old",
            "shortIds": ["$shortIds"]
        }
    }
}],
"outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

    cat > old_config.json <<EOF
{"log": {"loglevel": "warning"},"inbounds": [{
    "port": $portx,
    "listen": "$ipaddr",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s","flow": "xtls-rprx-vision"}],
        "decryption": "none"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
            "dest": "$domain_s:443",
            "serverNames": ["$domain_s"],
            "privateKey": "$private_old",
            "shortIds": ["$shortIds"]
        }
    }
}],
"outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

    # REALITY 订阅链接基础
    sub_base="encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s"

else
    # --- VLESS Encryption 配置 ---
    # 注意：VLESS Encryption 不需要 SNI Filter，直接监听端口
    cat > sni_config.json <<EOF
{"log": {"loglevel": "warning"},"inbounds": [{
    "listen": "${workdir}/socket/xray.friend,0600",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s","flow": "xtls-rprx-vision"}],
        "decryption": "$decryption_str"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "none"
    }
}],
"outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

    cat > old_config.json <<EOF
{"log": {"loglevel": "warning"},"inbounds": [{
    "port": $portx,
    "listen": "$ipaddr",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s","flow": "xtls-rprx-vision"}],
        "decryption": "$decryption_str"
    },
    "streamSettings": {
        "network": "tcp",
        "security": "none"
    }
}],
"outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

    # VLESS Encryption 订阅链接基础
    enc_url_encoded=$(echo -n "$encryption_str" | jq -sRr @uri)
    sub_base="encryption=${enc_url_encoded}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none"
fi

echo "配置已生成"

# ============================================================
# 阶段 12：降权用户（继承脚本3）
# ============================================================
if [ "$(id -u)" -eq 0 ]; then
    useradd xrayuser &>/dev/null || true
    usermod -s /sbin/nologin xrayuser
    chown -R xrayuser:xrayuser $workdir
fi

# ============================================================
# 阶段 13：SNI Filter（仅 REALITY 需要）
# ============================================================
if [ "$protocol" == "reality" ]; then
    wget -q https://github.com/shirasawatop/REALITY-sni-filter/releases/download/v0.2/autobuild.zip -O autobuild.zip
    unzip -o autobuild.zip -d . && rm autobuild.zip
    case $arch in
        x86_64) mv sni-filter-amd64 sni-filter;;
        i386|i686) mv sni-filter-i386 sni-filter;;
        aarch64) mv sni-filter-arm64 sni-filter;;
    esac
    chmod 755 sni-filter
    setcap 'cap_net_bind_service=+ep' sni-filter
    echo "SNI Filter 已安装（仅REALITY模式需要）"
else
    echo "VLESS Encryption 模式，跳过 SNI Filter 安装"
fi

# ============================================================
# 阶段 14：生成 xrayinit（启动脚本）
# ============================================================
if [ "$protocol" == "reality" ]; then
    cat > xrayinit <<EOF
#!/bin/bash
setsid $workdir/sni-filter -L=tcp://${ipaddr}:${portx} -F=unix://${workdir}/socket/xray.friend -S=$domain_s &
setsid $workdir/xray -c $workdir/sni_config.json &
echo "on" > $workdir/statusfilter
EOF
else
    # VLESS Encryption 直接启动 xray（不需要 SNI Filter）
    cat > xrayinit <<EOF
#!/bin/bash
# VLESS Encryption 模式：直接监听端口
setsid $workdir/xray -c $workdir/old_config.json &
echo "on" > $workdir/statusfilter
EOF
fi
chmod 755 xrayinit

# ============================================================
# 阶段 15：DDNS 检测脚本（继承脚本3，适配双协议）
# ============================================================
if [ "$ddns_enabled" == "yes" ]; then
    # 确定需要替换 IP 的配置文件列表
    if [ "$protocol" == "reality" ]; then
        config_files="sni_config.json old_config.json"
    else
        config_files="old_config.json"
    fi

    cat > ddns_check.sh << 'EOSH'
#!/bin/bash
config_file="DDNS_DIR/ddns.config"
[ ! -f "$config_file" ] && exit 0
read ddns_type target_ip strategy < "$config_file"
if [ "$ddns_type" == "ipv6" ]; then
    if ip -6 addr show | grep -q "$target_ip"; then exit 0; fi
    available_ips=$(ip -6 addr show | grep -oP 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80:' | grep -v '^::1')
else
    if ip -4 addr show | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | grep -q "$target_ip"; then exit 0; fi
    available_ips=$(ip -4 addr show | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | awk '{print $2}')
fi
new_ip=""
if [ "$strategy" == "any" ]; then
    for ip in $available_ips; do
        [ "$ip" != "$target_ip" ] && { new_ip="$ip"; break; }
    done
else
    case "$strategy" in
        match12) prefix=$(echo "$target_ip" | cut -d: -f1):;;
        match28) prefix=$(echo "$target_ip" | cut -d: -f1-2):;;
        match48) prefix=$(echo "$target_ip" | cut -d: -f1-3):;;
        match8) prefix="$(echo $target_ip | cut -d. -f1).";;
        match16) prefix="$(echo $target_ip | cut -d. -f1-2).";;
        match24) prefix="$(echo $target_ip | cut -d. -f1-3).";;
    esac
    for ip in $available_ips; do
        if [[ "$ip" == "$prefix"* ]] && [ "$ip" != "$target_ip" ]; then new_ip="$ip"; break; fi
    done
fi
if [ -n "$new_ip" ]; then
    # 替换所有配置文件中的旧IP
    for cfg in CONFIG_FILES; do
        sed -i "s/$target_ip/$new_ip/g" DDNS_DIR/$cfg
    done
    echo "$ddns_type $new_ip $strategy" > "$config_file"
    killall xray &>/dev/null; sleep 1
    if [ -f DDNS_DIR/sni_filter ]; then
        killall sni-filter &>/dev/null
        setsid DDNS_DIR/sni-filter -L=tcp://LISTEN_IP:LISTEN_PORT -F=unix://DDNS_DIR/socket/xray.friend -S=SNI_DOMAIN &
    fi
    setsid DDNS_DIR/xray -c DDNS_DIR/sni_config.json &
fi
EOSH
    # 替换占位符
    if [ "$protocol" == "reality" ]; then
        sed -i "s|CONFIG_FILES|$config_files|g; s|LISTEN_IP|$ipaddr|g; s|LISTEN_PORT|$portx|g; s|SNI_DOMAIN|$domain_s|g" ddns_check.sh
    else
        sed -i "s|CONFIG_FILES|$config_files|g" ddns_check.sh
        # 删除 REALITY 特有的 sni-filter 部分
        sed -i '/sni-filter/d' ddns_check.sh
    fi
    sed -i "s|DDNS_DIR|$workdir|g" ddns_check.sh
    chmod +x ddns_check.sh
    echo "$ddns_type $ddns_target_ip $ddns_strategy" > ddns.config

    # xrayinit 追加 DDNS 循环
    cat >> xrayinit << EOF
while true; do
    sleep 60
    $workdir/ddns_check.sh
done
EOF
else
    cat >> xrayinit << 'EOF'
while true; do sleep 3600; done
EOF
fi

# ============================================================
# 阶段 16：Systemd 服务（含 MTU 设置）
# ============================================================
if [ "$mtu_enabled" == "yes" ]; then
    mtu_line="ExecStartPre=-!/usr/sbin/ip link set dev $mtu_interface mtu $mtu_value"
else
    mtu_line=""
fi

cat > /etc/systemd/system/xray_service.service << EOF
[Unit]
Description=xray Service ($([ "$protocol" == "reality" ] && echo "REALITY" || echo "VLESS Encryption"))
After=network.target

[Service]
Type=simple
${mtu_line}
ExecStart=/usr/bin/sh $workdir/xrayinit
User=xrayuser

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
# 阶段 17：生成管理脚本
# ============================================================
echo -n "$id_s" > oldf_uuid.json
realip4=$(wget -q4 -O- https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2)
realip6=$(wget -q6 -O- https://www.cloudflare.com/cdn-cgi/trace | grep ip= | cut -d= -f2)

# 保存协议类型供管理脚本使用
echo "$protocol" > protocol_type.txt
# 保存 VLESS Encryption 信息供客户端使用
if [ "$protocol" == "encryption" ]; then
    echo "$encryption_str" > encryption_key.txt
fi

# chaguuid - 更换UUID
if [ "$protocol" == "reality" ]; then
    sub_gen="encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s"
else
    enc_for_link=$(cat $workdir/encryption_key.txt 2>/dev/null)
    enc_url_encoded=$(echo -n "$enc_for_link" | jq -sRr @uri 2>/dev/null || echo "$enc_for_link")
    sub_gen="encryption=${enc_url_encoded}&flow=xtls-rprx-vision&security=none&type=tcp&headerType=none"
fi

cat > chaguuid << EOF
#!/bin/bash
newuuid=\$($workdir/xray uuid)
olduuid=\$(cat $workdir/oldf_uuid.json)
sed -i "s/\$olduuid/\$newuuid/g" $workdir/sni_config.json $workdir/old_config.json
killall xray &>/dev/null
[ -f $workdir/sni-filter ] && killall sni-filter &>/dev/null
echo -n \$newuuid > $workdir/oldf_uuid.json
systemctl restart xray_service
[ -n "$realip4" ] && echo "IPv4: vless://\$newuuid@$realip4:$portx?${sub_gen}"
[ -n "$realip6" ] && echo "IPv6: vless://\$newuuid@[$realip6]:$portx?${sub_gen}"
EOF

cat > delxray << EOF
#!/bin/bash
systemctl stop xray_service; systemctl disable xray_service
killall xray &>/dev/null; killall sni-filter &>/dev/null
deluser xrayuser 2>/dev/null
rm -f /usr/bin/xray.*
rm -rf $workdir
echo "卸载完成"
EOF

cat > xraystop << EOF
#!/bin/bash
systemctl stop xray_service
EOF

cat > xraystart << EOF
#!/bin/bash
systemctl start xray_service
EOF

cat > xrayrestart << EOF
#!/bin/bash
systemctl restart xray_service
EOF

cat > xrayhelp << EOF
#!/bin/bash
echo "========================================"
echo "  Xray 管理命令 ($([ "$protocol" == "reality" ] && echo "REALITY" || echo "VLESS Encryption"))"
echo "========================================"
echo "xray.chuuid   更换UUID"
echo "xray.delxray  卸载"
echo "xray.stop     停止"
echo "xray.start    启动"
echo "xray.restart   重启"
echo "xray.debug    修复"
echo "xray.help     帮助"
echo "========================================"
EOF

chmod 755 chaguuid delxray xraystop xraystart xrayrestart xrayhelp 2>/dev/null
ln -sf $workdir/chaguuid /usr/bin/xray.chuuid
ln -sf $workdir/delxray /usr/bin/xray.delxray
ln -sf $workdir/xraystop /usr/bin/xray.stop
ln -sf $workdir/xraystart /usr/bin/xray.start
ln -sf $workdir/xrayrestart /usr/bin/xray.restart
ln -sf $workdir/xrayhelp /usr/bin/xray.help

# 修复脚本（如果存在）
if [ -f $workdir/xraynobug ]; then
    ln -sf $workdir/xraynobug /usr/bin/xray.debug
fi

# ============================================================
# 阶段 18：启动服务
# ============================================================
systemctl enable xray_service
systemctl start xray_service

# ============================================================
# 阶段 19：输出最终信息
# ============================================================
echo ""
echo "========== 安装完成 =========="
echo -e "\e[32m协议: $([ "$protocol" == "reality" ] && echo "REALITY" || echo "VLESS Encryption")\e[0m"

if [ "$protocol" == "reality" ]; then
    [ -n "$realip4" ] && echo -e "\e[32mIPv4: vless://$id_s@$realip4:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s#xray_REALITY\e[0m"
    [ -n "$realip6" ] && echo -e "\e[32mIPv6: vless://$id_s@[$realip6]:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s#xray_REALITY\e[0m"
else
    enc_link=$(cat $workdir/encryption_key.txt 2>/dev/null)
    [ -n "$realip4" ] && echo -e "\e[32mIPv4: vless://$id_s@$realip4:$portx?encryption=$enc_link&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption\e[0m"
    [ -n "$realip6" ] && echo -e "\e[32mIPv6: vless://$id_s@[$realip6]:$portx?encryption=$enc_link&flow=xtls-rprx-vision&security=none&type=tcp#xray_Encryption\e[0m"
fi

if [ "$mtu_enabled" == "yes" ]; then
    echo "MTU 自动调整已启用: $mtu_interface mtu $mtu_value"
fi

if [ "$protocol" == "reality" ]; then
    echo -e "\e[33m提示: 当前使用 REALITY 协议，不支持 VLESS Encryption\e[0m"
else
    echo -e "\e[33m提示: 当前使用 VLESS Encryption 协议，不支持 REALITY\e[0m"
fi
echo ""
echo "管理命令:"
cat $workdir/xrayhelp
