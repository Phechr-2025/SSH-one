#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077
fail() { printf 'WireGuard account delete: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
[[ -f /etc/wireguard/params && ! -L /etc/wireguard/params && -f /etc/wireguard/wg0.conf && ! -L /etc/wireguard/wg0.conf ]] || fail 'WireGuard config and parameters must be regular files.'
for tool in awk mktemp systemctl wg-quick; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done
# shellcheck source=/etc/wireguard/params
. /etc/wireguard/params
[[ ${SERVER_WG_NIC:-} =~ ^wg[0-9]+$ ]] || fail 'WireGuard interface name is invalid.'
mapfile -t CLIENTS < <(awk '$1=="###" && $2=="Client" {print $3 " " $4}' "/etc/wireguard/$SERVER_WG_NIC.conf")
(( ${#CLIENTS[@]} > 0 )) || fail 'there are no WireGuard clients.'
printf 'Select the WireGuard account to delete:\n'
for i in "${!CLIENTS[@]}"; do printf '%2d) %s\n' "$((i+1))" "${CLIENTS[$i]}"; done
read -r -p 'Account number: ' number || fail 'could not read account number.'
if [[ ! $number =~ ^[0-9]+$ ]] || (( number < 1 || number > ${#CLIENTS[@]} )); then
  fail 'invalid account number.'
fi
read -r user expiry <<< "${CLIENTS[$((number-1))]}"
[[ $user =~ ^[A-Za-z0-9_]{1,32}$ && $expiry =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail 'saved WireGuard account marker is malformed.'

config="/etc/wireguard/$SERVER_WG_NIC.conf"
backup=$(mktemp /etc/wireguard/.wg0.conf.pre-delete.XXXXXX) || fail 'could not stage a backup.'
cp -a -- "$config" "$backup" || fail 'could not back up the server config.'
tmp=$(mktemp /etc/wireguard/.wg0.conf.delete.XXXXXX) || { rm -f -- "$backup"; fail 'could not stage the server config.'; }
if ! awk -v marker="### Client $user $expiry" '
  $0==marker { if (skip) exit 2; skip=1; found=1; next }
  skip && /^AllowedIPs[[:space:]]*=/ { skip=0; next }
  skip { next }
  { print }
  END { if (!found || skip) exit 1 }
' "$config" > "$tmp"; then
  rm -f -- "$backup" "$tmp"
  fail 'could not find a complete client block; no changes were applied.'
fi
chmod --reference="$config" "$tmp"
mv -fT -- "$tmp" "$config" || { cp -a -- "$backup" "$config"; rm -f -- "$backup"; fail 'could not activate the server config.'; }
if ! wg-quick strip "$SERVER_WG_NIC" >/dev/null || ! systemctl restart "wg-quick@$SERVER_WG_NIC" || ! systemctl is-active --quiet "wg-quick@$SERVER_WG_NIC"; then
  cp -a -- "$backup" "$config"
  systemctl restart "wg-quick@$SERVER_WG_NIC" >/dev/null 2>&1 || true
  rm -f -- "$backup"
  fail 'WireGuard did not restart; the previous server config was restored.'
fi
rm -f -- "$backup"
for file in "/root/$SERVER_WG_NIC-client-$user.conf" "/home/vps/public_html/$user.conf"; do
  [[ ! -L $file && -f $file ]] && rm -f -- "$file"
done
printf 'Deleted WireGuard account %s (expired %s).\n' "$user" "$expiry"
