#!/bin/bash

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi
# =====================================================

# Color
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHT='\033[0;37m'

MYIP=$(wget -qO- ipinfo.io/ip);
MYIP=$(curl -s ipinfo.io/ip )
MYIP=$(curl -sS ipv4.icanhazip.com)
MYIP=$(curl -sS ifconfig.me )
clear
domain=$(cat /etc/xray/domain)
if [[ -z "$domain" ]]; then echo "Missing /etc/xray/domain; complete host/DNS setup first." >&2; exit 1; fi
if ! apt-get install -y iptables iptables-persistent curl socat xz-utils wget apt-transport-https gnupg gnupg2 gnupg1 dnsutils lsb-release cron bash-completion ntpdate jq lsof; then
	echo "Could not install Xray dependencies." >&2
	exit 1
fi
ntpdate pool.ntp.org
apt -y install chrony
timedatectl set-ntp true
systemctl enable chronyd && systemctl restart chronyd
systemctl enable chrony && systemctl restart chrony
timedatectl set-timezone Asia/Kuala_Lumpur
chronyc sourcestats -v
chronyc tracking -v
date

# / / Ambil Xray Core Version Terbaru
latest_version="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -er '.tag_name | ltrimstr("v")')" || { echo "Could not determine the latest Xray version." >&2; exit 1; }
[[ -n $latest_version ]] || { echo "GitHub returned an empty Xray version." >&2; exit 1; }

# / / Installation Xray Core
xraycore_link="https://github.com/XTLS/Xray-core/releases/download/v$latest_version/Xray-linux-64.zip"

# / / Make Main Directory
mkdir -p /usr/bin/xray
mkdir -p /etc/xray

# / / Unzip Xray Linux 64
xray_tmp=$(mktemp -d) || { echo "Could not create a temporary directory for Xray." >&2; exit 1; }
if ! curl --fail --location --retry 3 --connect-timeout 10 --max-time 120 "$xraycore_link" -o "$xray_tmp/Xray-linux-64.zip"; then
	echo "Could not download Xray archive: $xraycore_link" >&2
	rm -rf -- "$xray_tmp"
	exit 1
fi
if ! unzip -q "$xray_tmp/Xray-linux-64.zip" -d "$xray_tmp" || [[ ! -f "$xray_tmp/xray" ]]; then
	echo "The downloaded Xray archive is invalid or missing the xray binary." >&2
	rm -rf -- "$xray_tmp"
	exit 1
fi
install -m 0755 "$xray_tmp/xray" /usr/local/bin/xray
rm -rf -- "$xray_tmp"

# Make Folder XRay
mkdir -p /var/log/xray/

if lsof -nP -iTCP:80 -sTCP:LISTEN | grep -q LISTEN; then
	echo "TCP port 80 is already in use. Stop the service using it, then retry certificate issuance." >&2
	exit 1
fi
if ! curl --fail --location --retry 3 "${SSH_ONE_RAW_BASE}/acme.sh" -o /root/acme.sh; then
	echo "Could not download acme.sh from the SSH-one repository." >&2
	exit 1
fi
if ! bash /root/acme.sh --install; then echo "acme.sh installation failed." >&2; exit 1; fi
rm -f /root/acme.sh
acme_bin=/root/.acme.sh/acme.sh
[[ -x $acme_bin ]] || { echo "acme.sh binary was not installed at $acme_bin." >&2; exit 1; }
if ! "$acme_bin" --register-account -m "admin@${domain}"; then echo "Could not register the ACME account." >&2; exit 1; fi
if ! "$acme_bin" --issue --standalone -d "$domain"; then
	echo "Certificate issuance failed. Check DNS propagation and ensure TCP port 80 is reachable from the Internet." >&2
	exit 1
fi
if ! "$acme_bin" --install-cert -d "$domain" --fullchain-file /etc/xray/xray.crt --key-file /etc/xray/xray.key; then
	echo "Could not install the Xray TLS certificate." >&2
	exit 1
fi
[[ -s /etc/xray/xray.crt && -s /etc/xray/xray.key ]] || { echo "The TLS certificate or key is missing after issuance." >&2; exit 1; }
uuid7=$(cat /proc/sys/kernel/random/uuid)
uuid1=$(cat /proc/sys/kernel/random/uuid)
uuid2=$(cat /proc/sys/kernel/random/uuid)
uuid3=$(cat /proc/sys/kernel/random/uuid)
uuid4=$(cat /proc/sys/kernel/random/uuid)
uuid5=$(cat /proc/sys/kernel/random/uuid)
uuid6=$(cat /proc/sys/kernel/random/uuid)

# // Certificate File
path_crt="/etc/xray/xray.crt"
path_key="/etc/xray/xray.key"

# Buat Config Xray
cat > /etc/xray/config.json << END
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "info"
  },
  "inbounds": [
    {
      "port": 8443,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid1}",
            "alterId": 0
#xray-vmess-tls
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${path_crt}",
              "keyFile": "${path_key}"
            }
          ]
        },
        "tcpSettings": {},
        "kcpSettings": {},
        "httpSettings": {},
        "wsSettings": {
          "path": "/vmess",
          "headers": {
            "Host": ""
          }
        },
        "quicSettings": {}
      }
    },
    {
      "port": 80,
      "protocol": "vmess",
      "settings": {
        "clients": [

          {
            "id": "${uuid2}",
            "alterId": 0
#xray-vmess-nontls
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "tlsSettings": {},
        "tcpSettings": {},
        "kcpSettings": {},
        "httpSettings": {},
        "wsSettings": {
          "path": "/vmess",
          "headers": {
            "Host": ""
          }
        },
        "quicSettings": {}
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "port": 8444,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid3}"
#xray-vless-tls
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${path_crt}",
              "keyFile": "${path_key}"
            }
          ]
        },
        "tcpSettings": {},
        "kcpSettings": {},
        "httpSettings": {},
        "wsSettings": {
          "path": "/vless",
          "headers": {
            "Host": ""
          }
        },
        "quicSettings": {}
      },
      "domain": "$domain",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "port": 81,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid4}"
#xray-vless-nontls
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "tlsSettings": {},
        "tcpSettings": {},
        "kcpSettings": {},
        "httpSettings": {},
        "wsSettings": {
          "path": "/vless",
          "headers": {
            "Host": ""
          }
        },
        "quicSettings": {}
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "port": 2083,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${uuid5}"
#xray-trojan
          }
        ],
        "fallbacks": [
          {
            "dest": 80
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${path_crt}",
              "keyFile": "${path_key}"
            }
          ],
          "alpn": [
            "http/1.1"
          ]
        },
        "tcpSettings": {},
        "kcpSettings": {},
        "wsSettings": {},
        "httpSettings": {},
        "quicSettings": {},
        "grpcSettings": {}
      },
      "domain": "$domain"
     }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
      "protocol": "blackhole",
      "settings": {},
      "tag": "blocked"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "blocked"
      },
      {
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api",
        "type": "field"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ]
      }
    ]
  },
  "stats": {},
  "api": {
    "services": [
      "StatsService"
    ],
    "tag": "api"
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  }
}
END

if ! /usr/local/bin/xray run -test -config /etc/xray/config.json; then
	echo "Xray rejected /etc/xray/config.json; see the error above." >&2
	exit 1
fi

# / / Installation Xray Service
cat > /etc/systemd/system/xray.service << END
[Unit]
Description=Xray Service Mod
Documentation=https://nekopoi.care
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray -config /etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
END

# // Enable & Start Service
# Accept port Xray
iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 8443 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 8443 -j ACCEPT
iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 8444 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 8444 -j ACCEPT
iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 80 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 80 -j ACCEPT
iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 81 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 81 -j ACCEPT
iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 2083 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 2083 -j ACCEPT
iptables-save > /etc/iptables.up.rules
iptables-restore -t < /etc/iptables.up.rules
netfilter-persistent save
netfilter-persistent reload
systemctl daemon-reload
if ! systemctl enable --now xray.service || ! systemctl is-active --quiet xray.service; then
	echo "Xray service did not start. Check: journalctl -u xray.service -n 100 --no-pager" >&2
	exit 1
fi

# Install Trojan Go
trojango_link="https://github.com/NevermoreSSH/addons/releases/download/0.10.6/trojan-go-linux-amd64.zip"
mkdir -p "/usr/bin/trojan-go"
mkdir -p "/etc/trojan-go"
trojango_tmp=$(mktemp -d) || { echo "Could not create a temporary directory for Trojan-Go." >&2; exit 1; }
if ! curl --fail --location --retry 3 --connect-timeout 10 --max-time 120 "$trojango_link" -o "$trojango_tmp/trojan-go.zip"; then
	echo "Could not download Trojan-Go archive: $trojango_link" >&2
	rm -rf -- "$trojango_tmp"
	exit 1
fi
if ! unzip -q "$trojango_tmp/trojan-go.zip" -d "$trojango_tmp" || [[ ! -f "$trojango_tmp/trojan-go" ]]; then
	echo "The downloaded Trojan-Go archive is invalid or missing the binary." >&2
	rm -rf -- "$trojango_tmp"
	exit 1
fi
install -m 0755 "$trojango_tmp/trojan-go" /usr/local/bin/trojan-go
rm -rf -- "$trojango_tmp"
mkdir -p /var/log/trojan-go/
touch /etc/trojan-go/akun.conf
touch /var/log/trojan-go/trojan-go.log

# Buat Config Trojan Go
cat > /etc/trojan-go/config.json << END
{
  "run_type": "server",
  "local_addr": "0.0.0.0",
  "local_port": 2087,
  "remote_addr": "127.0.0.1",
  "remote_port": 89,
  "log_level": 1,
  "log_file": "/var/log/trojan-go/trojan-go.log",
  "password": [
      "$uuid"
  ],
  "disable_http_check": true,
  "udp_timeout": 60,
  "ssl": {
    "verify": false,
    "verify_hostname": false,
    "cert": "/etc/xray/xray.crt",
    "key": "/etc/xray/xray.key",
    "key_password": "",
    "cipher": "",
    "curves": "",
    "prefer_server_cipher": false,
    "sni": "$domain",
    "alpn": [
      "http/1.1"
    ],
    "session_ticket": true,
    "reuse_session": true,
    "plain_http_response": "",
    "fallback_addr": "127.0.0.1",
    "fallback_port": 0,
    "fingerprint": "firefox"
  },
  "tcp": {
    "no_delay": true,
    "keep_alive": true,
    "prefer_ipv4": true
  },
  "mux": {
    "enabled": false,
    "concurrency": 8,
    "idle_timeout": 60
  },
  "websocket": {
    "enabled": true,
    "path": "/trojango",
    "host": "$domain"
  },
    "api": {
    "enabled": false,
    "api_addr": "",
    "api_port": 0,
    "ssl": {
      "enabled": false,
      "key": "",
      "cert": "",
      "verify_client": false,
      "client_cert": []
    }
  }
}
END

# Installing Trojan Go Service
cat > /etc/systemd/system/trojan-go.service << END
[Unit]
Description=Trojan-Go Service Mod
Documentation=nekopoi.care
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/trojan-go -config /etc/trojan-go/config.json
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
END

# Trojan Go Uuid
cat > /etc/trojan-go/uuid.txt << END
$uuid
END

# restart
iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport 2086 -j ACCEPT
iptables -I INPUT -m state --state NEW -m udp -p udp --dport 2087 -j ACCEPT
iptables-save > /etc/iptables.up.rules
iptables-restore -t < /etc/iptables.up.rules
netfilter-persistent save
netfilter-persistent reload
systemctl daemon-reload
if ! jq -e . /etc/trojan-go/config.json >/dev/null; then
	echo "Generated Trojan-Go configuration is not valid JSON." >&2
	exit 1
fi
if ! systemctl enable --now trojan-go || ! systemctl is-active --quiet trojan-go; then
	echo "Trojan-Go service did not start. Check: journalctl -u trojan-go.service -n 100 --no-pager" >&2
	exit 1
fi

cd
cp /root/domain /etc/xray
