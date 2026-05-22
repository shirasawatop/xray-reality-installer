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
    
    # 获取所有网络接口
    interfaces=$(ip -o link show | awk -F': ' '{print $2}')
    
    for iface in $interfaces; do
        # 跳过lo和docker等虚拟接口
        if [[ "$iface" == "lo" ]] || [[ "$iface" == docker* ]] || [[ "$iface" == br-* ]] || [[ "$iface" == veth* ]]; then
            continue
        fi
        
        # 获取所有IPv4地址
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
        
        # 获取所有公网IPv6地址（排除fe80开头的本地链路地址和::1）
        ipv6_list=$(ip -6 addr show $iface 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | grep -v '^::1')
        for ipv6 in $ipv6_list; do
            ipv6_addresses+=("$ipv6")
            ipv6_interfaces+=("$iface: $ipv6")
        done
    done
    
    # 显示检测结果
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

# 调用IP检测函数
detect_ips

# ========== 自动选择出口IP ==========
# 自动选择AT&T IPv6（2600:开头）作为主出口
att_ipv6=""
for ipv6 in "${ipv6_addresses[@]}"; do
    if [[ "$ipv6" == 2600:* ]]; then
        att_ipv6="$ipv6"
        break
    fi
done

if [[ -z "$att_ipv6" ]]; then
    echo -e "\e[31m未检测到AT&T IPv6（2600:开头），将降级使用第一个公网IPv6。\e[0m"
    att_ipv6="${ipv6_addresses[0]}"
fi

echo -e "\e[32m自动选择AT&T IPv6出口: $att_ipv6\e[0m"

# 自动选择IPv4出口（第一个检测到的IPv4）
ipv4_outbound=""
if [ ${#ipv4_addresses[@]} -gt 0 ]; then
    ipv4_outbound="${ipv4_addresses[0]}"
    echo -e "\e[32m自动选择IPv4出口: $ipv4_outbound\e[0m"
else
    echo -e "\e[33m未检测到IPv4地址，将仅使用IPv6出口。\e[0m"
fi

# 设置全局变量
ipv6_outbound="$att_ipv6"
use_ipv6_priority="yes"      # IPv6优先
# ========== 自动选择出口IP结束 ==========

sec=$(whiptail --title "选择安装的组件" --checklist \
  "使用空格选择，多选后回车确认" 15 50 4 \
  "xray" "安装Reality" OFF \
  "hy2" "安装Hysteria2 (beta)" OFF 3>&1 1>&2 2>&3)

ipaddr=""
portx=""
hy2ipaddr=""
hy2mh=""
domain_s=""
domain_hy2=""
hy2portx=""
is_install=0
fingerprint="chrome"  # 默认指纹

echo ""

if [[ $sec == *xray* ]]; then
echo "安装 xray"
echo -e "\e[32m请输入xray监听IP,默认0.0.0.0\e[0m"
read ipaddr
echo -e "\e[32m请输入xray监听端口,默认443\e[0m"
read portx
echo -e "\e[32m请输入xray伪装的域名,默认tesla.com\e[0m"
read domain_s

# 选择浏览器指纹
fp_choice=$(whiptail --title "选择浏览器指纹" --menu \
    "使用 ↑↓ 选择，回车确认" 15 50 8 \
    "chrome" "Chrome浏览器 (推荐)" \
    "firefox" "Firefox浏览器" \
    "safari" "Safari浏览器" \
    "ios" "iOS Safari" \
    "android" "Android浏览器" \
    "edge" "Microsoft Edge" \
    "360" "360浏览器" \
    "qq" "QQ浏览器" 3>&1 1>&2 2>&3)

if [[ "$fp_choice" != "" ]]; then
fingerprint="$fp_choice"
fi
if [[ "$ipaddr" == "" ]]; then
ipaddr="0.0.0.0"
fi
if [[ "$portx" == "" ]]; then
portx="443"
fi
if [[ "$domain_s" == "" ]]; then
domain_s="tesla.com"
fi
is_install=1
echo "xray config: $ipaddr:$portx?sni=$domain_s&fp=$fingerprint"
echo ""
fi

if [[ $sec == *hy2* ]]; then
echo "安装 hy2"
echo -e "\e[32m请输入hy2监听IP,默认:0.0.0.0\e[0m"
read hy2ipaddr
echo -e "\e[32m请输入hy2监听IP,默认:4443\e[0m"
read hy2portx
echo -e "\e[32m请输入hy2宽带,默认:100\e[0m"
read hy2mh
echo -e "\e[32m请输入hy2伪装的域名,默认tesla.com\e[0m"
read domain_hy2
if [[ "$hy2ipaddr" == "" ]]; then
hy2ipaddr="0.0.0.0"
fi
if [[ "$hy2portx" == "" ]]; then
hy2portx="4443"
fi
if [[ "$hy2mh" == "" ]]; then
hy2mh="100"
fi
if [[ "$domain_hy2" == "" ]]; then
domain_hy2="tesla.com"
fi
is_install=1
hy2ipaddr=${hy2ipaddr}:${hy2portx}
echo "hy2 config: $hy2ipaddr?sni=$domain_hy2&bw=$hy2mh mbps"
echo ""
fi
if [ $is_install -eq 0 ]; then
echo ""
echo -e "\e[32mINFO: 未选中Reality，跳过\e[0m"
echo ""
echo -e "\e[32mINFO: 未选中Hysteria2，跳过\e[0m"
echo ""
echo -e "\033[31mERR: 没有安装的组件，退出\033[0m"
exit
fi

sleep 1
outlougt=$(whiptail --title "请选择落地设置" --menu "使用 ↑↓ 选择，回车确认" 15 50 4 \
  "direct" "直接落地"\
  "socks" "socks5落地" 3>&1 1>&2 2>&3)

if ping -c 2 8.8.8.8 &> /dev/null
then
if [[ "$ipaddr" != "" ]]; then
	echo -e "\e[32mINFO: 开始下载xray\e[0m"
fi
if [[ "$hy2ipaddr" != "" ]]; then
	echo -e "\e[32mINFO: 开始下载Hysteria2\e[0m"
fi
else
	echo -e "\033[31mERR: 没有网络连接\033[0m"
	exit
fi
if command -v wget > /dev/null 2>&1; then
	echo "Checking wget is installed."
else
	echo -e "\033[31mwget不存在,请apt install wget安装\033[0m"
	exit
fi
if command -v openssl > /dev/null 2>&1; then
    echo "Checking openssl is installed."
else
    echo -e "\033[31mopenssl不存在,请apt install openssl安装\033[0m"
	exit
fi
if command -v unzip > /dev/null 2>&1; then
    echo "Checking unzip is installed."
else
    echo -e "\033[31munzip不存在,请apt install unzip安装\033[0m"
	exit
fi

if [ "$(id -u)" == 0 ]; then
workdir=/var/xray
else
workdir=${HOME}/.xray
fi

mkdir ${workdir}
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

if [[ "$hy2ipaddr" != "" ]]; then
if [[ "$architecture" == "x86_64" ]]; then
wget -P ${workdir} https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.5/hysteria-linux-amd64
elif [[ "$architecture" == "i386" || "$architecture" == "i686" ]]; then
wget -P ${workdir} https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.5/hysteria-linux-386
elif [[ "$architecture" == "aarch64" ]]; then
wget -P ${workdir} https://github.com/apernet/hysteria/releases/download/app%2Fv2.6.5/hysteria-linux-arm64
else
echo -e "\033[31未知架构: $architecture,请手动安装\033[0m"
exit
fi
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
mkdir ${workdir}/socket

# 生成outbounds配置（使用全局变量 ipv4_outbound, ipv6_outbound）
generate_outbounds() {
    local outbound_type="$1"
    local socks5IP="$2"
    local socks5port="$3"
    local socks5user="$4"
    local socks5pass="$5"
    
    local outbounds_json=""
    
    if [[ "$outbound_type" == "socks" ]]; then
        outbounds_json='['
        if [[ -n "$ipv6_outbound" ]]; then
            outbounds_json+='
        {
            "tag": "direct-ipv6",
            "protocol": "socks",
            "settings": {
                "servers": [
                    {
                        "address": "'"$socks5IP"'",
                        "port": '"$socks5port"',
                        "users": [
                            {
                                "user": "'"$socks5user"'",
                                "pass": "'"$socks5pass"'",
                                "level": 0
                            }
                        ]
                    }
                ]
            },
            "sendThrough": "'"$ipv6_outbound"'"
        },'
        fi
        if [[ -n "$ipv4_outbound" ]]; then
            outbounds_json+='
        {
            "tag": "direct-ipv4",
            "protocol": "socks",
            "settings": {
                "servers": [
                    {
                        "address": "'"$socks5IP"'",
                        "port": '"$socks5port"',
                        "users": [
                            {
                                "user": "'"$socks5user"'",
                                "pass": "'"$socks5pass"'",
                                "level": 0
                            }
                        ]
                    }
                ]
            },
            "sendThrough": "'"$ipv4_outbound"'"
        },'
        fi
        outbounds_json="${outbounds_json%,}"
        outbounds_json+='
    ]'
    else
        # 直接出站
        outbounds_json='['
        if [[ -n "$ipv6_outbound" ]]; then
            outbounds_json+='
        {
            "protocol": "freedom",
            "tag": "direct-ipv6",
            "settings": {
                "domainStrategy": "UseIPv6"
            },
            "sendThrough": "'"$ipv6_outbound"'"
        },'
        fi
        if [[ -n "$ipv4_outbound" ]]; then
            outbounds_json+='
        {
            "protocol": "freedom",
            "tag": "direct-ipv4",
            "settings": {
                "domainStrategy": "UseIPv4"
            },
            "sendThrough": "'"$ipv4_outbound"'"
        },'
        fi
        outbounds_json="${outbounds_json%,}"
        outbounds_json+='
    ]'
    fi
    
    echo "$outbounds_json"
}

# 生成routing配置（IPv6优先）
generate_routing() {
    local routing_json=''
    
    if [[ -n "$ipv6_outbound" ]] && [[ -n "$ipv4_outbound" ]]; then
        # 两个出口都存在，IPv6优先
        routing_json='
    "routing": {
        "domainStrategy": "IPOnDemand",
        "rules": [
            {
                "type": "field",
                "outboundTag": "direct-ipv6",
                "ip": ["2000::/3", "::/0"]
            },
            {
                "type": "field",
                "outboundTag": "direct-ipv4",
                "ip": ["0.0.0.0/0"]
            }
        ]
    }'
    elif [[ -n "$ipv6_outbound" ]]; then
        routing_json='
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "outboundTag": "direct-ipv6",
                "network": "tcp,udp"
            }
        ]
    }'
    elif [[ -n "$ipv4_outbound" ]]; then
        routing_json='
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "outboundTag": "direct-ipv4",
                "network": "tcp,udp"
            }
        ]
    }'
    else
        routing_json=''
    fi
    
    echo "$routing_json"
}

if [[ "$outlougt" == "socks" ]]; then
socks5IP=""
socks5port=""
socks5user=""
socks5pass=""
echo -e "\e[32m请输入socks5 IP,格式: 192.168.1.1\e[0m"
read socks5IP
echo -e "\e[32m请输入socks5 port,格式: 1080\e[0m"
read socks5port
echo -e "\e[32m请输入socks5 user,格式: username\e[0m"
read socks5user
echo -e "\e[32m请输入socks5 pass,格式: password\e[0m"
read socks5pass

outbounds_config=$(generate_outbounds "socks" "$socks5IP" "$socks5port" "$socks5user" "$socks5pass")
routing_config=$(generate_routing)

cat << EOF > ${workdir}/sni_config.json
{"log": {"loglevel": "warning"},"inbounds": [{
            "listen": "${workdir}/socket/xray.friend,0600",
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$id_s",
						"flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$domain_s:443",
                    "serverNames": [
                        "$domain_s"
                    ],
                    "privateKey": "$private_old",
                    "shortIds": [
                        "$shortIds"
                    ]
                }
            }
        }
    ],
    "outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

cat << EOF > ${workdir}/old_config.json
{"log": {"loglevel": "warning"},"inbounds": [{
"port": $portx,
            "listen": "$ipaddr",
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$id_s",
						"flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$domain_s:443",
                    "serverNames": [
                        "$domain_s"
                    ],
                    "privateKey": "$private_old",
                    "shortIds": [
                        "$shortIds"
                    ]
                }
            }
        }
    ],
    "outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

if [[ "$hy2ipaddr" != "" ]]; then
mv hysteria-linux* hysteria
chmod 755 hysteria
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ${workdir}/server.key -out ${workdir}/server.crt -subj "/C=US/CN=${domain_hy2}" > /dev/null 2>&1
mkdir ${workdir}/www
echo > ${workdir}/www/index.html
cat << EOF > ${workdir}/hy2_config.json
{
	"listen": "$hy2ipaddr",
	"auth": {
		"type": "password",
		"password": "$id_s"
	},
	"bandwidth": {
		"up": "$hy2mh mbps",
		"down": "$hy2mh mbps"
	},
	"tls": {
		"type": "tls",
		"cert": "${workdir}/server.crt",
		"key": "${workdir}/server.key"
	},
	"masquerade": {
		"type": "file",
		"file": {
			"dir": "${workdir}/www/index.html"
		}
	},
	"outbounds": [
		{
			"name": "socksout",
			"type": "socks5",
			"socks5": {
				"addr": "${socks5IP}:${socks5port}",
				"username": "$socks5user",
				"password": "$socks5pass"
			}
		}
	]
}
EOF
fi
else
# 直接落地模式
outbounds_config=$(generate_outbounds "direct")
routing_config=$(generate_routing)

cat << EOF > ${workdir}/sni_config.json
{"log": {"loglevel": "warning"},"inbounds": [{
            "listen": "${workdir}/socket/xray.friend,0600",
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$id_s",
						"flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$domain_s:443",
                    "serverNames": [
                        "$domain_s"
                    ],
                    "privateKey": "$private_old",
                    "shortIds": [
                        "$shortIds"
                    ]
                }
            }
        }
    ],
    "outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

cat << EOF > ${workdir}/old_config.json
{"log": {"loglevel": "warning"},"inbounds": [{
"port": $portx,
            "listen": "$ipaddr",
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$id_s",
						"flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$domain_s:443",
                    "serverNames": [
                        "$domain_s"
                    ],
                    "privateKey": "$private_old",
                    "shortIds": [
                        "$shortIds"
                    ]
                }
            }
        }
    ],
    "outbounds": $outbounds_config$( [[ -n "$routing_config" ]] && echo "," )$routing_config
}
EOF

if [[ "$hy2ipaddr" != "" ]]; then
mv hysteria-linux* hysteria
chmod 755 hysteria
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ${workdir}/server.key -out ${workdir}/server.crt -subj "/C=US/CN=${domain_hy2}" > /dev/null 2>&1
mkdir ${workdir}/www
echo > ${workdir}/www/index.html
cat << EOF > ${workdir}/hy2_config.json
{
	"listen": "$hy2ipaddr",
	"auth": {
		"type": "password",
		"password": "$id_s"
	},
	"bandwidth": {
		"up": "$hy2mh mbps",
		"down": "$hy2mh mbps"
	},
	"tls": {
		"type": "tls",
		"cert": "${workdir}/server.crt",
		"key": "${workdir}/server.key"
	},
	"masquerade": {
		"type": "file",
		"file": {
			"dir": "${workdir}/www/index.html"
		}
	},
	"outbounds": [
		{
			"name": "directout",
			"type": "direct"
		}
	]
}
EOF
fi
fi

# 显示出口配置信息
echo ""
echo -e "\e[32m出口IP配置信息:\e[0m"
if [[ -n "$ipv4_outbound" ]]; then
    echo "  IPv4出口: $ipv4_outbound"
fi
if [[ -n "$ipv6_outbound" ]]; then
    echo "  IPv6出口: $ipv6_outbound"
fi
if [[ "$use_ipv6_priority" == "yes" ]]; then
    echo "  优先级: IPv6优先"
else
    echo "  优先级: IPv4优先"
fi
echo ""

if [ "$(id -u)" == 0 ]; then
echo "当前root用户，降权到非root初始化脚本"
useradd xrayuser
usermod -s /sbin/nologin xrayuser
if [[ "$hy2ipaddr" != "" ]]; then
chown xrayuser ${workdir}/server.*
fi
chown :xrayuser ${workdir}/*.json
chown xrayuser ${workdir}/
chown xrayuser ${workdir}/socket
fi
echo "#!/bin/bash" > ${workdir}/xrayinit
chmod 755 ${workdir}/xrayinit
wget -P ${workdir} https://github.com/oldfriendme/REALITY-sni-filter/releases/download/v0.2/autobuild.zip
unzip autobuild.zip
rm autobuild.zip
if [[ "$architecture" == "x86_64" ]]; then
mv sni-filter-amd64 sni-filter
elif [[ "$architecture" == "i386" || "$architecture" == "i686" ]]; then
mv sni-filter-i386 sni-filter
elif [[ "$architecture" == "aarch64" ]]; then
mv sni-filter-arm64 sni-filter
else
echo "echo maybe soon" > sni-filter
fi
chmod 755 sni-filter
setcap 'cap_net_bind_service=+ep' ${workdir}/sni-filter
echo "[Unit]" > /etc/systemd/system/xray_service.service
echo "Description=xray Service" >> /etc/systemd/system/xray_service.service
echo "After=network.target" >> /etc/systemd/system/xray_service.service
echo "" >> /etc/systemd/system/xray_service.service
echo "[Service]" >> /etc/systemd/system/xray_service.service
echo "Type=simple" >> /etc/systemd/system/xray_service.service
echo "ExecStart=/usr/bin/sh ${workdir}/xrayinit" >> /etc/systemd/system/xray_service.service
echo "User=xrayuser" >> /etc/systemd/system/xray_service.service
echo "" >> /etc/systemd/system/xray_service.service
echo "[Install]" >> /etc/systemd/system/xray_service.service
echo "WantedBy=multi-user.target" >> /etc/systemd/system/xray_service.service
if [[ "$ipaddr" != "" ]]; then
echo "setsid ${workdir}/sni-filter -L=tcp://${ipaddr}:${portx} -F=unix://${workdir}/socket/xray.friend -S=$domain_s &" >> ${workdir}/xrayinit
echo "setsid ${workdir}/xray -c ${workdir}/sni_config.json &" >> ${workdir}/xrayinit
echo "on" > ${workdir}/statusfilter
fi
if [[ "$hy2ipaddr" != "" ]]; then
echo "setsid ${workdir}/hysteria server -c ${workdir}/hy2_config.json &" >> ${workdir}/xrayinit
fi
echo "while true" >> ${workdir}/xrayinit
echo "do" >> ${workdir}/xrayinit
echo "sleep 3600" >> ${workdir}/xrayinit
echo "done" >> ${workdir}/xrayinit
echo -n $id_s > ${workdir}/oldf_uuid.json
oldip=$(wget -q -O - "https://www.cloudflare.com/cdn-cgi/trace")
realip=$(echo "$oldip" | grep "ip=" | cut -d '=' -f 2)
if [ ${#realip} -gt 16 ]; then
	realip=[$realip]
fi
echo "#!/bin/bash" > ${workdir}/chaguuid
echo "newuuid=\`${workdir}/xray uuid\`" >> ${workdir}/chaguuid
echo "olduuid=\`cat ${workdir}/oldf_uuid.json\`" >> ${workdir}/chaguuid
echo "sed -i \"s/\$olduuid/\$newuuid/g\" ${workdir}/old_config.json" >> ${workdir}/chaguuid
echo "sed -i \"s/\$olduuid/\$newuuid/g\" ${workdir}/sni_config.json" >> ${workdir}/chaguuid
echo "sleep 1" >> ${workdir}/chaguuid
if [[ "$ipaddr" != "" ]]; then
echo "killall xray > /dev/null 2>&1" >> ${workdir}/chaguuid
echo "killall sni-filter > /dev/null 2>&1" >> ${workdir}/chaguuid
fi
if [[ "$hy2ipaddr" != "" ]]; then
echo "sed -i \"s/\$olduuid/\$newuuid/g\" ${workdir}/hy2_config.json" >> ${workdir}/chaguuid
fi
echo "echo -n \$newuuid > ${workdir}/oldf_uuid.json" >> ${workdir}/chaguuid
echo "systemctl restart xray_service" >> ${workdir}/chaguuid
if [[ "$ipaddr" != "" ]]; then
echo "olddy=\"$realip:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s&flow=$old_flow#xray_REALITY\"" >> ${workdir}/chaguuid
fi
if [[ "$hy2ipaddr" != "" ]]; then
echo "oldhy2=\"$realip:$hy2portx?sni=$domain_hy2&insecure=1#hysteria2\"" >> ${workdir}/chaguuid
fi
echo "echo uuid已更新,新uuid为: \$newuuid" >> ${workdir}/chaguuid
if [[ "$ipaddr" != "" ]]; then
echo "echo xray新订阅为: vless://\$newuuid@\$olddy" >> ${workdir}/chaguuid
fi
if [[ "$hy2ipaddr" != "" ]]; then
echo "echo hy2新订阅为: hysteria2://\$newuuid@\$oldhy2" >> ${workdir}/chaguuid
fi
echo "#!/bin/bash" > ${workdir}/closedsni
if [[ "$ipaddr" != "" ]]; then
echo "setcap 'cap_net_bind_service=+ep' ${workdir}/xray" >> ${workdir}/closedsni
echo "echo \"#!/bin/bash\" > ${workdir}/xrayinit" >> ${workdir}/closedsni
if [[ "$hy2ipaddr" != "" ]]; then
echo "echo \"setsid ${workdir}/hysteria server -c ${workdir}/hy2_config.json &\" >> ${workdir}/xrayinit" >> ${workdir}/closedsni
fi
echo "echo \"setsid ${workdir}/xray -c ${workdir}/old_config.json &\" >> ${workdir}/xrayinit" >> ${workdir}/closedsni
echo "echo while true >> ${workdir}/xrayinit" >> ${workdir}/closedsni
echo "echo do >> ${workdir}/xrayinit" >> ${workdir}/closedsni
echo "echo sleep 3600 >> ${workdir}/xrayinit" >> ${workdir}/closedsni
echo "echo done >> ${workdir}/xrayinit" >> ${workdir}/closedsni
echo "killall xray > /dev/null 2>&1" >> ${workdir}/closedsni
echo "killall sni-filter > /dev/null 2>&1" >> ${workdir}/closedsni
echo "sleep 1" >> ${workdir}/closedsni
echo "rm ${workdir}/statusfilter" >> ${workdir}/closedsni
echo "echo 已关闭,正在重启xray" >> ${workdir}/closedsni
echo "systemctl restart xray_service" >> ${workdir}/closedsni
echo "olddy=\"$realip:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s&flow=$old_flow#xray_REALITY\"" >> ${workdir}/closedsni
echo "olduuid=\`cat ${workdir}/oldf_uuid.json\`" >> ${workdir}/closedsni
echo "echo 订阅为: vless://\$olduuid@\$olddy" >> ${workdir}/closedsni
fi
echo 
echo "#!/bin/bash" > ${workdir}/opensni
if [[ "$ipaddr" != "" ]]; then
echo "echo \"#!/bin/bash\" > ${workdir}/xrayinit" >> ${workdir}/opensni
echo "echo \"setsid ${workdir}/sni-filter -L=tcp://$ipaddr:$portx -F=unix://${workdir}/socket/xray.friend -S=$domain_s &\" >> ${workdir}/xrayinit" >> ${workdir}/opensni
echo "echo \"setsid ${workdir}/xray -c ${workdir}/sni_config.json &\" >> ${workdir}/xrayinit" >> ${workdir}/opensni
if [[ "$hy2ipaddr" != "" ]]; then
echo "echo \"setsid ${workdir}/hysteria server -c ${workdir}/hy2_config.json &\" >> ${workdir}/xrayinit" >> ${workdir}/opensni
fi
echo "echo while true >> ${workdir}/xrayinit" >> ${workdir}/opensni
echo "echo do >> ${workdir}/xrayinit" >> ${workdir}/opensni
echo "echo sleep 3600 >> ${workdir}/xrayinit" >> ${workdir}/opensni
echo "echo done >> ${workdir}/xrayinit" >> ${workdir}/opensni
echo "killall xray > /dev/null 2>&1" >> ${workdir}/opensni
echo "sleep 1" >> ${workdir}/opensni
echo "echo \"on\" > ${workdir}/statusfilter" >> ${workdir}/opensni
echo "echo 已打开,正在重启xray" >> ${workdir}/opensni
echo "systemctl restart xray_service" >> ${workdir}/opensni
echo "olddy=\"$realip:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s&flow=$old_flow#xray_REALITY\"" >> ${workdir}/opensni
echo "olduuid=\`cat ${workdir}/oldf_uuid.json\`" >> ${workdir}/opensni
echo "echo 订阅为: vless://\$olduuid@\$olddy" >> ${workdir}/opensni
fi
echo
chmod 755 ${workdir}/sni*
echo "echo -e \"\033[32mbug已解决\033[0m\"" >> ${workdir}/xraynobug
echo "#!/bin/bash" > ${workdir}/delxray
echo "systemctl stop xray_service" >> ${workdir}/delxray
echo "systemctl disable xray_service" >> ${workdir}/delxray
echo "killall xray > /dev/null 2>&1" >> ${workdir}/delxray
echo "killall sni-filter > /dev/null 2>&1" >> ${workdir}/delxray
if [[ "$hy2ipaddr" != "" ]]; then
echo "killall hysteria > /dev/null 2>&1" >> ${workdir}/delxray
fi
echo "deluser xrayuser" >> ${workdir}/delxray
echo "rm /usr/bin/xray.*" >> ${workdir}/delxray
if [[ "$hy2ipaddr" != "" ]]; then
echo "rm ${workdir}/www/*" >> ${workdir}/delxray
echo "rmdir ${workdir}/www" >> ${workdir}/delxray
fi
echo "rm -r ${workdir}/socket" >> ${workdir}/delxray
echo "rm ${workdir}/*" >> ${workdir}/delxray
echo "rmdir ${workdir}" >> ${workdir}/delxray
echo "echo -e \"\e[32m卸载完成,感谢使用\e[0m\"" >> ${workdir}/delxray
echo "#!/bin/bash" > ${workdir}/xraystop
echo "if [ -e \"${workdir}/statusfilter\" ]; then" >> ${workdir}/xraystop
if [[ "$ipaddr" != "" ]]; then
echo "killall xray > /dev/null 2>&1" >> ${workdir}/xraystop
echo "killall sni-filter > /dev/null 2>&1" >> ${workdir}/xraystop
fi
if [[ "$hy2ipaddr" != "" ]]; then
echo "killall hysteria > /dev/null 2>&1" >> ${workdir}/delxray
fi
echo "systemctl stop xray_service" >> ${workdir}/xraystop
echo "else" >> ${workdir}/xraystop
echo "systemctl stop xray_service" >> ${workdir}/xraystop
echo "fi" >> ${workdir}/xraystop
echo "#!/bin/bash" > ${workdir}/xraystart
echo "systemctl start xray_service" >> ${workdir}/xraystart
echo "#!/bin/bash" > ${workdir}/xrayrestart
echo "if [ -e \"${workdir}/statusfilter\" ]; then" >> ${workdir}/xrayrestart
if [[ "$ipaddr" != "" ]]; then
echo "killall xray > /dev/null 2>&1" >> ${workdir}/xrayrestart
echo "killall sni-filter > /dev/null 2>&1" >> ${workdir}/xrayrestart
fi
if [[ "$hy2ipaddr" != "" ]]; then
echo "killall hysteria > /dev/null 2>&1" >> ${workdir}/delxray
fi
echo "systemctl restart xray_service" >> ${workdir}/xrayrestart
echo "else" >> ${workdir}/xrayrestart
echo "systemctl restart xray_service" >> ${workdir}/xrayrestart
echo "fi" >> ${workdir}/xrayrestart
cat << EOF > ${workdir}/xrayhelp
echo -e "\e[32mxray快捷命令\e[0m"
echo "修改订阅uuid->          xray.chuuid"
echo "删除xray及脚本->        xray.delxray"
echo "停止xray->              xray.stop"
echo "启动xray->              xray.start"
echo "重启xray->              xray.restart"
echo "关闭sni-filter模式->    xray.csni"
echo "打开sni-filter模式->    xray.osni"
echo "一键解决bug->           xray.debug"
echo "帮助->                  xray.help"
EOF
chmod 655 ${workdir}/*sni
chmod 640 ${workdir}/*.json
chmod 755 ${workdir}/delxray
chmod 755 ${workdir}/chaguuid
chmod 755 ${workdir}/xray*
ln -s ${workdir}/chaguuid /usr/bin/xray.chuuid
ln -s ${workdir}/delxray /usr/bin/xray.delxray
ln -s ${workdir}/xraystop /usr/bin/xray.stop
ln -s ${workdir}/xraystart /usr/bin/xray.start
ln -s ${workdir}/xrayrestart /usr/bin/xray.restart
ln -s ${workdir}/closedsni /usr/bin/xray.csni
ln -s ${workdir}/opensni /usr/bin/xray.osni
ln -s ${workdir}/xraynobug /usr/bin/xray.debug
ln -s ${workdir}/xrayhelp /usr/bin/xray.help
systemctl enable xray_service

# ==================== 自动更新AT&T IPv6出口 ====================
echo "$att_ipv6" > ${workdir}/last_att_ipv6.txt

cat << 'AUTOUPDATE_SCRIPT' > ${workdir}/auto_update_ip.sh
#!/bin/bash

workdir="/var/xray"
last_ip_file="${workdir}/last_att_ipv6.txt"
config_sni="${workdir}/sni_config.json"
config_old="${workdir}/old_config.json"

current_ip=""
for ip in $(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | grep -v '^::1'); do
    if [[ "$ip" == 2600:* ]]; then
        current_ip="$ip"
        break
    fi
done

if [[ -z "$current_ip" ]]; then
    echo "未发现AT&T IPv6，跳过"
    exit 0
fi

last_ip=$(cat "$last_ip_file" 2>/dev/null)
if [[ "$current_ip" == "$last_ip" ]]; then
    exit 0
fi

echo "AT&T IPv6 已变化: $last_ip -> $current_ip"

sed -i "s/\"sendThrough\": \"$last_ip\"/\"sendThrough\": \"$current_ip\"/g" "$config_sni"
sed -i "s/\"sendThrough\": \"$last_ip\"/\"sendThrough\": \"$current_ip\"/g" "$config_old"

echo "$current_ip" > "$last_ip_file"
systemctl restart xray_service
echo "Xray已使用新IPv6出口重启"
AUTOUPDATE_SCRIPT

chmod +x ${workdir}/auto_update_ip.sh

(crontab -l 2>/dev/null; echo "* * * * * ${workdir}/auto_update_ip.sh") | crontab -

echo -e "\e[32m已添加自动更新IP的cron任务（每分钟检查）\e[0m"

echo "done!"
echo -e "\e[32m安装完成\e[0m"
echo -e "\e[32m你的订阅为\e[0m"
echo
echo

if [[ "$ipaddr" != "" ]]; then
echo -e "\e[32mvless://$id_s@$realip:$portx?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$domain_s&fp=$fingerprint&pbk=$public_old&sid=$shortIds&type=tcp&headerType=none&host=$domain_s&flow=$old_flow#xray_REALITY\e[0m"
fi

echo ""

if [[ "$hy2ipaddr" != "" ]]; then
echo -e "\e[32mhysteria2://$id_s@$realip:$hy2portx?sni=$domain_hy2&insecure=1#hysteria2\e[0m"
fi

echo 
echo 
${workdir}/xrayhelp
systemctl start xray_service
