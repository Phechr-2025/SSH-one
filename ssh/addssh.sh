#!/bin/bash

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi

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

domain=$(cat /etc/xray/domain)
clear
read -p "Username : " Login
read -p "Password : " Pass
read -p "Expired (Days): " masaaktif

IP=$(wget -qO- ipinfo.io/ip);
IP=$(curl -s ipinfo.io/ip )
IP=$(curl -sS ipv4.icanhazip.com)
IP=$(curl -sS ifconfig.me )
ws="$(cat ~/log-install.txt | grep -w "Websocket TLS" | cut -d: -f2|sed 's/ //g')"
ws2="$(cat ~/log-install.txt | grep -w "Websocket None TLS" | cut -d: -f2|sed 's/ //g')"

ssl="$(cat ~/log-install.txt | grep -w "Stunnel5" | cut -d: -f2)"
sqd="$(cat ~/log-install.txt | grep -w "Squid" | cut -d: -f2)"
ovpn="$(netstat -nlpt | grep -i openvpn | grep -i 0.0.0.0 | awk '{print $4}' | cut -d: -f2)"
ovpn2="$(netstat -nlpu | grep -i openvpn | grep -i 0.0.0.0 | awk '{print $4}' | cut -d: -f2)"
clear
# SlowDNS is not installed by SSH-one. Restart optional services only when
# their unit exists and is already active; account creation must not emit
# failures for services this installer intentionally skipped.
restart_active_service() {
	local unit=$1
	if systemctl list-unit-files --type=service --no-legend "$unit.service" 2>/dev/null | grep -q "^${unit}\.service" &&
	   systemctl is-active --quiet "$unit.service"; then
		systemctl restart "$unit.service" >/dev/null 2>&1 || echo "Warning: could not restart $unit.service." >&2
	fi
}
for optional_service in ws-tls ws-nontls ssh-ohp dropbear-ohp openvpn-ohp; do
	restart_active_service "$optional_service"
done
if ! getent group ssh-one-ssh >/dev/null 2>&1; then groupadd --system ssh-one-ssh || { echo "Could not create the SSH account group." >&2; exit 1; }; fi
useradd -e "$(date -d "$masaaktif days" +"%Y-%m-%d")" -s /bin/false -M -G ssh-one-ssh "$Login" || { echo "Could not create the SSH account." >&2; exit 1; }
expi="$(chage -l $Login | grep "Account expires" | awk -F": " '{print $2}')"
echo -e "$Pass\n$Pass\n"|passwd $Login &> /dev/null
hariini=`date -d "0 days" +"%Y-%m-%d"`
expi=`date -d "$masaaktif days" +"%Y-%m-%d"`

cat > /home/vps/public_html/ssh-$Login.txt <<-END
====================================================================
             P R O J E C T  O F  N E V E R M O R E S S H
                       [Freedom Internet]
====================================================================
            ${SSH_ONE_REPO_URL}
====================================================================
              Format SSH OVPN Account - hoppV2
====================================================================

═══════════════════════════════════════════════════════
Premium Server SSH Websocket
==============================
Username: $Login
Password: $Pass
Created: $hariini
Expired: $expi
===========HOST-SSH===========
IP/Host: $IP
Domain SSH: $domain
=========Service-Port=========
OpenSSH: 22
Dropbear: 443, 109, 143
SSL/TLS: 443
SSH Websocket SSL/TLS: 443
SSH Websocket HTTP: 8880
BadVPN UDPGW: 7100,7200,7300
Proxy Squid: 3128, 8000 [OFF]
OHP SSH: 8181
OHP Dropbear: 8282
OHP OpenVPN: 8383
OVPN Websocket: 2086
OVPN Port TCP: $ovpn
OVPN Port UDP: $ovpn2
OVPN Port SSL: 990
==============================
Payload Websocket SSL/TLS
==============================
GET wss://bug.com/ HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]
==============================
Payload Websocket HTTP
==============================
GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]
==============================
Script Mod

END

echo -e ""
echo -e "Premium Server SSH Websocket"
echo -e "=============================="
echo -e "Username: $Login"
echo -e "Password: $Pass"
echo -e "Created: $hariini"
echo -e "Expired: $expi"
echo -e "===========HOST-SSH==========="
echo -e "IP/Host: $IP"
echo -e "Domain SSH: $domain"
echo -e "=========Service-Port========="
echo -e "OpenSSH: 22"
echo -e "Dropbear: 443, 109, 143"
echo -e "SSL/TLS: 443"
echo -e "SSH Websocket SSL/TLS: 443"
echo -e "SSH Websocket HTTP: 8880"
echo -e "BadVPN UDPGW: 7100,7200,7300"
echo -e "Proxy Squid: 3128, 8000 [OFF]"
echo -e "OHP SSH: 8181"
echo -e "OHP Dropbear: 8282"
echo -e "OHP OpenVPN: 8383"
echo -e "OVPN Websocket: 2086"
echo -e "OVPN Port TCP: $ovpn"
echo -e "OVPN Port UDP: $ovpn2"
echo -e "OVPN Port SSL: 990"
echo -e "OVPN TCP: http://$IP:89/tcp.ovpn"
echo -e "OVPN UDP: http://$IP:89/udp.ovpn"
echo -e "OVPN SSL: http://$IP:89/ssl.ovpn"
echo -e "SSH Config : http://${domain}:81/ssh-$Login.txt"
echo -e "=============================="
echo -e "Payload Websocket SSL/TLS"
echo -e "=============================="
echo -e "GET wss://bug.com/ HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]"
echo -e "=============================="
echo -e "Payload Websocket HTTP"
echo -e "=============================="
echo -e "GET / HTTP/1.1[crlf]Host: [host][crlf]Upgrade: websocket[crlf][crlf]"
echo -e "=============================="
echo -e "Script Mod"
command -v ssh-one-account-tools >/dev/null 2>&1 && ssh-one-account-tools mark-created ssh || true
