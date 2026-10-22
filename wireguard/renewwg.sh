#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077
fail() { printf 'WireGuard account renew: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
[[ -f /etc/wireguard/params && ! -L /etc/wireguard/params && -f /etc/wireguard/wg0.conf && ! -L /etc/wireguard/wg0.conf ]] || fail 'WireGuard config and parameters must be regular files.'
for tool in awk date mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done
# shellcheck source=/etc/wireguard/params
. /etc/wireguard/params
[[ ${SERVER_WG_NIC:-} =~ ^wg[0-9]+$ ]] || fail 'WireGuard interface name is invalid.'
mapfile -t CLIENTS < <(awk '$1=="###" && $2=="Client" {print $3 " " $4}' "/etc/wireguard/$SERVER_WG_NIC.conf")
(( ${#CLIENTS[@]} > 0 )) || fail 'there are no WireGuard clients.'
printf 'Select the WireGuard account to renew:\n'
for i in "${!CLIENTS[@]}"; do printf '%2d) %s\n' "$((i+1))" "${CLIENTS[$i]}"; done
read -r -p 'Account number: ' number || fail 'could not read account number.'
if [[ ! $number =~ ^[0-9]+$ ]] || (( number < 1 || number > ${#CLIENTS[@]} )); then
  fail 'invalid account number.'
fi
read -r user expiry <<< "${CLIENTS[$((number-1))]}"
[[ $user =~ ^[A-Za-z0-9_]{1,32}$ && $expiry =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail 'saved WireGuard account marker is malformed.'
read -r -p 'Add days (1-3650): ' days || fail 'could not read expiry.'
if [[ ! $days =~ ^[0-9]{1,4}$ ]] || (( 10#$days < 1 || 10#$days > 3650 )); then
  fail 'enter a whole number from 1 to 3650.'
fi
now=$(date +%F)
today_epoch=$(date -d "$now" +%s) || fail 'could not read current date.'
expiry_epoch=$(date -d "$expiry" +%s) || fail 'saved expiry date is invalid.'
base_epoch=$expiry_epoch
(( base_epoch < today_epoch )) && base_epoch=$today_epoch
new_expiry=$(date -d "@$((base_epoch + 10#$days * 86400))" +%F) || fail 'could not calculate new expiry.'
config="/etc/wireguard/$SERVER_WG_NIC.conf"
backup=$(mktemp /etc/wireguard/.wg0.conf.pre-renew.XXXXXX) || fail 'could not stage a backup.'
cp -a -- "$config" "$backup" || fail 'could not back up the server config.'
tmp=$(mktemp /etc/wireguard/.wg0.conf.renew.XXXXXX) || { rm -f -- "$backup"; fail 'could not stage the server config.'; }
if ! awk -v old="### Client $user $expiry" -v new="### Client $user $new_expiry" '
  $0==old { if (found) exit 2; print new; found=1; next }
  { print }
  END { if (!found) exit 1 }
' "$config" > "$tmp"; then
  rm -f -- "$backup" "$tmp"
  fail 'could not find the selected client; no changes were applied.'
fi
chmod --reference="$config" "$tmp"
mv -fT -- "$tmp" "$config" || { cp -a -- "$backup" "$config"; rm -f -- "$backup"; fail 'could not activate the renewed expiry.'; }
rm -f -- "$backup"
command -v ssh-one-account-tools >/dev/null 2>&1 && ssh-one-account-tools mark-renewed wireguard "$user" || true
printf 'Renewed WireGuard account %s through %s.\n' "$user" "$new_expiry"
