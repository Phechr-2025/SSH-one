#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

fail() { printf 'WireGuard account: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
for tool in wg wg-quick systemctl curl date grep awk mktemp python3; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done
[[ -f /etc/wireguard/params && ! -L /etc/wireguard/params && -f /etc/wireguard/wg0.conf && ! -L /etc/wireguard/wg0.conf ]] || fail 'WireGuard config and parameters must be regular files.'
# shellcheck source=/etc/wireguard/params
. /etc/wireguard/params
[[ ${SERVER_WG_NIC:-} =~ ^wg[0-9]+$ ]] || fail 'WireGuard interface name is invalid.'
if [[ ! ${SERVER_PORT:-} =~ ^[0-9]{1,5}$ ]] || (( 10#$SERVER_PORT < 1 || 10#$SERVER_PORT > 65535 )); then
  fail 'WireGuard port is invalid.'
fi
[[ ${SERVER_PUB_KEY:-} =~ ^[A-Za-z0-9+/=]{40,50}$ ]] || fail 'WireGuard server key is invalid.'

SSH_ONE_IP=''
SSH_ONE_DOMAIN=''
if [[ -f /var/lib/crot/ipvps.conf && ! -L /var/lib/crot/ipvps.conf && -r /var/lib/crot/ipvps.conf ]]; then
  # The legacy host setup stores plain shell assignments in this root-owned file.
  # shellcheck source=/var/lib/crot/ipvps.conf
  . /var/lib/crot/ipvps.conf
  SSH_ONE_IP=${IP:-}
  SSH_ONE_DOMAIN=${IP2:-}
fi
if [[ -z $SSH_ONE_IP ]]; then
  SSH_ONE_IP=$(curl -4fsS --connect-timeout 5 --max-time 10 https://api.ipify.org) || fail 'could not detect the VPS public IPv4 address.'
fi
python3 - "$SSH_ONE_IP" <<'PY' || fail 'the WireGuard endpoint is not a valid IPv4 address.'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except ipaddress.AddressValueError:
    raise SystemExit(1)
PY
[[ -n $SSH_ONE_DOMAIN ]] || SSH_ONE_DOMAIN=$(cat /etc/xray/domain 2>/dev/null || true)
SERVER_ENDPOINT="$SSH_ONE_IP:$SERVER_PORT"

printf 'WireGuard IPv4 game tunnel account\n'
while :; do
  read -r -p 'Username (letters, numbers, underscore): ' CLIENT_NAME || fail 'could not read username.'
  [[ $CLIENT_NAME =~ ^[A-Za-z0-9_]{1,32}$ ]] || { printf 'Use 1-32 letters, numbers, or underscores.\n' >&2; continue; }
  if grep -Eq "^### Client ${CLIENT_NAME}([[:space:]]|$)" "/etc/wireguard/$SERVER_WG_NIC.conf"; then
    printf 'That username already exists.\n' >&2
    continue
  fi
  if [[ -e /root/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf || -L /root/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf || -e /home/vps/public_html/${CLIENT_NAME}.conf || -L /home/vps/public_html/${CLIENT_NAME}.conf ]]; then
    printf 'A profile file with that name already exists; choose another username.\n' >&2
    continue
  fi
  break
done
while :; do
  read -r -p 'Expiry in days (1-3650): ' EXPIRY_DAYS || fail 'could not read expiry.'
  [[ $EXPIRY_DAYS =~ ^[0-9]{1,4}$ ]] && (( 10#$EXPIRY_DAYS >= 1 && 10#$EXPIRY_DAYS <= 3650 )) && break
  printf 'Enter a whole number from 1 to 3650.\n' >&2
done

CLIENT_ADDRESS=''
for octet in {2..254}; do
  if ! grep -Eq "^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*10\.66\.66\.${octet}/32([[:space:],]|$)" "/etc/wireguard/$SERVER_WG_NIC.conf"; then
    CLIENT_ADDRESS="10.66.66.$octet"
    break
  fi
done
[[ -n $CLIENT_ADDRESS ]] || fail 'the WireGuard client address pool is full.'

CREATED=$(date +%F)
EXPIRES=$(date -d "+$EXPIRY_DAYS days" +%F) || fail 'could not calculate the expiry date.'
CLIENT_PRIV_KEY=$(wg genkey) || fail 'could not generate client private key.'
CLIENT_PUB_KEY=$(printf '%s' "$CLIENT_PRIV_KEY" | wg pubkey) || fail 'could not generate client public key.'
CLIENT_PRE_SHARED_KEY=$(wg genpsk) || fail 'could not generate the preshared key.'
[[ $CLIENT_PRIV_KEY =~ ^[A-Za-z0-9+/=]{40,50}$ && $CLIENT_PUB_KEY =~ ^[A-Za-z0-9+/=]{40,50}$ && $CLIENT_PRE_SHARED_KEY =~ ^[A-Za-z0-9+/=]{40,50}$ ]] || fail 'WireGuard generated an invalid client key.'

CLIENT_CONFIG="/root/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
PROFILE_TMP=$(mktemp /root/.ssh-one-wg-client.XXXXXX) || fail 'could not stage client profile.'
cat > "$PROFILE_TMP" <<PROFILE
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = $CLIENT_ADDRESS/24
MTU = 1380
DNS = 1.1.1.1,1.0.0.1

[Peer]
PublicKey = $SERVER_PUB_KEY
PresharedKey = $CLIENT_PRE_SHARED_KEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
PROFILE
chmod 0600 "$PROFILE_TMP"
SERVER_BACKUP=$(mktemp /etc/wireguard/.wg0.conf.pre-client.XXXXXX) || { rm -f -- "$PROFILE_TMP"; fail 'could not stage a WireGuard backup.'; }
cp -a -- "/etc/wireguard/$SERVER_WG_NIC.conf" "$SERVER_BACKUP" || { rm -f -- "$PROFILE_TMP" "$SERVER_BACKUP"; fail 'could not back up the server config.'; }
if ! printf '\n### Client %s %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' "$CLIENT_NAME" "$EXPIRES" "$CLIENT_PUB_KEY" "$CLIENT_PRE_SHARED_KEY" "$CLIENT_ADDRESS" >> "/etc/wireguard/$SERVER_WG_NIC.conf"; then
  cp -a -- "$SERVER_BACKUP" "/etc/wireguard/$SERVER_WG_NIC.conf"
  rm -f -- "$PROFILE_TMP" "$SERVER_BACKUP"
  fail 'could not add the client to the server config.'
fi
if ! wg-quick strip "$SERVER_WG_NIC" >/dev/null || ! systemctl restart "wg-quick@$SERVER_WG_NIC" || ! systemctl is-active --quiet "wg-quick@$SERVER_WG_NIC"; then
  cp -a -- "$SERVER_BACKUP" "/etc/wireguard/$SERVER_WG_NIC.conf"
  systemctl restart "wg-quick@$SERVER_WG_NIC" >/dev/null 2>&1 || true
  rm -f -- "$PROFILE_TMP" "$SERVER_BACKUP"
  fail 'the client was not activated; the previous server config was restored.'
fi
if ! mv -fT -- "$PROFILE_TMP" "$CLIENT_CONFIG"; then
  cp -a -- "$SERVER_BACKUP" "/etc/wireguard/$SERVER_WG_NIC.conf"
  systemctl restart "wg-quick@$SERVER_WG_NIC" >/dev/null 2>&1 || true
  rm -f -- "$PROFILE_TMP" "$SERVER_BACKUP"
  fail 'could not save the secure client profile; the previous server config was restored.'
fi
chmod 0600 "$CLIENT_CONFIG"
rm -f -- "$SERVER_BACKUP"
command -v ssh-one-account-tools >/dev/null 2>&1 && ssh-one-account-tools mark-created wireguard || true

printf '\nWireGuard account created\n'
printf 'Username : %s\nCreated  : %s\nExpires  : %s\nEndpoint : %s (UDP)\n' "$CLIENT_NAME" "$CREATED" "$EXPIRES" "$SERVER_ENDPOINT"
printf 'Profile  : %s (root-only)\n' "$CLIENT_CONFIG"
printf 'Retrieve : scp root@%s:%s .\n' "$SSH_ONE_IP" "$CLIENT_CONFIG"
printf 'Import the profile into the WireGuard app, then enable the tunnel. Do not share it.\n'
printf 'The profile tunnels IPv4 only; IPv6 is not routed through this VPS.\n'
