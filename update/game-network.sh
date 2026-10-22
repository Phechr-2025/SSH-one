#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() { printf 'Game network setup: %s\n' "$*" >&2; exit 1; }
note() { printf 'Game network setup: %s\n' "$*"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
for tool in systemctl ss iptables awk sed grep mktemp install sleep sysctl readlink cp chown tr date python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."
done

badvpn_unit=/etc/systemd/system/ssh-one-badvpn-udpgw.service
badvpn_signature='ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:7100 --listen-addr 127.0.0.1:7200 --listen-addr 127.0.0.1:7300 --max-clients 500 --max-connections-for-client 100'
legacy_rc_local_badvpn=0

remove_legacy_rc_local() {
  local rc=/etc/rc.local tmp backup
  [[ -f $rc && ! -L $rc ]] || return 0
  if ! grep -Eq 'screen -dmS badvpn badvpn-udpgw --listen-addr 127\.0\.0\.1:(7100|7200|7300) --max-clients (500|1000)' "$rc"; then
    return 0
  fi
  legacy_rc_local_badvpn=1
  install -d -m 0700 /etc/ssh-one/backups || fail 'could not create the backup directory for /etc/rc.local.'
  backup=/etc/ssh-one/backups/rc.local.pre-game-network
  [[ -e $backup ]] || cp -a -- "$rc" "$backup" || fail 'could not back up /etc/rc.local.'
  tmp=$(mktemp /etc/rc.local.ssh-one.XXXXXX) || fail 'could not stage /etc/rc.local.'
  if ! awk '!/screen -dmS badvpn badvpn-udpgw --listen-addr 127\.0\.0\.1:(7100|7200|7300) --max-clients (500|1000)/' "$rc" > "$tmp"; then
    rm -f -- "$tmp"
    fail 'could not remove old BadVPN startup lines from /etc/rc.local.'
  fi
  chmod --reference="$rc" "$tmp"
  chown --reference="$rc" "$tmp" 2>/dev/null || true
  mv -fT -- "$tmp" "$rc" || fail 'could not activate the cleaned /etc/rc.local.'
  note 'removed duplicate legacy BadVPN startup lines; the original /etc/rc.local is backed up.'
}

stop_legacy_badvpn() {
  local proc pid cmd exe
  for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    [[ $pid != "$$" && -r $proc/cmdline ]] || continue
    cmd=$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)
    [[ $cmd == *badvpn-udpgw* && ( $cmd == *127.0.0.1:7100* || $cmd == *127.0.0.1:7200* || $cmd == *127.0.0.1:7300* ) ]] || continue
    exe=$(readlink "$proc/exe" 2>/dev/null || true)
    [[ ${exe##*/} == badvpn-udpgw ]] || continue
    kill "$pid" 2>/dev/null || true
  done
  for _ in 1 2 3 4 5; do
    if ! ss -H -ltn | grep -Eq '127\.0\.0\.1:(7100|7200|7300)([[:space:]]|$)'; then return 0; fi
    sleep 1
  done
}

install_badvpn_service() {
  local tmp
  [[ -x /usr/bin/badvpn-udpgw ]] || fail 'BadVPN UDPGW binary is missing at /usr/bin/badvpn-udpgw.'
  if [[ -e $badvpn_unit || -L $badvpn_unit ]]; then
    [[ -f $badvpn_unit && ! -L $badvpn_unit ]] || fail "refusing to replace an unexpected path: $badvpn_unit"
    if ! grep -Fqx "$badvpn_signature" "$badvpn_unit"; then
      grep -Fq 'Description=SSH-one BadVPN UDP gateway' "$badvpn_unit" || fail 'an unrelated BadVPN systemd unit already exists; it was left unchanged.'
    fi
  fi
  if systemctl is-active --quiet ssh-one-badvpn-udpgw.service; then
    systemctl stop ssh-one-badvpn-udpgw.service || fail 'could not stop the existing SSH-one BadVPN service.'
  fi
  remove_legacy_rc_local
  if (( legacy_rc_local_badvpn )); then stop_legacy_badvpn; fi
  tmp=$(mktemp /etc/systemd/system/.ssh-one-badvpn-udpgw.XXXXXX) || fail 'could not stage the BadVPN systemd unit.'
  cat > "$tmp" <<UNIT
[Unit]
Description=SSH-one BadVPN UDP gateway for compatible SSH clients
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
$badvpn_signature
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$tmp"
  mv -fT -- "$tmp" "$badvpn_unit" || fail 'could not install the BadVPN systemd unit.'
  systemctl daemon-reload || fail 'systemd could not reload the BadVPN service unit.'
  systemctl enable --now ssh-one-badvpn-udpgw.service >/dev/null || fail 'could not enable or start the BadVPN UDP gateway.'
  systemctl is-active --quiet ssh-one-badvpn-udpgw.service || fail 'the BadVPN UDP gateway is not active.'
  for port in 7100 7200 7300; do
    ss -H -ltn | awk -v p="$port" '$4 == "127.0.0.1:" p { found=1 } END { exit !found }' || {
      systemctl --no-pager --full status ssh-one-badvpn-udpgw.service >&2 || true
      fail "BadVPN is not listening on 127.0.0.1:$port."
    }
  done
  note 'BadVPN is active under systemd on loopback TCP 7100, 7200, and 7300.'
}

read_param() {
  local key=$1
  awk -v key="$key" 'index($0, key "=")==1 { if (found++) exit 2; sub(/^[^=]*=/, ""); gsub(/\r/, ""); print } END { if (found!=1) exit 1 }' /etc/wireguard/params 2>/dev/null
}

ensure_forwarding_file() {
  local path=/etc/sysctl.d/99-ssh-one-wireguard.conf tmp
  if [[ -L $path ]]; then fail "refusing to follow a symbolic link: $path"; fi
  if [[ -e $path ]]; then
    [[ -f $path ]] || fail "WireGuard forwarding settings are not a regular file: $path"
    [[ $(<"$path") == $'# SSH-one WireGuard IPv4 game/network forwarding\nnet.ipv4.ip_forward=1' ]] || fail "$path exists with different settings; it was left unchanged."
  else
    tmp=$(mktemp /etc/sysctl.d/.ssh-one-wireguard.XXXXXX) || fail 'could not stage persistent IPv4 forwarding settings.'
    cat > "$tmp" <<'SYSCTL'
# SSH-one WireGuard IPv4 game/network forwarding
net.ipv4.ip_forward=1
SYSCTL
    chmod 0644 "$tmp"
    mv -fT -- "$tmp" "$path" || fail 'could not install persistent IPv4 forwarding settings.'
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null || fail 'could not enable IPv4 packet forwarding.'
}

configure_wireguard() {
  local config=/etc/wireguard/wg0.conf nic port tmp backup was_active
  if [[ ! -e $config && ! -e /etc/wireguard/params ]]; then
    note 'WireGuard is not installed; skipped its game-traffic routing setup.'
    return 0
  fi
  [[ -f $config && ! -L $config && -f $params && ! -L $params ]] || fail 'WireGuard config or parameters are not regular files.'
  nic=$(read_param SERVER_PUB_NIC) || fail 'could not read the WireGuard public interface parameter.'
  port=$(read_param SERVER_PORT) || fail 'could not read the WireGuard UDP port parameter.'
  [[ $nic =~ ^[A-Za-z0-9_.:-]{1,64}$ ]] || fail 'WireGuard has an invalid public network interface in /etc/wireguard/params.'
  if [[ ! $port =~ ^[0-9]{1,5}$ ]]; then fail 'WireGuard has an invalid UDP listening port.'; fi
  if (( 10#$port < 1 || 10#$port > 65535 )); then fail 'WireGuard has an invalid UDP listening port.'; fi
  command -v wg-quick >/dev/null 2>&1 || fail 'wg-quick is required to configure WireGuard routing.'
  command -v python3 >/dev/null 2>&1 || fail 'python3 is required to update WireGuard routing safely.'
  ensure_forwarding_file
  install -d -m 0700 /etc/ssh-one/backups/wireguard
  backup="/etc/ssh-one/backups/wireguard/wg0.conf.pre-game-network.$(date +%Y%m%d%H%M%S).$$"
  cp -a -- "$config" "$backup" || fail 'could not back up /etc/wireguard/wg0.conf.'
  tmp=$(mktemp /etc/wireguard/.wg0.conf.game-network.XXXXXX) || fail 'could not stage the WireGuard server config.'
  if ! python3 - "$config" "$tmp" "$nic" "$port" <<'PY'
import re, sys
source, target, nic, port = sys.argv[1:]
if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", nic) or not re.fullmatch(r"[0-9]{1,5}", port):
    raise SystemExit("invalid interface or port")
port = str(int(port))
up = (
    f"iptables -C INPUT -i {nic} -p udp --dport {port} -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i {nic} -p udp --dport {port} -m comment --comment SSH-one-WireGuard -j ACCEPT; "
    f"iptables -C FORWARD -s 10.66.66.0/24 -i wg0 -o {nic} -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s 10.66.66.0/24 -i wg0 -o {nic} -m comment --comment SSH-one-WireGuard -j ACCEPT; "
    f"iptables -C FORWARD -d 10.66.66.0/24 -i {nic} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d 10.66.66.0/24 -i {nic} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT; "
    f"iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o {nic} -m comment --comment SSH-one-WireGuard -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s 10.66.66.0/24 -o {nic} -m comment --comment SSH-one-WireGuard -j MASQUERADE"
)
down = (
    f"while iptables -C INPUT -i {nic} -p udp --dport {port} -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null; do iptables -D INPUT -i {nic} -p udp --dport {port} -m comment --comment SSH-one-WireGuard -j ACCEPT; done; "
    f"while iptables -C FORWARD -s 10.66.66.0/24 -i wg0 -o {nic} -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null; do iptables -D FORWARD -s 10.66.66.0/24 -i wg0 -o {nic} -m comment --comment SSH-one-WireGuard -j ACCEPT; done; "
    f"while iptables -C FORWARD -d 10.66.66.0/24 -i {nic} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null; do iptables -D FORWARD -d 10.66.66.0/24 -i {nic} -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT; done; "
    f"while iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o {nic} -m comment --comment SSH-one-WireGuard -j MASQUERADE 2>/dev/null; do iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o {nic} -m comment --comment SSH-one-WireGuard -j MASQUERADE; done"
)
hooks = {"PostUp": up, "PostDown": down}
with open(source, encoding="utf-8") as stream:
    lines = stream.read().replace("\r\n", "\n").replace("\r", "\n").splitlines()
out=[]
section=None
seen={"PostUp": False, "PostDown": False}
interface_found=False

def finish_interface():
    for key, value in hooks.items():
        if not seen[key]:
            out.append(f"{key} = {value}")
            seen[key]=True

for line in lines:
    match = re.match(r"^\s*\[([^]]+)\]\s*(?:#.*)?$", line)
    if match:
        if section and section.lower()=="interface": finish_interface()
        section=match.group(1).strip()
        if section.lower()=="interface": interface_found=True
        out.append(line)
        continue
    if section and section.lower()=="interface":
        key_match=re.match(r"^\s*(PostUp|PostDown)\s*=\s*(.*?)\s*$", line, re.I)
        if key_match:
            key=key_match.group(1).title()
            value=key_match.group(2)
            if value == hooks[key]:
                if not seen[key]: out.append(f"{key} = {hooks[key]}")
                seen[key]=True
                continue
            legacy_up=(key=="PostUp" and (("iptables -A FORWARD -i wg0 -j ACCEPT" in value and "POSTROUTING" in value) or ("SSH-one-WireGuard" in value and "iptables -C INPUT" in value)))
            legacy_down=(key=="PostDown" and (("iptables -D FORWARD -i wg0 -j ACCEPT" in value and "POSTROUTING" in value) or ("SSH-one-WireGuard" in value and "iptables -C INPUT" in value)))
            if legacy_up or legacy_down:
                continue
    out.append(line)
if section and section.lower()=="interface": finish_interface()
if not interface_found:
    raise SystemExit("WireGuard config has no [Interface] section")
with open(target, "w", encoding="utf-8", newline="\n") as stream:
    stream.write("\n".join(out)+"\n")
PY
  then
    rm -f -- "$tmp"
    fail 'could not prepare the WireGuard routing config.'
  fi
  chmod --reference="$config" "$tmp"
  chown --reference="$config" "$tmp" 2>/dev/null || true
  if ! mv -fT -- "$tmp" "$config"; then rm -f -- "$tmp"; fail 'could not activate WireGuard routing config.'; fi
  if ! wg-quick strip wg0 >/dev/null; then
    cp -a -- "$backup" "$config"
    fail 'WireGuard config validation failed; the previous config was restored.'
  fi
  was_active=0
  systemctl is-active --quiet wg-quick@wg0 && was_active=1 || true
  if ! systemctl enable wg-quick@wg0 >/dev/null || ! systemctl restart wg-quick@wg0 || ! systemctl is-active --quiet wg-quick@wg0; then
    cp -a -- "$backup" "$config"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if (( was_active )); then systemctl restart wg-quick@wg0 >/dev/null 2>&1 || true; else systemctl stop wg-quick@wg0 >/dev/null 2>&1 || true; fi
    fail 'WireGuard could not start with the game-traffic routing rules; previous config restored.'
  fi
  note 'WireGuard IPv4 forwarding, stateful return traffic, NAT, and UDP listener firewall rules are active.'
  note "WireGuard server config backup: $backup"
}

migrate_public_profiles() {
  local server_key profile name secure_tmp
  [[ -r /etc/wireguard/params && -d /home/vps/public_html ]] || return 0
  server_key=$(read_param SERVER_PUB_KEY) || return 0
  [[ $server_key =~ ^[A-Za-z0-9+/=]{40,50}$ ]] || return 0
  shopt -s nullglob
  for profile in /home/vps/public_html/*.conf; do
    [[ -f $profile && ! -L $profile ]] || continue
    name=${profile##*/}; name=${name%.conf}
    [[ $name =~ ^[A-Za-z0-9_]+$ ]] || continue
    if ! grep -Fxq '[Interface]' "$profile" || ! grep -Fxq '[Peer]' "$profile"; then continue; fi
    grep -Eq '^PrivateKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/=]{40,50}$' "$profile" || continue
    grep -Fxq "PublicKey = $server_key" "$profile" || continue
    secure_tmp=$(mktemp "/root/.wg0-client-${name}.XXXXXX") || fail "could not stage the secure profile for $name."
    if ! awk '
      /^\[Interface\]$/ { section="interface"; print; if (!mtu) { print "MTU = 1380"; mtu=1 }; next }
      /^\[Peer\]$/ { section="peer"; print; next }
      /^MTU[[:space:]]*=/ && section=="interface" { if (!mtu) print "MTU = 1380"; mtu=1; next }
      /^PersistentKeepalive[[:space:]]*=/ && section=="peer" { if (!keepalive) print "PersistentKeepalive = 25"; keepalive=1; next }
      /^AllowedIPs[[:space:]]*=/ && section=="peer" { print "AllowedIPs = 0.0.0.0/0"; next }
      { print }
      END { if (!keepalive) print "PersistentKeepalive = 25" }
    ' "$profile" > "$secure_tmp"; then
      rm -f -- "$secure_tmp"
      fail "could not secure the profile for $name."
    fi
    chmod 0600 "$secure_tmp"
    if [[ -e /root/wg0-client-${name}.conf || -L /root/wg0-client-${name}.conf ]]; then
      rm -f -- "$secure_tmp"
      note "kept the public profile for $name because a root-only profile already exists; remove it manually after checking the root copy."
      continue
    fi
    mv -fT -- "$secure_tmp" "/root/wg0-client-${name}.conf" || fail "could not install the root-only profile for $name."
    rm -f -- "$profile" || fail "the secure profile for $name was saved, but its public copy could not be removed."
    note "moved WireGuard profile $name to /root/wg0-client-${name}.conf (mode 0600) and removed its public HTTP copy."
  done
  shopt -u nullglob
}

case ${1:-apply} in
  apply)
    install_badvpn_service
    configure_wireguard
    migrate_public_profiles
    ;;
  restart)
    systemctl restart ssh-one-badvpn-udpgw.service || fail 'could not restart BadVPN UDPGW.'
    ;;
  status)
    systemctl --no-pager --full status ssh-one-badvpn-udpgw.service || true
    for port in 7100 7200 7300; do
      if ss -H -ltn | awk -v p="$port" '$4 == "127.0.0.1:" p { found=1 } END { exit !found }'; then note "BadVPN loopback TCP $port: listening"; else note "BadVPN loopback TCP $port: not listening"; fi
    done
    if [[ -r /etc/wireguard/wg0.conf ]]; then
      systemctl --no-pager --full status wg-quick@wg0 || true
      sysctl net.ipv4.ip_forward || true
      iptables -t nat -S POSTROUTING | grep -F '10.66.66.0/24' || true
    else note 'WireGuard is not configured.'; fi
    ;;
  *) fail 'usage: ssh-one-game-network [apply|restart|status].' ;;
esac
