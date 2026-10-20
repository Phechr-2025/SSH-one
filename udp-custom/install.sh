#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'UDP Custom: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
[[ -r /etc/os-release ]] || fail 'cannot identify the operating system.'
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 20.04 ]] || fail 'the upstream UDP Custom binary documents Ubuntu 20.04 only.'
[[ $(uname -m) == x86_64 ]] || fail 'the upstream binary is x86_64 only.'
command -v systemctl >/dev/null || fail 'systemd is required.'

repo='https://raw.githubusercontent.com/http-custom/udp-custom/fcf839259e623af001cfa85fe1e1e343c58df264'
tmp=$(mktemp -d /tmp/ssh-one-udp.XXXXXX)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

fetch() {
  local path=$1 output=$2 expected=$3
  curl --fail --location --retry 3 --silent --show-error "$repo/$path" -o "$output" || fail "download failed: $path"
  local actual
  actual=$(sha256sum "$output" | awk '{print $1}')
  [[ $actual == "$expected" ]] || fail "checksum mismatch: $path"
}

fetch 'bin/udp-custom-linux-amd64' "$tmp/udp-custom" '2a1b5584c7947feb5a02e847e09795751024f63ce7137a353c2b9c2a4282d636'
fetch 'module/udpgw' "$tmp/udpgw" '48832133b7bdff20261bac41713e3ea231404b85764c1143d2095311867fb43f'
fetch 'config/config.json' "$tmp/config.json" '52ba917ff7e752f9a36277dd07cfeff3715881d15d0ecea8f82238cf1768c5f4'

install -d -m 0755 /root/udp /etc/systemd/system
install -m 0755 "$tmp/udp-custom" /root/udp/udp-custom
install -m 0755 "$tmp/udpgw" /bin/udpgw
if [[ ! -e /root/udp/config.json ]]; then
  install -m 0600 "$tmp/config.json" /root/udp/config.json
fi

cat >/etc/systemd/system/udp-custom.service <<'UNIT'
[Unit]
Description=UDP Custom
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/udp
ExecStart=/root/udp/udp-custom server
Restart=on-failure
RestartSec=2s
User=root

[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/udpgw.service <<'UNIT'
[Unit]
Description=UDP Custom gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/udpgw --listen-addr 127.0.0.1:7800 --max-clients 1000 --max-connections-for-client 100
Restart=on-failure
RestartSec=2s
User=root

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now udpgw.service udp-custom.service

# Preserve the existing firewall. If UFW is active, allow the requested UDP range.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 1:65535/udp comment 'SSH-one UDP Custom'
fi

printf 'UDP Custom services installed. Check the VPS provider firewall/security group for inbound UDP ports 1-65535.\n'
