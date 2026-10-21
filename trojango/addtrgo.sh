#!/bin/bash
# ==========================================
# Color
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHT='\033[0;37m'
# ==========================================
# Getting
MYIP=$(wget -qO- ipinfo.io/ip);
echo "Checking VPS"
IZIN=$( curl ipinfo.io/ip | grep $MYIP )
if [ $MYIP = $MYIP ]; then
echo -e "${NC}${GREEN}Permission Accepted...${NC}"
else
echo -e "${NC}${RED}Permission Denied!${NC}";
echo -e "${NC}${LIGHT}Fuck You!!"
exit 0
fi
clear
source /var/lib/crot/ipvps.conf
if [[ "$IP" = "" ]]; then
domain=$(cat /etc/xray/domain)
else
domain=$IP
fi
trgo="$(cat ~/log-install.txt | grep -w "TrojanGo" | cut -d: -f2|sed 's/ //g')"
until [[ $user =~ ^[a-zA-Z0-9_]+$ && ${user_EXISTS} == '0' ]]; do
		read -rp "Password : " -e user
		user_EXISTS=$(grep -w $user /etc/trojan-go/akun.conf | wc -l)

		if [[ ${user_EXISTS} == '1' ]]; then
			echo ""
			echo -e "Username ${RED}${user}${NC} Already On VPS Please Choose Another"
			exit 1
		fi
	done
read -p "Expired (Days) : " masaaktif
if ! jq -e '.password | type == "array"' /etc/trojan-go/config.json >/dev/null; then
	echo "Trojan-Go password list is missing or invalid." >&2
	exit 1
fi
trojan_config_tmp=$(mktemp /etc/trojan-go/.config.json.XXXXXX) || { echo "Could not stage the Trojan-Go config." >&2; exit 1; }
if ! jq --arg user "$user" '.password += [$user]' /etc/trojan-go/config.json > "$trojan_config_tmp"; then
	rm -f -- "$trojan_config_tmp"
	echo "Could not update the Trojan-Go password list." >&2
	exit 1
fi
chmod --reference=/etc/trojan-go/config.json "$trojan_config_tmp"
mv -fT -- "$trojan_config_tmp" /etc/trojan-go/config.json || { rm -f -- "$trojan_config_tmp"; echo "Could not activate the Trojan-Go config." >&2; exit 1; }
exp=`date -d "$masaaktif days" +"%Y-%m-%d"`
hariini=`date -d "0 days" +"%Y-%m-%d"`
echo -e "### $user $exp" >> /etc/trojan-go/akun.conf
systemctl restart trojan-go.service
link="trojan-go://${user}@${domain}:${trgo}/?sni=${domain}&type=ws&host=${domain}&path=/trojango&encryption=none#$user"
clear
echo -e ""
echo -e "=======-TROJAN-GO-======="
echo -e "Remarks    : ${user}"
echo -e "IP/Host    : ${MYIP}"
echo -e "Address    : ${domain}"
echo -e "Port       : ${trgo}"
echo -e "Key        : ${user}"
echo -e "Encryption : none"
echo -e "Path       : /trojango"
echo -e "Created    : $hariini"
echo -e "Expired    : $exp"
echo -e "========================="
echo -e "Link TrGo  : ${link}"
echo -e "========================="
echo -e "Script Mod"
command -v ssh-one-account-tools >/dev/null 2>&1 && ssh-one-account-tools mark-created trojango || true
