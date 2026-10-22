#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

fail() { printf 'WireGuard install: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
[[ -r /etc/os-release ]] || fail 'cannot identify the operating system.'
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 20.04 && $(uname -m) == x86_64 ]] || fail 'this release supports Ubuntu 20.04 x86_64 only.'
command -v systemctl >/dev/null 2>&1 || fail 'systemd is required.'
for path in /etc/wireguard/params /etc/wireguard/wg0.conf; do
  [[ ! -e $path && ! -L $path ]] || fail "WireGuard data already exists at $path; refusing to overwrite it."
done

SERVER_PUB_NIC=$(ip -4 route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}') || fail 'could not determine the default-route interface.'
[[ $SERVER_PUB_NIC =~ ^[A-Za-z0-9_.:-]{1,64}$ ]] || fail 'could not determine a valid public interface.'

export DEBIAN_FRONTEND=noninteractive
apt-get update || fail 'could not refresh apt package lists.'
apt-get install -y wireguard iptables || fail 'could not install WireGuard or iptables.'
for tool in wg wg-quick iptables sysctl; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is missing after package installation."; done

install -d -m 0700 /etc/wireguard
SERVER_PRIV_KEY=$(wg genkey) || fail 'could not generate a server private key.'
SERVER_PUB_KEY=$(printf '%s' "$SERVER_PRIV_KEY" | wg pubkey) || fail 'could not generate a server public key.'
[[ $SERVER_PRIV_KEY =~ ^[A-Za-z0-9+/=]{40,50}$ && $SERVER_PUB_KEY =~ ^[A-Za-z0-9+/=]{40,50}$ ]] || fail 'WireGuard generated an invalid key.'
SERVER_WG_NIC=wg0
SERVER_WG_IPV4=10.66.66.1
SERVER_PORT=7070

params_tmp=$(mktemp /etc/wireguard/.params.XXXXXX) || fail 'could not stage WireGuard parameters.'
cat > "$params_tmp" <<PARAMS
SERVER_PUB_NIC=$SERVER_PUB_NIC
SERVER_WG_NIC=$SERVER_WG_NIC
SERVER_WG_IPV4=$SERVER_WG_IPV4
SERVER_PORT=$SERVER_PORT
SERVER_PRIV_KEY=$SERVER_PRIV_KEY
SERVER_PUB_KEY=$SERVER_PUB_KEY
PARAMS
chmod 0600 "$params_tmp"
mv -fT -- "$params_tmp" /etc/wireguard/params || fail 'could not install WireGuard parameters.'

sysctl_file=/etc/sysctl.d/99-ssh-one-wireguard.conf
if [[ -e $sysctl_file || -L $sysctl_file ]]; then
  [[ -f $sysctl_file && ! -L $sysctl_file ]] || fail "refusing to replace an unexpected path: $sysctl_file"
  grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1([[:space:]]*(#.*)?)?$' "$sysctl_file" || fail "existing forwarding config differs: $sysctl_file"
else
  printf '# SSH-one WireGuard IPv4 game/network forwarding\nnet.ipv4.ip_forward=1\n' > "$sysctl_file" || fail 'could not write IPv4 forwarding settings.'
  chmod 0644 "$sysctl_file"
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null || fail 'could not enable IPv4 forwarding.'

config_tmp=$(mktemp /etc/wireguard/.wg0.conf.XXXXXX) || fail 'could not stage the WireGuard server config.'
cat > "$config_tmp" <<WGCONF
[Interface]
Address = $SERVER_WG_IPV4/24
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIV_KEY
PostUp = iptables -C INPUT -i $SERVER_PUB_NIC -p udp --dport $SERVER_PORT -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i $SERVER_PUB_NIC -p udp --dport $SERVER_PORT -m comment --comment SSH-one-WireGuard -j ACCEPT; iptables -C FORWARD -s 10.66.66.0/24 -i wg0 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -s 10.66.66.0/24 -i wg0 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j ACCEPT; iptables -C FORWARD -d 10.66.66.0/24 -i $SERVER_PUB_NIC -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -d 10.66.66.0/24 -i $SERVER_PUB_NIC -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT; iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s 10.66.66.0/24 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j MASQUERADE
PostDown = while iptables -C INPUT -i $SERVER_PUB_NIC -p udp --dport $SERVER_PORT -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null; do iptables -D INPUT -i $SERVER_PUB_NIC -p udp --dport $SERVER_PORT -m comment --comment SSH-one-WireGuard -j ACCEPT; done; while iptables -C FORWARD -s 10.66.66.0/24 -i wg0 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null; do iptables -D FORWARD -s 10.66.66.0/24 -i wg0 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j ACCEPT; done; while iptables -C FORWARD -d 10.66.66.0/24 -i $SERVER_PUB_NIC -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT 2>/dev/null; do iptables -D FORWARD -d 10.66.66.0/24 -i $SERVER_PUB_NIC -o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment SSH-one-WireGuard -j ACCEPT; done; while iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j MASQUERADE 2>/dev/null; do iptables -t nat -D POSTROUTING -s 10.66.66.0/24 -o $SERVER_PUB_NIC -m comment --comment SSH-one-WireGuard -j MASQUERADE; done
WGCONF
chmod 0600 "$config_tmp"
mv -fT -- "$config_tmp" /etc/wireguard/wg0.conf || fail 'could not install the WireGuard server config.'
wg-quick strip wg0 >/dev/null || fail 'WireGuard config validation failed; inspect /etc/wireguard/wg0.conf.'
systemctl enable --now wg-quick@wg0 || fail 'WireGuard failed to start; inspect journalctl -u wg-quick@wg0.'
systemctl is-active --quiet wg-quick@wg0 || fail 'WireGuard did not become active.'
wg show wg0 >/dev/null || fail 'WireGuard interface wg0 is not available.'
printf 'WireGuard is active on UDP %s. IPv4 forwarding and NAT are enabled.\n' "$SERVER_PORT"
printf 'Create a client profile with: addwg\n'
printf 'Allow UDP %s in the VPS provider firewall/security group.\n' "$SERVER_PORT"
