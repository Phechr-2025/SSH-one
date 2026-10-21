# SSH-one

**Languages:** [English](README.md) | [ไทย](README_TH.md)

<div align="center">
  <img src="assets/ssh-one-banner.svg" alt="SSH-one — VPN services installer" width="100%">
</div>

SSH-one installs and manages SSH/VPN services on a VPS. This document describes v26.

## Install

Use a new Ubuntu 20.04 x86_64 VPS with systemd, a public IPv4 address, and working root SSH access. Debian, ARM, and other Ubuntu releases are not certified.

Before installing, create a DNS-only A record in Cloudflare (for example, <code>ssh1.example.com</code>) that points to the VPS public IPv4. Prepare a Cloudflare API token from the account that owns this zone, with Zone Read and DNS Write permissions limited to that zone.

Download and run the installer on the VPS:

~~~~bash
curl -fsSL -o ssh-one-install.sh https://raw.githubusercontent.com/Phechr-2025/SSH-one/main/install.sh
bash ssh-one-install.sh Phechr-2025 SSH-one main
~~~~

Enter the hostname and Cloudflare token when prompted. The installer checks DNS, zone access, and the record. After its SSH check succeeds, it counts down for 10 seconds and reboots. A daily reboot is scheduled for 05:00 in the VPS local timezone. If installation fails, inspect <code>/root/log-install.txt</code>; do not rerun the installer over a partial installation.

## Installer inputs

- **Host/subdomain:** Full DNS name, such as <code>ssh1.example.com</code>. Do not enter an IP, port, or <code>https://</code>. Its DNS-only A record must already point to the VPS.
- **Cloudflare API token:** Create it in the same Cloudflare account as the zone. Grant Zone Read and DNS Write only for that zone. Do not use a Global API Key.

The installer verifies public DNS, zone nameservers, token access, and the A record. DNS must have propagated and there must be no conflicting record. It stops and reports any mismatch.

Create the token in Cloudflare: My Profile → API Tokens → Create Token → Edit Zone DNS. Grant Zone Read and DNS Write, and restrict Zone Resources to this domain.

For a step-by-step Thai walkthrough, see the [Thai installation guide](docs/install/INSTALL_GUIDE_TH.md).

## Use and maintain

- Open the main menu with <code>menu</code>; if another command shadows it, use <code>/usr/bin/menu</code>.
- Option **1** manages UDP Custom and the host firewall. UDP Custom is installed by default.
- Option **21** updates SSH-one managed files. A successful update reports the version and file changes, counts down for 10 seconds, then reboots.
- Open **22. Settings → 21** to control whether actions return to the main menu. The default is off.
- Option **26** uninstalls SSH-one. Review the summary, back up data, and type <code>UNINSTALL</code> to confirm.
- Option **27** creates, lists, and deletes API tokens. The default token lifetime is 30 days.

Updates replace only files listed in the managed manifest. They do not automatically update OS packages, service configuration/accounts, or separately downloaded upstream binaries. Uninstall removes some service data; it retains OpenSSH, OS packages, unlabelled firewall rules, and files modified after installation.

## Services and default ports

Open required ports in both the VPS firewall and the provider firewall/security group. These are configured defaults when the service is installed and running; check the VPS configuration and service status before use.

| Service | Port/protocol |
| --- | --- |
| OpenSSH | TCP 22, 2253 |
| Dropbear | TCP 109, 143, 1153 |
| OpenVPN | TCP 1194, UDP 2200, TLS/TCP 990 |
| SSLH / SSH WebSocket | TCP 443 (TLS multiplex), HTTP 8880 |
| Stunnel5 | TCP 445, 777, 990 |
| BadVPN UDPGW | TCP 7100, 7200, 7300 (loopback) |
| WireGuard | UDP 7070 |
| L2TP/IPsec, PPTP | UDP 500, 1701, 4500; TCP 1732 |
| SSTP | TCP 444 |
| Shadowsocks-R | TCP 1443–1543 |
| Shadowsocks OBFS | TCP/TLS 2443–2543, TCP/HTTP 3443–3543 |
| Xray VMess | TCP/TLS 8443, TCP 80 |
| Xray VLESS | TCP/TLS 8444, TCP 81 |
| Xray Trojan, Trojan-Go | TCP 2083, 2087 |
| OHP | TCP 8181, 8282, 8383 |
| UDP Custom | UDP 1–65535; listener defaults to 36712 |

UDP Custom uses UDP ports 1–65535. The installer opens this range in UFW when UFW is active; allow the ports separately in the VPS provider firewall/security group. Ports 500, 1701, 2200, 4500, and 7070 are excluded by default for other UDP services. The listener defaults to <code>:36712</code> and can be changed from option 1. This binary cannot report connected UDP usernames.

## API for automation

API v1 reads VPS/system/port information and creates, lists, reads, renews, or deletes SSH, UDP Custom, VMess, VLESS, Trojan, and Trojan-Go accounts. Connect through an SSH tunnel to <code>127.0.0.1:8765</code> and send a bearer token with every request. Do not expose the API port publicly or put secrets in a browser.

- [API guide — English](docs/api/API_GUIDE_EN.md)
- [คู่มือ API ภาษาไทย](docs/api/API_GUIDE_TH.md)

There are no API endpoints for L2TP/PPTP/SSTP, WireGuard, Shadowsocks/SSR, firewall, DNS, update, reboot, uninstall, or general shell commands.

## Limitations and help

SlowDNS is not installed, gRPC is disabled, and Squid is not included. OHP requires an HTTP proxy at <code>127.0.0.1:3128</code>. Upstream services can behave differently across VPS providers and networks; ping or throughput cannot be guaranteed.

For errors, inspect the relevant service status and <code>/root/log-install.txt</code>. Back up before installing, updating, or uninstalling. Revoke and replace any Cloudflare/API token that was exposed in Git history.
