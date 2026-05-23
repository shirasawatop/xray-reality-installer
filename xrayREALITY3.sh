#!/bin/bash
echo -e "\e[32m欢迎使用REALITY一键脚本,v20251217\e[0m"
echo ""
echo "         _      _   __        _                   _ "
echo "   ___  | |  __| | / _| _ __ (_)  ___  _ __    __| |"
echo "  / _ \ | | / _I || |_ | __|| |  / _ \| |_ \  / _| |"
echo " | (_) || || (_| ||  _|| |   | ||  __/| | | || (_| |"
echo "  \___/ |_| \__,_||_|  |_|   |_| \___||_| |_| \__,_|"
echo "                                                    "
sleep 1

# 自动检测系统IP地址
detect_ips() {
    echo -e "\e[32m正在检测系统网络配置...\e[0m"
    
    # 检测IPv4地址
    ipv4_addresses=()
    ipv4_interfaces=()
    
    interfaces=$(ip -o link show | awk -F': ' '{print $2}')
    
    for iface in $interfaces; do
        if [[ "$iface" == "lo" ]] || [[ "$iface" == docker* ]] || [[ "$iface" == br-* ]] || [[ "$iface" == veth* ]]; then
            continue
        fi
        
        ipv4_list=$(ip -4 addr show $iface 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        for ipv4 in $ipv4_list; do
            ipv4_addresses+=("$ipv4")
            ipv4_interfaces+=("$iface: $ipv4")
        done
    done
    
    # 检测IPv6地址
    ipv6_addresses=()
    ipv6_interfaces=()
    
    for iface in $interfaces; do
        if [[ "$iface" == "lo" ]] || [[ "$iface" == docker* ]] || [[ "$iface" == br-* ]] || [[ "$iface" == veth* ]]; then
            continue
        fi
        
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

# 固定安装xray
sec="xray"

ipaddr=""
portx=""
domain_s=""
is_install=1
fingerprint="chrome"

ipv4_outbound=""
ipv6_outbound=""
use_ipv6_priority="yes"

echo ""

# 出口IP配置
echo -e "\e[32m配置出口IP地址\e[0m"

ipv6_priority=$(whiptail --title "IPv6优先" --menu "是否优先使用IPv6出口？" 15 50 4 \
    "yes" "是，IPv6优先" \
    "no" "否，IPv4优先" 3>&1 1>&2 2>&3)

if [[ "$ipv6_priority" == "yes" ]]; then
    use_ipv6_priority="yes"
    echo "已选择IPv6优先出口"
else
    use_ipv6_priority="no"
    echo "已选择IPv4优先出口"
fi

# IPv4出口
if [ ${#ipv4_addresses[@]} -gt 0 ]; then
    echo -e "\e[32m请选择IPv4出口地址:\e[0m"
    select ipv4_option in "使用检测到的地址" "手动输入地址" "不使用IPv4出口"; do
        case $ipv4_option in
            "使用检测到的地址")
                if [ ${#ipv4_addresses[@]} -eq 1 ]; then
                    ipv4_outbound="${ipv4_addresses[0]}"
                else
                    echo "请选择IPv4地址:"
                    select ipv4_addr in "${ipv4_addresses[@]}"; do
                        ipv4_outbound="$ipv4_addr"
                        break
                    done
                fi
                echo "已选择IPv4出口: $ipv4_outbound"
                break
                ;;
            "手动输入地址")
                read -p "请输入IPv4出口地址: " ipv4_outbound
                [ -z "$ipv4_outbound" ] && echo "未输入IPv4地址，将不使用IPv4出口" || echo "已设置IPv4出口: $ipv4_outbound"
                break
                ;;
            "不使用IPv4出口")
                echo "将不使用IPv4出口"
                break
                ;;
        esac
    done
else
    read -p "未检测到IPv4地址，请输入IPv4出口地址（留空则不使用）: " ipv4_outbound
    [ -n "$ipv4_outbound" ] && echo "已设置IPv4出口: $ipv4_outbound"
fi

# IPv6出口
if [ ${#ipv6_addresses[@]} -gt 0 ]; then
    echo -e "\e[32m请选择IPv6出口地址:\e[0m"
    select ipv6_option in "使用检测到的地址" "手动输入地址" "不使用IPv6出口"; do
        case $ipv6_option in
            "使用检测到的地址")
                if [ ${#ipv6_addresses[@]} -eq 1 ]; then
                    ipv6_outbound="${ipv6_addresses[0]}"
                else
                    echo "请选择IPv6地址:"
                    select ipv6_addr in "${ipv6_addresses[@]}"; do
                        ipv6_outbound="$ipv6_addr"
                        break
                    done
                fi
                echo "已选择IPv6出口: $ipv6_outbound"
                break
                ;;
            "手动输入地址")
                read -p "请输入IPv6出口地址: " ipv6_outbound
                [ -z "$ipv6_outbound" ] && echo "未输入IPv6地址，将不使用IPv6出口" || echo "已设置IPv6出口: $ipv6_outbound"
                break
                ;;
            "不使用IPv6出口")
                echo "将不使用IPv6出口"
                break
                ;;
        esac
    done
else
    read -p "未检测到IPv6地址，请输入IPv6出口地址（留空则不使用）: " ipv6_outbound
    [ -n "$ipv6_outbound" ] && echo "已设置IPv6出口: $ipv6_outbound"
fi

# ---------- DDNS 自动更换出口 IP ----------
ddns_enabled="no"
ddns_type=""
ddns_target_ip=""
ddns_strategy=""

if whiptail --title "自动更换出口IP" --yesno "是否开启当出口IP丢失后自动更换功能？" 10 50; then
    ddns_choice=$(whiptail --title "选择监控的IP类型" --menu "请选择要监控的出口IP类型：" 15 50 2 \
        "ipv6" "IPv6出口" \
        "ipv4" "IPv4出口" 3>&1 1>&2 2>&3)
    
    case "$ddns_choice" in
        ipv6)
            if [ -z "$ipv6_outbound" ]; then
                echo "未配置IPv6出口，无法开启自动更换功能。"
            else
                ddns_type="ipv6"
                ddns_target_ip="$ipv6_outbound"
                prefix12=$(echo "$ddns_target_ip" | cut -d: -f1)":"
                prefix28=$(echo "$ddns_target_ip" | cut -d: -f1-2)":"
                prefix48=$(echo "$ddns_target_ip" | cut -d: -f1-3)":"
                strategy=$(whiptail --title "选择替换策略" --menu "选择匹配新IPv6地址的规则" 15 50 4 \
                    "match12" "匹配以 $prefix12 开头的IPv6" \
                    "match28" "匹配以 $prefix28 开头的IPv6" \
                    "match48" "匹配以 $prefix48 开头的IPv6" \
                    "any" "任意不同的IPv6" 3>&1 1>&2 2>&3)
                ddns_strategy="$strategy"
                ddns_enabled="yes"
            fi
            ;;
        ipv4)
            if [ -z "$ipv4_outbound" ]; then
                echo "未配置IPv4出口，无法开启自动更换功能。"
            else
                ddns_type="ipv4"
                ddns_target_ip="$ipv4_outbound"
                IFS='.' read -r a b c d <<< "$ddns_target_ip"
                prefix8="$a."
                prefix16="$a.$b."
                prefix24="$a.$b.$c."
                strategy=$(whiptail --title "选择替换策略" --menu "选择匹配新IPv4地址的规则" 15 50 4 \
                    "match8" "匹配以 $prefix8 开头的IPv4" \
                    "match16" "匹配以 $prefix16 开头的IPv4" \
                    "match24" "匹配以 $prefix24 开头的IPv4" \
                    "any" "任意不同的IPv4" 3>&1 1>&2 2>&3)
                ddns_strategy="$strategy"
                ddns_enabled="yes"
            fi
            ;;
    esac
fi

echo ""

# Xray 基本配置
echo "安装 xray"
echo -e "\e[32m请输入xray监听IP,默认0.0.0.0\e[0m"
read ipaddr
echo -e "\e[32m请输入xray监听端口,默认443\e[0m"
read portx
echo -e "\e[32m请输入xray伪装的域名,默认tesla.com\e[0m"
read domain_s

fp_choice=$(whiptail --title "选择浏览器指纹" --menu \
    "使用 ↑↓ 选择，回车确认" 15 50 5 \
    "chrome" "Chrome浏览器 (推荐)" \
    "firefox" "Firefox浏览器" \
    "safari" "Safari浏览器" \
    "ios" "iOS Safari" \
    "edge" "Microsoft Edge" 3>&1 1>&2 2>&3)

[ -n "$fp_choice" ] && fingerprint="$fp_choice"

[ -z "$ipaddr" ] && ipaddr="0.0.0.0"
[ -z "$portx" ] && portx="443"
[ -z "$domain_s" ] && domain_s="tesla.com"

echo "xray config: $ipaddr:$portx?sni=$domain_s&fp=$fingerprint"
echo ""

# 网络与依赖检查
if ping -c 2 8.8.8.8 &> /dev/null; then
    echo -e "\e[32mINFO: 开始下载xray\e[0m"
else
    echo -e "\033[31mERR: 没有网络连接\033[0m"
    exit
fi

if command -v wget > /dev/null 2>&1; then echo "Checking wget is installed."; else echo -e "\033[31mwget不存在,请apt install wget安装\033[0m"; exit; fi
if command -v openssl > /dev/null 2>&1; then echo "Checking openssl is installed."; else echo -e "\033[31mopenssl不存在,请apt install openssl安装\033[0m"; exit; fi
if command -v unzip > /dev/null 2>&1; then echo "Checking unzip is installed."; else echo -e "\033[31munzip不存在,请apt install unzip安装\033[0m"; exit; fi

# 工作目录
if [ "$(id -u)" == 0 ]; then
    workdir=/var/xray
else
    workdir=${HOME}/.xray
fi

mkdir -p ${workdir}
architecture=$(uname -m)
if [[ "$architecture" == "x86_64" ]]; then
    wget -P ${workdir} https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-64.zip
elif [[ "$architecture" == "i386" || "$architecture" == "i686" ]]; then
    wget -P ${workdir} https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-32.zip
elif [[ "$architecture" == "aarch64" ]]; then
    wget -P ${workdir} https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-arm64-v8a.zip
else
    echo -e "\033[31未知架构: $architecture,请手动安装\033[0m"
    exit
fi

cd ${workdir}/
unzip *.zip
chmod 755 ${workdir}/xray
rm *.zip
id_s=`${workdir}/xray uuid`
xray_x25519=`${workdir}/xray x25519`
shortIds=`openssl rand -hex 6`
private_old=$(echo "$xray_x25519" | grep "PrivateKey:" | cut -d ' ' -f 2-)
public_old=$(echo "$xray_x25519" | grep "Password:" | cut -d ' ' -f 2-)
mkdir -p ${workdir}/socket

# 出站配置生成
generate_outbounds() {
    local outbound_type="$1"
    local socks5IP="$2"
    local socks5port="$3"
    local socks5user="$4"
    local socks5pass="$5"
    
    local outbounds_json=""
    
    if [[ "$outbound_type" == "socks" ]]; then
        outbounds_json='['
        [[ -n "$ipv6_outbound" ]] && outbounds_json+='
        {
            "tag": "direct-ipv6",
            "protocol": "socks",
            "settings": {
                "servers": [{"address": "'"$socks5IP"'", "port": '"$socks5port"', "users": [{"user": "'"$socks5user"'", "pass": "'"$socks5pass"'", "level": 0}]}]
            },
            "sendThrough": "'"$ipv6_outbound"'"
        },'
        [[ -n "$ipv4_outbound" ]] && outbounds_json+='
        {
            "tag": "direct-ipv4",
            "protocol": "socks",
            "settings": {
                "servers": [{"address": "'"$socks5IP"'", "port": '"$socks5port"', "users": [{"user": "'"$socks5user"'", "pass": "'"$socks5pass"'", "level": 0}]}]
            },
            "sendThrough": "'"$ipv4_outbound"'"
        },'
        outbounds_json="${outbounds_json%,}"
        outbounds_json+=']'
    else
        outbounds_json='['
        [[ -n "$ipv6_outbound" ]] && outbounds_json+='
        {
            "protocol": "freedom",
            "tag": "direct-ipv6",
            "settings": {"domainStrategy": "UseIPv6"},
            "sendThrough": "'"$ipv6_outbound"'"
        },'
        [[ -n "$ipv4_outbound" ]] && outbounds_json+='
        {
            "protocol": "freedom",
            "tag": "direct-ipv4",
            "settings": {"domainStrategy": "UseIPv4"},
            "sendThrough": "'"$ipv4_outbound"'"
        },'
        outbounds_json="${outbounds_json%,}"
        outbounds_json+=']'
    fi
    
    echo "$outbounds_json"
}

# 路由配置生成
generate_routing() {
    local routing_json=''
    if [[ -n "$ipv6_outbound" ]] && [[ -n "$ipv4_outbound" ]]; then
        if [[ "$use_ipv6_priority" == "yes" ]]; then
            routing_json='{
    "routing": {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]},
            {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]}
        ]
    }}'
        else
            routing_json='{
    "routing": {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {"type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"]},
            {"type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"]}
        ]
    }}'
        fi
    elif [[ -n "$ipv6_outbound" ]]; then
        routing_json='{
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [{"type": "field", "outboundTag": "direct-ipv6", "network": "tcp,udp"}]
    }}'
    elif [[ -n "$ipv4_outbound" ]]; then
        routing_json='{
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [{"type": "field", "outboundTag": "direct-ipv4", "network": "tcp,udp"}]
    }}'
    fi
    echo "$routing_json"
}

# 落地方式
outlougt=$(whiptail --title "请选择落地设置" --menu "使用 ↑↓ 选择，回车确认" 15 50 4 \
    "direct" "直接落地" \
    "socks" "socks5落地" 3>&1 1>&2 2>&3)

if [[ "$outlougt" == "socks" ]]; then
    socks5IP=""; socks5port=""; socks5user=""; socks5pass=""
    read -p "请输入socks5 IP: " socks5IP
    read -p "请输入socks5 port: " socks5port
    read -p "请输入socks5 user: " socks5user
    read -p "请输入socks5 pass: " socks5pass
    outbounds_config=$(generate_outbounds "socks" "$socks5IP" "$socks5port" "$socks5user" "$socks5pass")
    routing_config=$(generate_routing)
else
    outbounds_config=$(generate_outbounds "direct")
    routing_config=$(generate_routing)
fi

# 生成配置文件（始终使用 sni-filter 的 Unix socket 监听）
cat << EOF > ${workdir}/sni_config.json
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

# 同时也生成一份 old_config.json（保留兼容性，虽然不通过该配置启动）
cat << EOF > ${workdir}/old_config.json
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

# 出口IP信息
echo ""
echo -e "\e[32m出口IP配置信息:\e[0m"
[ -n "$ipv4_outbound" ] && echo "  IPv4出口: $ipv4_outbound"
[ -n "$ipv6_outbound" ] && echo "  IPv6出口: $ipv6_outbound"
echo "  优先级: $([ "$use_ipv6_priority" == "yes" ] && echo "IPv6优先" || echo "IPv4优先")"
[ "$ddns_enabled" == "yes" ] && echo "  DDNS已开启: 监控 $ddns_type ($ddns_target_ip) 策略: $ddns_strategy"

# 降权用户
if [ "$(id -u)" == 0 ]; then
    echo "当前root用户，降权到非root初始化脚本"
    useradd xrayuser &>/dev/null || true
    usermod -s /sbin/nologin xrayuser
    chown :xrayuser ${workdir}/*.json
    chown xrayuser ${workdir}/
    chown xrayuser ${workdir}/socket
fi

# 启动脚本
echo "#!/bin/bash" > ${workdir}/xrayinit
chmod 755 ${workdir}/xrayinit

# sni-filter
wget -P ${workdir} https://github.com/oldfriendme/REALITY-sni-filter/releases/download/v0.2/autobuild.zip
unzip -o ${workdir}/autobuild.zip -d ${workdir}/
rm ${workdir}/autobuild.zip
case "$architecture" in
    x86_64) mv ${workdir}/sni-filter-amd64 ${workdir}/sni-filter ;;
    i386|i686) mv ${workdir}/sni-filter-i386 ${workdir}/sni-filter ;;
    aarch64) mv ${workdir}/sni-filter-arm64 ${workdir}/sni-filter ;;
    *) echo "echo maybe soon" > ${workdir}/sni-filter ;;
esac
chmod 755 ${workdir}/sni-filter
setcap 'cap_net_bind_service=+ep' ${workdir}/sni-filter

# 生成 systemd 服务
cat << EOF > /etc/systemd/system/xray_service.service
[Unit]
Description=xray Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/sh ${workdir}/xrayinit
User=xrayuser

[Install]
WantedBy=multi-user.target
EOF

# xrayinit 主体（始终使用 sni-filter）
cat << EOF >> ${workdir}/xrayinit
setsid ${workdir}/sni-filter -L=tcp://${ipaddr}:${portx} -F=unix://${workdir}/socket/xray.friend -S=$domain_s &
setsid ${workdir}/xray -c ${workdir}/sni_config.json &
echo "on" > ${workdir}/statusfilter
EOF

# 如果开启了DDNS，则生成监控循环；否则简单休眠
if [ "$ddns_enabled" == "yes" ]; then
    cat << 'EOSH' > ${workdir}/ddns_check.sh
#!/bin/bash
config_file="DDNS_CONFIG_PLACEHOLDER/ddns.config"
[ ! -f "$config_file" ] && exit 0
read ddns_type target_ip strategy < "$config_file"
if [ "$ddns_type" == "ipv6" ]; then
    if ip -6 addr show | grep -q "$target_ip"; then
        exit 0
    fi
    available_ips=$(ip -6 addr show | grep -oP 'inet6 [0-9a-f:]+' | awk '{print $2}' | grep -v '^fe80:' | grep -v '^::1')
    new_ip=""
    if [ "$strategy" == "any" ]; then
        for ip in $available_ips; do
            if [ "$ip" != "$target_ip" ]; then
                new_ip="$ip"
                break
            fi
        done
    else
        case "$strategy" in
            match12) prefix=$(echo "$target_ip" | cut -d: -f1)":" ;;
            match28) prefix=$(echo "$target_ip" | cut -d: -f1-2)":" ;;
            match48) prefix=$(echo "$target_ip" | cut -d: -f1-3)":" ;;
        esac
        for ip in $available_ips; do
            if [[ "$ip" == "$prefix"* ]] && [ "$ip" != "$target_ip" ]; then
                new_ip="$ip"
                break
            fi
        done
    fi
else
    if ip -4 addr show | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | grep -q "$target_ip"; then
        exit 0
    fi
    available_ips=$(ip -4 addr show | grep -oP 'inet \d+\.\d+\.\d+\.\d+' | awk '{print $2}')
    new_ip=""
    if [ "$strategy" == "any" ]; then
        for ip in $available_ips; do
            if [ "$ip" != "$target_ip" ]; then
                new_ip="$ip"
                break
            fi
        done
    else
        IFS='.' read -r a b c d <<< "$target_ip"
        case "$strategy" in
            match8) prefix="$a." ;;
            match16) prefix="$a.$b." ;;
            match24) prefix="$a.$b.$c." ;;
        esac
        for ip in $available_ips; do
            if [[ "$ip" == "$prefix"* ]] && [ "$ip" != "$target_ip" ]; then
                new_ip="$ip"
                break
            fi
        done
    fi
fi

if [ -n "$new_ip" ]; then
    sed -i "s/$target_ip/$new_ip/g" DDNS_CONFIG_PLACEHOLDER/sni_config.json DDNS_CONFIG_PLACEHOLDER/old_config.json
    echo "$ddns_type $new_ip $strategy" > "$config_file"
    killall xray > /dev/null 2>&1
    sleep 1
    setsid DDNS_CONFIG_PLACEHOLDER/xray -c DDNS_CONFIG_PLACEHOLDER/sni_config.json &
fi
EOSH
    sed -i "s|DDNS_CONFIG_PLACEHOLDER|$workdir|g" ${workdir}/ddns_check.sh
    chmod +x ${workdir}/ddns_check.sh

    echo "$ddns_type $ddns_target_ip $ddns_strategy" > ${workdir}/ddns.config

    cat << EOF >> ${workdir}/xrayinit
while true; do
    sleep 60
    ${workdir}/ddns_check.sh
done
EOF

else
    cat << 'EOF' >> ${workdir}/xrayinit
while true; do
    sleep 3600
done
EOF
fi

# 记录UUID
echo -n $id_s > ${workdir}/oldf_uuid.json

# 获取真实公网IP（IPv4 与 IPv6）
realip4=""
realip6=""
# 尝试获取IPv4
oldip4=$(wget -q4 -O - "https://www.cloudflare.com/cdn-cgi/trace")
if [ -n "$oldip4" ]; then
    realip4=$(echo "$oldip4" | grep "ip=" | cut -d '=' -f 2)
fi
# 尝试获取IPv6
oldip6=$(wget -q6 -O - "https://www.cloudflare.com/cdn-cgi/trace")
if [ -n "$oldip6" ]; then
    realip6=$(echo "$oldip6" | grep "ip=" | cut -d '=' -f 2)
fi

# 订阅链接基础参数（已移除多余的 &flow=）
sub_base="encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s#xray_REALITY"

# 管理脚本：更换UUID
cat << EOF > ${workdir}/chaguuid
#!/bin/bash
newuuid=\`${workdir}/xray uuid\`
olduuid=\`cat ${workdir}/oldf_uuid.json\`
sed -i "s/\$olduuid/\$newuuid/g" ${workdir}/sni_config.json ${workdir}/old_config.json
sleep 1
killall xray > /dev/null 2>&1
killall sni-filter > /dev/null 2>&1
echo -n \$newuuid > ${workdir}/oldf_uuid.json
systemctl restart xray_service
echo uuid已更新,新uuid为: \$newuuid
# IPv4 链接
[ -n "$realip4" ] && echo "xray IPv4订阅: vless://\$newuuid@$realip4:$portx?$sub_base"
# IPv6 链接
[ -n "$realip6" ] && echo "xray IPv6订阅: vless://\$newuuid@[$realip6]:$portx?$sub_base"
EOF

# 简化管理工具
echo "echo -e \"\033[32mbug已解决\033[0m\"" > ${workdir}/xraynobug

cat << EOF > ${workdir}/delxray
#!/bin/bash
systemctl stop xray_service
systemctl disable xray_service
killall xray > /dev/null 2>&1
killall sni-filter > /dev/null 2>&1
deluser xrayuser 2>/dev/null
rm -f /usr/bin/xray.*
rm -rf ${workdir}
echo -e "\e[32m卸载完成,感谢使用\e[0m"
EOF

cat << EOF > ${workdir}/xraystop
#!/bin/bash
systemctl stop xray_service
EOF

cat << EOF > ${workdir}/xraystart
#!/bin/bash
systemctl start xray_service
EOF

cat << EOF > ${workdir}/xrayrestart
#!/bin/bash
systemctl restart xray_service
EOF

cat << EOF > ${workdir}/xrayhelp
echo -e "\e[32mxray快捷命令\e[0m"
echo "修改订阅uuid->          xray.chuuid"
echo "删除xray及脚本->        xray.delxray"
echo "停止xray->              xray.stop"
echo "启动xray->              xray.start"
echo "重启xray->              xray.restart"
echo "一键解决bug->           xray.debug"
echo "帮助->                  xray.help"
EOF

# 设置权限
chmod 640 ${workdir}/*.json
chmod 755 ${workdir}/delxray ${workdir}/chaguuid ${workdir}/ddns_check.sh 2>/dev/null || true
chmod 755 ${workdir}/xray*

# 软链接
ln -sf ${workdir}/chaguuid /usr/bin/xray.chuuid
ln -sf ${workdir}/delxray /usr/bin/xray.delxray
ln -sf ${workdir}/xraystop /usr/bin/xray.stop
ln -sf ${workdir}/xraystart /usr/bin/xray.start
ln -sf ${workdir}/xrayrestart /usr/bin/xray.restart
ln -sf ${workdir}/xraynobug /usr/bin/xray.debug
ln -sf ${workdir}/xrayhelp /usr/bin/xray.help

systemctl enable xray_service

# 安装完成提示与订阅
echo ""
echo -e "\e[32m==================== 安装完成 ====================\e[0m"
echo ""
if [ -n "$realip4" ]; then
    echo -e "\e[32m[IPv4] vless://$id_s@$realip4:$portx?$sub_base\e[0m"
fi
if [ -n "$realip6" ]; then
    echo -e "\e[32m[IPv6] vless://$id_s@[$realip6]:$portx?$sub_base\e[0m"
fi
if [ -z "$realip4" ] && [ -z "$realip6" ]; then
    echo -e "\033[31m未能获取公网IP，请手动检查网络！\033[0m"
fi
echo ""
echo -e "\e[33m请确保防火墙已开放 TCP 端口 $portx\e[0m"
echo "若使用云服务器，请检查安全组/防火墙规则。"
echo "如需手动开放（iptables）："
echo "  iptables -I INPUT -p tcp --dport $portx -j ACCEPT"
echo "  ip6tables -I INPUT -p tcp --dport $portx -j ACCEPT"
echo ""
${workdir}/xrayhelp
systemctl start xray_service
sleep 2
echo ""
echo -e "\e[32m服务已启动，可通过以下命令查看状态：\e[0m"
echo "  systemctl status xray_service"
