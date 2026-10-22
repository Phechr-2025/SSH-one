#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

fail() { printf 'WireGuard expiry: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
[[ -f /etc/wireguard/params && ! -L /etc/wireguard/params && -f /etc/wireguard/wg0.conf && ! -L /etc/wireguard/wg0.conf ]] || exit 0
for tool in awk date mktemp cp chmod mv wg-quick systemctl install; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done
# shellcheck source=/etc/wireguard/params
. /etc/wireguard/params
[[ ${SERVER_WG_NIC:-} =~ ^wg[0-9]+$ ]] || fail 'WireGuard interface name is invalid.'
config="/etc/wireguard/$SERVER_WG_NIC.conf"
[[ -f $config && ! -L $config ]] || fail 'WireGuard config is not a regular file.'

today=$(date +%F)
today_epoch=$(date -d "$today" +%s) || fail 'could not read the current date.'
mapfile -t clients < <(awk '$1=="###" && $2=="Client" {print $3 "|" $4}' "$config")
expired=()
for entry in "${clients[@]}"; do
  user=${entry%%|*}
  expiry=${entry#*|}
  [[ $user =~ ^[A-Za-z0-9_]{1,32}$ && $expiry =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || {
    printf 'WireGuard expiry: ignored malformed client marker: %s\n' "$entry" >&2
    continue
  }
  expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || {
    printf 'WireGuard expiry: ignored invalid expiry date for %s.\n' "$user" >&2
    continue
  }
  [[ $(date -d "@$expiry_epoch" +%F) == "$expiry" ]] || continue
  (( expiry_epoch <= today_epoch )) && expired+=("$user|$expiry")
done
(( ${#expired[@]} > 0 )) || exit 0

install -d -m 0700 /etc/ssh-one/backups/wireguard
backup="/etc/ssh-one/backups/wireguard/wg0.conf.pre-expiry.$(date +%Y%m%d%H%M%S).$$"
cp -a -- "$config" "$backup" || fail 'could not back up the WireGuard config.'
tmp=$(mktemp "/etc/wireguard/.${SERVER_WG_NIC}.expiry.XXXXXX") || fail 'could not stage the WireGuard config.'
cp -a -- "$config" "$tmp" || { rm -f -- "$tmp"; fail 'could not stage the WireGuard config.'; }
for entry in "${expired[@]}"; do
  user=${entry%%|*}
  expiry=${entry#*|}
  next=$(mktemp "/etc/wireguard/.${SERVER_WG_NIC}.expiry.XXXXXX") || { rm -f -- "$tmp"; fail 'could not stage the updated WireGuard config.'; }
  if ! awk -v marker="### Client $user $expiry" '
    $0==marker { if (found || skip) exit 2; skip=1; found=1; next }
    skip && /^[[:space:]]*AllowedIPs[[:space:]]*=/ { skip=0; next }
    skip { next }
    { print }
    END { if (!found || skip) exit 1 }
  ' "$tmp" > "$next"; then
    rm -f -- "$tmp" "$next"
    fail "could not find the complete client block for $user; no changes were applied."
  fi
  chmod --reference="$config" "$next"
  mv -fT -- "$next" "$tmp" || { rm -f -- "$tmp" "$next"; fail 'could not stage the updated WireGuard config.'; }
done
chmod --reference="$config" "$tmp"
mv -fT -- "$tmp" "$config" || { rm -f -- "$tmp"; fail 'could not activate the updated WireGuard config.'; }
if ! wg-quick strip "$SERVER_WG_NIC" >/dev/null || ! systemctl restart "wg-quick@$SERVER_WG_NIC" || ! systemctl is-active --quiet "wg-quick@$SERVER_WG_NIC"; then
  cp -a -- "$backup" "$config"
  systemctl restart "wg-quick@$SERVER_WG_NIC" >/dev/null 2>&1 || true
  fail 'WireGuard did not restart; the previous config was restored.'
fi

for entry in "${expired[@]}"; do
  user=${entry%%|*}
  for profile in "/root/$SERVER_WG_NIC-client-$user.conf" "/home/vps/public_html/$user.conf"; do
    [[ -f $profile && ! -L $profile ]] && rm -f -- "$profile"
  done
  printf 'Expired WireGuard account removed: %s\n' "$user"
done
printf 'WireGuard expiry backup: %s\n' "$backup"
