# SSH-one

<div align="center">
  <img src="assets/ssh-one-banner.svg" alt="SSH-one — VPN services installer" width="100%">
</div>

**Languages:** [ไทย](README.md) | [English](README_EN.md)

SSH-one installs and manages a set of SSH/VPN services on a VPS. This README documents the v26 package. See [the Thai README](README.md) for the full Thai installation notes and service details.

## Quick installation

> Use a new VPS. Continuing a failed or partial installation is not supported.

1. Upload the repository contents to the root of your GitHub repository.
2. Connect to the VPS as <code>root</code>.
3. Run:

~~~~bash
curl -fsSL -o ssh-one-install.sh https://raw.githubusercontent.com/Phechr-2025/SSH-one/main/install.sh
bash ssh-one-install.sh Phechr-2025 SSH-one main
~~~~

4. Enter a hostname with a DNS A record already pointing to the VPS public IPv4 address, then enter a Cloudflare API token when prompted.

The installer checks SSH access before restarting the VPS. On success, it counts down for 10 seconds and reboots. If the SSH check fails, inspect <code>/root/log-install.txt</code>.

## Requirements

- New VPS running Ubuntu 20.04 x86_64 with systemd.
- Root access over SSH and a public IPv4 address.
- Cloudflare zone active on its assigned nameservers, with a DNS-only A record for the chosen host pointing to the VPS public IPv4.
- A Cloudflare API token from the account that owns the zone, with Zone Read and DNS Write access scoped to the required zone.
- Provider firewall/security-group rules that allow the ports for the services you plan to use.

Debian, ARM, and other Ubuntu releases are not certified by this v26 package.

## API for a sales or provisioning backend

The local API can read VPS/system information and manage SSH, UDP Custom, VMess, VLESS, Trojan, and Trojan-Go accounts. It supports create, list, read, expiry update, and delete operations.

- [API v1 guide — English](API_GUIDE_EN.md)
- [คู่มือ API v1 — ภาษาไทย](API_GUIDE_TH.md)

The API binds only to <code>127.0.0.1:8765</code>. Connect to the VPS over SSH using its IP plus an SSH password or key, create a local SSH tunnel, and send an API bearer token with every API request. Do not expose port 8765 to the internet or put SSH/API secrets in a browser.

Example tunnel:

~~~~bash
ssh -N -L 8765:127.0.0.1:8765 root@VPS_IP
~~~~

Create and manage tokens from <code>menu</code>, option <code>27. API token management</code>. Tokens default to 30 days and can be listed or revoked. All tokens have the same API permissions in v26.

The API does not cover L2TP, PPTP, SSTP, WireGuard, Shadowsocks, ShadowsocksR, firewall, DNS, update, reboot, uninstall, or general system commands. See the API guide for endpoint schemas, examples, security requirements, error codes, and limitations.

## Update, uninstall, and service information

- Main menu option <code>21</code> or command <code>ssh-one-update</code> updates managed SSH-one files. A successful update reports old/new versions and the file changes, then counts down for 10 seconds before reboot.
- Main menu option <code>26</code> or command <code>ssh-one-uninstall</code> starts removal. Review the Thai README for the files/data removed and the items intentionally retained.
- UDP Custom installs by default. Its listener defaults to UDP port <code>36712</code>; the host firewall can be configured for UDP <code>1–65535</code>, with configurable exclusions.
- SSH and UDP account lists are separate. Expiry and API credential details are described in the API guide.

For the supported services, detailed ports, Cloudflare setup, installation prompts, known limitations, and recovery steps, continue to the [full Thai README](README.md).