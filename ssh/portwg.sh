#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

fail() { printf 'WireGuard port: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
[[ -f /etc/wireguard/params && ! -L /etc/wireguard/params && -f /etc/wireguard/wg0.conf && ! -L /etc/wireguard/wg0.conf ]] || fail 'WireGuard config and parameters must be regular files.'
for tool in awk date install ip ss wg systemctl mktemp cp mv; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done
# shellcheck source=/etc/wireguard/params
. /etc/wireguard/params
if [[ ! ${SERVER_WG_NIC:-} =~ ^wg[0-9]+$ || ! ${SERVER_PORT:-} =~ ^[0-9]{1,5}$ ]] || (( 10#${SERVER_PORT:-0} < 1 || 10#${SERVER_PORT:-0} > 65535 )); then
  fail 'WireGuard parameters are invalid.'
fi

printf 'Current WireGuard UDP port: %s\n' "$SERVER_PORT"
read -r -p 'New WireGuard UDP port (1-65535): ' new_port || fail 'could not read the port.'
if [[ ! $new_port =~ ^[0-9]{1,5}$ ]] || (( 10#$new_port < 1 || 10#$new_port > 65535 )); then
  fail 'enter a whole number from 1 to 65535.'
fi
new_port=$((10#$new_port))
if (( new_port == 10#$SERVER_PORT )); then
  printf 'WireGuard already uses UDP %s.\n' "$new_port"
  exit 0
fi
if ss -H -lun | awk -v port=":$new_port" '$4 ~ (port "$" ) { found=1 } END { exit !found }'; then
  fail "UDP port $new_port is already in use."
fi

config="/etc/wireguard/$SERVER_WG_NIC.conf"
params=/etc/wireguard/params
[[ -f $config && ! -L $config && -f $params && ! -L $params ]] || fail 'WireGuard files must be regular files.'
backup_dir=/etc/ssh-one/backups/wireguard
install -d -m 0700 "$backup_dir"
stamp="$(date +%Y%m%d%H%M%S).$$"
config_backup="$backup_dir/${SERVER_WG_NIC}.conf.pre-port-change.$stamp"
params_backup="$backup_dir/params.pre-port-change.$stamp"
cp -a -- "$config" "$config_backup" || fail 'could not back up the WireGuard config.'
cp -a -- "$params" "$params_backup" || fail 'could not back up WireGuard parameters.'

config_tmp=$(mktemp "/etc/wireguard/.${SERVER_WG_NIC}.port.XXXXXX") || fail 'could not stage the WireGuard config.'
params_tmp=$(mktemp /etc/wireguard/.params.port.XXXXXX) || { rm -f -- "$config_tmp"; fail 'could not stage WireGuard parameters.'; }
if ! awk -v port="$new_port" '
  /^\[Interface\][[:space:]]*$/ { section="interface"; print; next }
  /^\[[^]]+\][[:space:]]*$/ { section="peer"; print; next }
  section=="interface" && /^[[:space:]]*ListenPort[[:space:]]*=/ {
    if (found++) exit 2
    print "ListenPort = " port
    next
  }
  { print }
  END { if (found!=1) exit 1 }
' "$config" > "$config_tmp"; then
  rm -f -- "$config_tmp" "$params_tmp"
  fail 'could not find exactly one ListenPort in the WireGuard interface config.'
fi
if ! awk -v port="$new_port" '
  /^SERVER_PORT=/ { if (found++) exit 2; print "SERVER_PORT=" port; next }
  { print }
  END { if (found!=1) exit 1 }
' "$params" > "$params_tmp"; then
  rm -f -- "$config_tmp" "$params_tmp"
  fail 'could not find exactly one SERVER_PORT parameter.'
fi
chmod --reference="$config" "$config_tmp"
chmod --reference="$params" "$params_tmp"
if ! mv -fT -- "$config_tmp" "$config"; then rm -f -- "$config_tmp" "$params_tmp"; fail 'could not activate the updated WireGuard config.'; fi
if ! mv -fT -- "$params_tmp" "$params"; then
  cp -a -- "$config_backup" "$config"
  rm -f -- "$params_tmp"
  fail 'could not activate the updated WireGuard parameters; the config was restored.'
fi

if [[ -x /usr/bin/ssh-one-game-network ]]; then
  if ! /usr/bin/ssh-one-game-network apply || ! systemctl is-active --quiet "wg-quick@$SERVER_WG_NIC" || [[ $(wg show "$SERVER_WG_NIC" listen-port) != "$new_port" ]]; then
    cp -a -- "$config_backup" "$config"
    cp -a -- "$params_backup" "$params"
    systemctl restart "wg-quick@$SERVER_WG_NIC" >/dev/null 2>&1 || true
    fail 'WireGuard did not apply the new port; the previous config and parameters were restored.'
  fi
else
  cp -a -- "$config_backup" "$config"
  cp -a -- "$params_backup" "$params"
  fail 'the SSH-one game-network manager is missing; no port change was retained.'
fi

if [[ -f /root/log-install.txt && ! -L /root/log-install.txt ]]; then
  log_tmp=$(mktemp /root/.log-install.wgport.XXXXXX) || log_tmp=''
  if [[ -z $log_tmp ]]; then
    printf 'Warning: could not stage /root/log-install.txt; the WireGuard port changed successfully.\n' >&2
  elif ! awk -v port="$new_port" '
    /^   - WireGuard Game Tunnel[[:space:]]*:/ { sub(/UDP [0-9]+/, "UDP " port); found=1 }
    /^   - Wire[Gg]uard[[:space:]]*:/ { sub(/:[[:space:]]*[0-9]+/, ": " port); found=1 }
    { print }
    END { if (!found) exit 1 }
  ' /root/log-install.txt > "$log_tmp"; then
    rm -f -- "$log_tmp"
    printf 'Warning: could not update /root/log-install.txt; the WireGuard port changed successfully.\n' >&2
  elif ! chmod --reference=/root/log-install.txt "$log_tmp" || ! mv -fT -- "$log_tmp" /root/log-install.txt; then
    rm -f -- "$log_tmp"
    printf 'Warning: could not update /root/log-install.txt; the WireGuard port changed successfully.\n' >&2
  fi
fi

printf 'WireGuard game tunnel now listens on UDP %s.\n' "$new_port"
printf 'Allow UDP %s in the VPS provider firewall/security group.\n' "$new_port"
