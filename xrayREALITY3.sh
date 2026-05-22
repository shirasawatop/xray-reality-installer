#!/bin/bash
echo -e "\e[32m欢迎使用REALITY一键脚本 (最终版)\e[0m"
echo ""
echo "         _      _   __        _                   _ "
echo "   ___  | |  __| | / _| _ __ (_)  ___  _ __    __| |"
echo "  / _ \ | | / _I || |_ | __|| |  / _ \| |_ \  / _| |"
echo " | (_) || || (_| ||  _|| |   | ||  __/| | | || (_| |"
echo "  \___/ |_| \__,_||_|  |_|   |_| \___||_| |_| \__,_|"
echo "                                                    "
sleep 1

# ---------- IP 检测 ----------
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
    [ ${#ipv4_interfaces[@]} -eq 0 ] && echo "  未检测到IPv4地址" || for i in "${!ipv4_interfaces[@]}"; do echo "  [$((i+1))] ${ipv4_interfaces[$i]}"; done
    echo -e "\e[32m检测到的IPv6地址:\e[0m"
    [ ${#ipv6_interfaces[@]} -eq 0 ] && echo "  未检测到IPv6地址" || for i in "${!ipv6_interfaces[@]}"; do echo "  [$((i+1))] ${ipv6_interfaces[$i]}"; done
}

detect_ips

# ---------- 自动选择出口 IP ----------
att_ipv6=""
for ipv6 in "${ipv6_addresses[@]}"; do
    [[ "$ipv6" == 2600:* ]] && { att_ipv6="$ipv6"; break; }
done
if [[ -z "$att_ipv6" ]]; then
    echo -e "\e[31m未检测到AT&T IPv6（2600:开头），降级使用第一个公网IPv6。\e[0m"
    att_ipv6="${ipv6_addresses[0]}"
fi
echo -e "\e[32m自动选择AT&T IPv6出口: $att_ipv6\e[0m"

ipv4_outbound=""
if [ ${#ipv4_addresses[@]} -gt 0 ]; then
    ipv4_outbound="${ipv4_addresses[0]}"
    echo -e "\e[32m自动选择IPv4出口: $ipv4_outbound\e[0m"
else
    echo -e "\e[33m未检测到IPv4，将仅使用IPv6出口。\e[0m"
fi

# ---------- 用户输入 ----------
ipaddr=""
portx=""
domain_s=""
fingerprint="chrome"
echo "安装 xray (REALITY)"
echo -e "\e[32m请输入xray监听IP,默认0.0.0.0\e[0m"
read ipaddr
echo -e "\e[32m请输入xray监听端口,默认443\e[0m"
read portx
echo -e "\e[32m请输入xray伪装的域名,默认tesla.com\e[0m"
read domain_s

fp_choice=$(whiptail --title "选择浏览器指纹" --menu "使用 ↑↓ 选择，回车确认" 15 50 8 \
    "chrome" "Chrome浏览器 (推荐)" \
    "firefox" "Firefox浏览器" \
    "safari" "Safari浏览器" \
    "ios" "iOS Safari" \
    "edge" "Microsoft Edge" 3>&1 1>&2 2>&3)
[[ "$fp_choice" != "" ]] && fingerprint="$fp_choice"
[[ "$ipaddr" == "" ]] && ipaddr="0.0.0.0"
[[ "$portx" == "" ]] && portx="443"
[[ "$domain_s" == "" ]] && domain_s="tesla.com"
echo "xray config: $ipaddr:$portx?sni=$domain_s&fp=$fingerprint"

# ---------- 环境检测 ----------
ping -c 2 8.8.8.8 &> /dev/null || { echo -e "\033[31mERR: 没有网络连接\033[0m"; exit; }
command -v wget > /dev/null 2>&1 || { echo -e "\033[31mwget不存在,请apt install wget安装\033[0m"; exit; }
command -v openssl > /dev/null 2>&1 || { echo -e "\033[31mopenssl不存在,请apt install openssl安装\033[0m"; exit; }
command -v unzip > /dev/null 2>&1 || { echo -e "\033[31munzip不存在,请apt install unzip安装\033[0m"; exit; }

# ---------- 下载并安装 xray (只下载xray，无hy2) ----------
[ "$(id -u)" == 0 ] && workdir=/var/xray || workdir=${HOME}/.xray
mkdir -p ${workdir}
architecture=$(uname -m)
case $architecture in
    x86_64)  wget -q -P ${workdir} https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-64.zip ;;
    i386|i686) wget -q -P ${workdir} https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-32.zip ;;
    aarch64) wget -q -P ${workdir} https://github.com/XTLS/Xray-core/releases/download/v25.10.15/Xray-linux-arm64-v8a.zip ;;
    *) echo -e "\033[31未知架构: $architecture,请手动安装\033[0m"; exit ;;
esac
cd ${workdir}
unzip -o *.zip   # 自动覆盖（-o）
chmod 755 ${workdir}/xray
rm -f *.zip
id_s=$(${workdir}/xray uuid)
xray_x25519=$(${workdir}/xray x25519)
shortIds=$(openssl rand -hex 6)
private_old=$(echo "$xray_x25519" | grep "PrivateKey:" | cut -d ' ' -f 2-)
public_old=$(echo "$xray_x25519" | grep "Password:" | cut -d ' ' -f 2-)
mkdir -p ${workdir}/socket

# ---------- 生成配置（关键：保留 domainStrategy: IPOnDemand） ----------
outbounds_json='[
    {
        "protocol": "freedom",
        "tag": "direct-ipv6",
        "settings": { "domainStrategy": "UseIPv6" },
        "sendThrough": "'$att_ipv6'"
    },
    {
        "protocol": "freedom",
        "tag": "direct-ipv4",
        "settings": { "domainStrategy": "UseIPv4" },
        "sendThrough": "'$ipv4_outbound'"
    }
]'

routing_json='{
    "domainStrategy": "IPOnDemand",
    "rules": [
        { "type": "field", "outboundTag": "direct-ipv6", "ip": ["2000::/3", "::/0"] },
        { "type": "field", "outboundTag": "direct-ipv4", "ip": ["0.0.0.0/0"] }
    ]
}'

# sni_config.json（通过 unix socket）
cat << EOF > ${workdir}/sni_config.json
{"log": {"loglevel": "warning"},"inbounds": [{
    "listen": "${workdir}/socket/xray.friend,0600",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s", "flow": "xtls-rprx-vision"}],
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
"outbounds": $outbounds_json,
"routing": $routing_json
}
EOF

# old_config.json（直接监听端口）
cat << EOF > ${workdir}/old_config.json
{"log": {"loglevel": "warning"},"inbounds": [{
    "port": $portx,
    "listen": "$ipaddr",
    "protocol": "vless",
    "settings": {
        "clients": [{"id": "$id_s", "flow": "xtls-rprx-vision"}],
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
"outbounds": $outbounds_json,
"routing": $routing_json
}
EOF

# 显示出口信息
echo ""
echo -e "\e[32m出口IP配置信息:\e[0m"
[ -n "$ipv4_outbound" ] && echo "  IPv4出口: $ipv4_outbound"
[ -n "$att_ipv6" ] && echo "  IPv6出口: $att_ipv6"

# ---------- 用户 & 权限 ----------
if [ "$(id -u)" == 0 ]; then
    useradd -M -s /sbin/nologin xrayuser 2>/dev/null
    chown -R :xrayuser ${workdir}/*.json
    chown xrayuser ${workdir}/ ${workdir}/socket
fi

# ---------- sni-filter ----------
echo "#!/bin/bash" > ${workdir}/xrayinit
chmod 755 ${workdir}/xrayinit
wget -q -P ${workdir} https://github.com/oldfriendme/REALITY-sni-filter/releases/download/v0.2/autobuild.zip
unzip -o autobuild.zip   # 自动覆盖
rm -f autobuild.zip
case $architecture in
    x86_64)  mv sni-filter-amd64 sni-filter ;;
    i386|i686) mv sni-filter-i386 sni-filter ;;
    aarch64) mv sni-filter-arm64 sni-filter ;;
esac
chmod 755 sni-filter
setcap 'cap_net_bind_service=+ep' ${workdir}/sni-filter

# ---------- systemd 服务 ----------
cat << 'EOF' > /etc/systemd/system/xray_service.service
[Unit]
Description=xray Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/sh /var/xray/xrayinit
User=xrayuser

[Install]
WantedBy=multi-user.target
EOF

echo "setsid ${workdir}/sni-filter -L=tcp://${ipaddr}:${portx} -F=unix://${workdir}/socket/xray.friend -S=$domain_s &" >> ${workdir}/xrayinit
echo "setsid ${workdir}/xray -c ${workdir}/sni_config.json &" >> ${workdir}/xrayinit
echo "on" > ${workdir}/statusfilter
echo "while true; do sleep 3600; done" >> ${workdir}/xrayinit

# ---------- 快捷命令 ----------
echo -n $id_s > ${workdir}/oldf_uuid.json
realip=$(wget -q -O - "https://www.cloudflare.com/cdn-cgi/trace" | grep "ip=" | cut -d '=' -f 2)
[ ${#realip} -gt 16 ] && realip=[$realip]

# uuid更新脚本
cat << 'CHAGUUID' > ${workdir}/chaguuid
#!/bin/bash
workdir="/var/xray"
newuuid=$(${workdir}/xray uuid)
olduuid=$(cat ${workdir}/oldf_uuid.json)
sed -i "s/$olduuid/$newuuid/g" ${workdir}/old_config.json ${workdir}/sni_config.json
echo -n $newuuid > ${workdir}/oldf_uuid.json
systemctl restart xray_service
echo "uuid已更新，新uuid为: $newuuid"
CHAGUUID
chmod 755 ${workdir}/chaguuid

# 卸载脚本
cat << 'DEL' > ${workdir}/delxray
#!/bin/bash
systemctl stop xray_service
systemctl disable xray_service
killall xray sni-filter 2>/dev/null
deluser xrayuser 2>/dev/null
rm -f /usr/bin/xray.* /etc/systemd/system/xray_service.service
rm -rf /var/xray
echo "已卸载"
DEL
chmod 755 ${workdir}/delxray

# 快捷链接
ln -sf ${workdir}/chaguuid /usr/bin/xray.chuuid
ln -sf ${workdir}/delxray /usr/bin/xray.delxray
ln -sf ${workdir}/xrayinit /usr/bin/xray.start
ln -sf ${workdir}/xrayinit /usr/bin/xray.restart

# ---------- 自动更新 AT&T IPv6 ----------
echo "$att_ipv6" > ${workdir}/last_att_ipv6.txt
cat << 'AUTOUPDATE' > ${workdir}/auto_update_ip.sh
#!/bin/bash
workdir="/var/xray"
last_ip_file="${workdir}/last_att_ipv6.txt"
config_sni="${workdir}/sni_config.json"
config_old="${workdir}/old_config.json"
current_ip=""
for ip in $(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | grep -v '^::1'); do
    [[ "$ip" == 2600:* ]] && { current_ip="$ip"; break; }
done
[ -z "$current_ip" ] && exit 0
last_ip=$(cat "$last_ip_file" 2>/dev/null)
[ "$current_ip" == "$last_ip" ] && exit 0
echo "AT&T IPv6 已变化: $last_ip -> $current_ip"
sed -i "s/\"sendThrough\": \"$last_ip\"/\"sendThrough\": \"$current_ip\"/g" "$config_sni" "$config_old"
echo "$current_ip" > "$last_ip_file"
systemctl restart xray_service
echo "Xray已使用新IPv6出口重启"
AUTOUPDATE
chmod +x ${workdir}/auto_update_ip.sh
(crontab -l 2>/dev/null; echo "* * * * * ${workdir}/auto_update_ip.sh") | crontab -
echo -e "\e[32m已添加自动更新IP的cron任务（每分钟检查）\e[0m"

# ---------- 完成 ----------
systemctl daemon-reload
systemctl enable xray_service
systemctl start xray_service
echo ""
echo -e "\e[32m安装完成！你的订阅链接：\e[0m"
echo "vless://$id_s@$realip:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s#xray_REALITY"
echo ""
echo -e "\e[32m快捷命令：\e[0m"
echo "  修改uuid: xray.chuuid"
echo "  卸载:     xray.delxray"
