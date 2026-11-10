#!/bin/bash
set -Eeuo pipefail

UDP_DIR="/root/udp"
UDP_SOURCE="https://raw.githubusercontent.com/NevermoreSSH/Vergil/main/Tunnel"
UDP_PORT="36712"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Run this installer as root."
    exit 1
fi

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --retry 3 "$url" --output "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --tries=3 --output-document="$destination" "$url"
    else
        echo "Install curl or wget, then run this installer again."
        exit 1
    fi
}

if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemd is required to run UDP Custom."
    exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Downloading UDP Custom from the VVV source..."
download_file "${UDP_SOURCE}/udp-custom-linux-amd64" "${tmp_dir}/udp-custom"
download_file "${UDP_SOURCE}/config.json" "${tmp_dir}/config.json"

if [[ ! -s "${tmp_dir}/udp-custom" || ! -s "${tmp_dir}/config.json" ]]; then
    echo "The UDP Custom binary or configuration download was empty."
    exit 1
fi

install -d -m 0755 "$UDP_DIR"
install -m 0755 "${tmp_dir}/udp-custom" "${UDP_DIR}/udp-custom"
install -m 0644 "${tmp_dir}/config.json" "${UDP_DIR}/config.json"

cat > /etc/systemd/system/udp-custom.service <<'EOF'
[Unit]
Description=UDP Custom by NevermoreSSH
After=network.target

[Service]
User=root
Type=simple
WorkingDirectory=/root/udp
ExecStart=/root/udp/udp-custom server
Restart=always
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p udp --dport "$UDP_PORT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p udp --dport "$UDP_PORT" -j ACCEPT
    fi
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    fi
fi

systemctl daemon-reload
systemctl enable --now udp-custom.service
echo "UDP Custom is enabled on UDP port ${UDP_PORT}."
systemctl --no-pager --full status udp-custom.service
