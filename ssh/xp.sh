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
data=( `cat /var/lib/crot/data-user-l2tp | grep '^###' | cut -d ' ' -f 2`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### $user" "/var/lib/crot/data-user-l2tp" | cut -d ' ' -f 3)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" = "0" ]]; then
sed -i "/^### $user $exp/d" "/var/lib/crot/data-user-l2tp"
sed -i '/^"'"$user"'" l2tpd/d' /etc/ppp/chap-secrets
sed -i '/^'"$user"':\$1\$/d' /etc/ipsec.d/passwd
chmod 600 /etc/ppp/chap-secrets* /etc/ipsec.d/passwd*
fi
done
data=( `cat /var/lib/crot/data-user-pptp | grep '^###' | cut -d ' ' -f 2`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### $user" "/var/lib/crot/data-user-pptp" | cut -d ' ' -f 3)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" = "0" ]]; then
sed -i "/^### $user $exp/d" "/var/lib/crot/data-user-pptp"
sed -i '/^"'"$user"'" pptpd/d' /etc/ppp/chap-secrets
chmod 600 /etc/ppp/chap-secrets*
fi
done
data=( `cat /etc/shadowsocks-libev/akun.conf | grep '^###' | cut -d ' ' -f 2`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### $user" "/etc/shadowsocks-libev/akun.conf" | cut -d ' ' -f 3)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" = "0" ]]; then
sed -i "/^### $user $exp/,/^port_http/d" "/etc/shadowsocks-libev/akun.conf"
systemctl disable shadowsocks-libev-server@$user-tls.service
systemctl disable shadowsocks-libev-server@$user-http.service
systemctl stop shadowsocks-libev-server@$user-tls.service
systemctl stop shadowsocks-libev-server@$user-http.service
rm -f "/etc/shadowsocks-libev/$user-tls.json"
rm -f "/etc/shadowsocks-libev/$user-http.json"
fi
done
data=( `cat /usr/local/shadowsocksr/akun.conf | grep '^###' | cut -d ' ' -f 2`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### $user" "/usr/local/shadowsocksr/akun.conf" | cut -d ' ' -f 3)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" = "0" ]]; then
sed -i "/^### $user $exp/d" "/usr/local/shadowsocksr/akun.conf"
cd /usr/local/shadowsocksr
match_del=$(python mujson_mgr.py -d -u "${user}"|grep -w "delete user")
cd
fi
done
/etc/init.d/ssrmu restart
data=( `cat /var/lib/crot/data-user-sstp | grep '^###' | cut -d ' ' -f 2`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### $user" "/var/lib/crot/data-user-sstp" | cut -d ' ' -f 3)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" = "0" ]]; then
sed -i "/^### $user $exp/d" "/var/lib/crot/data-user-sstp"
sed -i '/^'"$user"'/d' /home/sstp/sstp_account
fi
done

# AUTO REMOVE WIREGUARD
data=( `cat /etc/wireguard/wg0.conf | grep '^### Client' | cut -d ' ' -f 3`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### Client $user" "/etc/wireguard/wg0.conf" | cut -d ' ' -f 4)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" = "0" ]]; then
sed -i "/^### Client $user $exp/,/^AllowedIPs/d" /etc/wireguard/wg0.conf
rm -f "/home/vps/public_html/$user.conf"
fi
done
systemctl restart wg-quick@wg0

#----- Auto Remove Vmess
XRAY_ACCOUNTS_REMOVED=0
TROJAN_GO_ACCOUNTS_REMOVED=0
data=( `cat /etc/xray/config.json | grep '^###' | cut -d ' ' -f 2 | sort | uniq`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### $user" "/etc/xray/config.json" | cut -d ' ' -f 3 | sort | uniq)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" -le "0" ]]; then
if command -v ssh-one-xray-accounts >/dev/null 2>&1 && [[ $(ssh-one-xray-accounts mode /etc/xray/config.json '#xray-vmess-tls') == empty ]]; then
	ssh-one-xray-accounts remove-user /etc/xray/config.json '#xray-vmess-tls' "$user" && ssh-one-xray-accounts remove-user /etc/xray/config.json '#xray-vmess-nontls' "$user" || continue
else
	sed -i "/^### $user $exp/,/^},{/d" /etc/xray/config.json
	sed -i "/^### $user $exp/,/^},{/d" /etc/xray/config.json
fi
rm -f /etc/xray/vmess-$user-tls.json /etc/xray/vmess-$user-nontls.json
XRAY_ACCOUNTS_REMOVED=1
fi
done
echo -e "$ORANGE Sucessfully XRAY VMESS WS Account Deleted !$NC"

#----- Auto Remove Vless
data=( `cat /etc/xray/config.json | grep '^####' | cut -d ' ' -f 2 | sort | uniq`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^#### $user" "/etc/xray/config.json" | cut -d ' ' -f 3 | sort | uniq)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" -le "0" ]]; then
if command -v ssh-one-xray-accounts >/dev/null 2>&1 && [[ $(ssh-one-xray-accounts mode /etc/xray/config.json '#xray-vless-tls') == empty ]]; then
	ssh-one-xray-accounts remove-user /etc/xray/config.json '#xray-vless-tls' "$user" && ssh-one-xray-accounts remove-user /etc/xray/config.json '#xray-vless-nontls' "$user" || continue
else
	sed -i "/^#### $user $exp/,/^},{/d" /etc/xray/config.json
	sed -i "/^#### $user $exp/,/^},{/d" /etc/xray/config.json
fi
XRAY_ACCOUNTS_REMOVED=1
fi
done
echo -e "$ORANGE Sucessfully XRAY VLESS WS Account Deleted !$NC"

#----- Auto Remove Trojan
data=( `cat /etc/xray/config.json | grep '^#&#' | cut -d ' ' -f 2 | sort | uniq`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^#&# $user" "/etc/xray/config.json" | cut -d ' ' -f 3 | sort | uniq)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" -le "0" ]]; then
if command -v ssh-one-xray-accounts >/dev/null 2>&1 && [[ $(ssh-one-xray-accounts mode /etc/xray/config.json '#xray-trojan') == empty ]]; then
	ssh-one-xray-accounts remove-user /etc/xray/config.json '#xray-trojan' "$user" || continue
else
	sed -i "/^#&# $user $exp/,/^},{/d" /etc/xray/config.json
	sed -i "/^#&# $user $exp/,/^},{/d" /etc/xray/config.json
fi
XRAY_ACCOUNTS_REMOVED=1
fi
done
echo -e "$ORANGE Sucessfully XRAY TROJAN WS Account Deleted !$NC"

#----- Auto Remove Trojan GO
data=( `cat /etc/trojan-go/akun.conf | grep '^###' | cut -d ' ' -f 2 | sort | uniq`);
now=`date +"%Y-%m-%d"`
for user in "${data[@]}"
do
exp=$(grep -w "^### $user" "/etc/trojan-go/akun.conf" | cut -d ' ' -f 3 | sort | uniq)
d1=$(date -d "$exp" +%s)
d2=$(date -d "$now" +%s)
exp2=$(( (d1 - d2) / 86400 ))
if [[ "$exp2" -le "0" ]]; then
trojan_config_tmp=$(mktemp /etc/trojan-go/.config.json.XXXXXX) || continue
if jq --arg user "$user" '.password |= map(select(. != $user))' /etc/trojan-go/config.json > "$trojan_config_tmp" && chmod --reference=/etc/trojan-go/config.json "$trojan_config_tmp" && mv -fT -- "$trojan_config_tmp" /etc/trojan-go/config.json; then
	sed -i "/^### $user $exp\$/d" /etc/trojan-go/akun.conf
	TROJAN_GO_ACCOUNTS_REMOVED=1
else
	rm -f -- "$trojan_config_tmp"
	echo "Could not remove expired Trojan-Go account $user from config." >&2
fi
fi
done
echo -e "$ORANGE Sucessfully XRAY TROJAN GO Account Deleted !$NC"
if [[ $XRAY_ACCOUNTS_REMOVED == 1 ]]; then systemctl restart xray.service || echo 'Xray could not be restarted after account cleanup.' >&2; fi
if [[ $TROJAN_GO_ACCOUNTS_REMOVED == 1 ]]; then systemctl restart trojan-go.service || echo 'Trojan-Go could not be restarted after account cleanup.' >&2; fi
