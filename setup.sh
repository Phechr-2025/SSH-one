#!/bin/bash

SSH_ONE_SOURCE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
# shellcheck source=/etc/ssh-one/repository.conf
if [ -r "$SSH_ONE_REPO_CONFIG" ]; then . "$SSH_ONE_REPO_CONFIG"; fi
if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
fi
if [ "$(systemd-detect-virt)" == "openvz" ]; then
		echo "OpenVZ is not supported"
		exit 1
fi
# Link Hosting Kalian Untuk Ssh Vpn
akbarvpn="${SSH_ONE_RAW_HOST}/ssh"
# Link Hosting Kalian Untuk Sstp
akbarvpnn="${SSH_ONE_RAW_HOST}/sstp"
# Link Hosting Kalian Untuk Ssr
akbarvpnnn="${SSH_ONE_RAW_HOST}/ssr"
# Link Hosting Kalian Untuk Shadowsocks
akbarvpnnnn="${SSH_ONE_RAW_HOST}/shadowsocks"
# Link Hosting Kalian Untuk Wireguard
akbarvpnnnnn="${SSH_ONE_RAW_HOST}/wireguard"
# Link Hosting Kalian Untuk Xray
akbarvpnnnnnn="${SSH_ONE_RAW_HOST}/xray"
# Link Hosting Kalian Untuk Ipsec
akbarvpnnnnnnn="${SSH_ONE_RAW_HOST}/ipsec"
# Link Hosting Kalian Untuk Backup
akbarvpnnnnnnnn="${SSH_ONE_RAW_HOST}/backup"
# Link Hosting Kalian Untuk Websocket
akbarvpnnnnnnnnn="${SSH_ONE_RAW_HOST}/websocket"
# Link Hosting Kalian Untuk Ohp
akbarvpnnnnnnnnnn="${SSH_ONE_RAW_HOST}/ohp"

# Do not overwrite /etc/resolv.conf; cloud-init and systemd-resolved may manage it.
echo "Checking VPS"
report_error() {
	printf '%s\n' "$*" | tee -a /root/log-install.txt >&2
}
if [ -f "/etc/ssh-one/installation-complete" ]; then
		report_error "SSH-one is already installed. This setup will not run a second time."
		exit 1
	fi
if [ -e "/etc/ssh-one/install-in-progress" ]; then
		report_error "An earlier SSH-one installation is incomplete. This setup cannot safely resume it; use a fresh VPS unless a recovery procedure specifically covers that version."
		exit 1
fi
if [ -e "/etc/xray/domain" ] || [ -e "/etc/v2ray/domain" ] || [ -e "/root/domain" ] || [ -e "/var/lib/crot/ipvps.conf" ]; then
		report_error "SSH/VPN installation files already exist. This may be an existing or partial installation; use a fresh VPS unless a recovery procedure specifically covers that version."
		exit 1
fi
if ! wget -q -O slhost.sh "https://${akbarvpn}/slhost.sh"; then
		report_error "Could not download the host/DNS setup script from ${akbarvpn}/slhost.sh"
		exit 1
fi
chmod +x slhost.sh
if ! ./slhost.sh; then
		report_error "Host/DNS setup failed. Later services were not started."
		exit 1
fi
if ! install -d -m 0755 /etc/ssh-one; then
	report_error "Could not create the SSH-one state directory."
	exit 1
fi
if ! printf 'v25 started at %s\n' "$(date -Is)" > /etc/ssh-one/install-in-progress; then
	report_error "Could not write the installation-in-progress marker."
	exit 1
fi
if [[ -L /etc/ssh-one/menu-after-create || -e /etc/ssh-one/menu-after-create ]]; then
	report_error "Unexpected menu setting file already exists; refusing to overwrite it."
	exit 1
fi
if ! printf '0\n' > /etc/ssh-one/menu-after-create || ! chmod 0644 /etc/ssh-one/menu-after-create; then
	report_error "Could not initialize the account-creation menu setting."
	exit 1
fi

# Preserve any command paths that the legacy installers will replace, so uninstall
# can restore them instead of deleting files that predated SSH-one.
backup_preexisting_paths() {
	local path name source target
	local manifest="$SSH_ONE_SOURCE_ROOT/update/managed-files.tsv"
	local command_backup=/etc/ssh-one/backups/managed-bin
	local runtime_backup=/etc/ssh-one/backups/runtime
	local preexisting_tmp="$command_backup/.preexisting-managed-bin.tsv.new"
	if [[ ! -r "$manifest" ]]; then
		report_error "Managed-file manifest is missing: $manifest"
		return 1
	fi
	install -d -m 0700 "$command_backup" "$runtime_backup" || return 1
	: > "$preexisting_tmp" || { report_error "Could not prepare the pre-install command list."; return 1; }
	while IFS=$'\t' read -r source target _; do
		[[ -n "$source" && "$source" != \#* ]] || continue
		[[ "$target" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || { report_error "Invalid target in managed-file manifest: $target"; return 1; }
		path="/usr/bin/$target"
		if [[ -L "$path" ]]; then
			report_error "A symbolic link already uses the command path $path. Resolve this collision before installing."
			return 1
		elif [[ -f "$path" ]]; then
			cp -a -- "$path" "$command_backup/$target" || { report_error "Could not preserve pre-existing command $path"; return 1; }
			printf '%s\n' "$target" >> "$preexisting_tmp" || { report_error "Could not record pre-existing command $path"; return 1; }
		elif [[ -e "$path" ]]; then
			report_error "A non-file already uses the command path $path. Resolve this collision before installing."
			return 1
		fi
	done < "$manifest"
	mv -fT -- "$preexisting_tmp" "$command_backup/preexisting-managed-bin.tsv" || { report_error "Could not save the pre-install command list."; return 1; }
	for path in /usr/local/bin/xray /usr/local/bin/trojan-go /usr/local/bin/ws-tls /usr/local/bin/ws-nontls /usr/local/bin/ws-ovpn /usr/local/bin/ohpserver /root/udp/udp-custom; do
		if [[ -L "$path" ]]; then
			report_error "A symbolic link already uses the runtime path $path. Resolve this collision before installing."
			return 1
		elif [[ -f "$path" ]]; then
			name=${path##*/}
			cp -a -- "$path" "$runtime_backup/$name" || { report_error "Could not preserve pre-existing runtime file $path"; return 1; }
		elif [[ -e "$path" ]]; then
			report_error "A non-file already uses the runtime path $path. Resolve this collision before installing."
			return 1
		fi
	done
}
backup_preexisting_paths || exit 1
# Do not pass the Cloudflare token to unrelated legacy service installers.
unset CF_API_TOKEN

download_script() {
	local path=$1 url=$2
	if ! wget -q --tries=3 --timeout=30 -O "$path" "$url"; then
		report_error "Download failed: $url"
		return 1
	fi
	chmod +x "$path"
}
run_installer() {
	local name=$1 path=$2 url=$3
	download_script "$path" "$url" || return 1
	if ! bash "./$path"; then
		report_error "$name installer failed: $path"
		return 1
	fi
}
run_script() {
	local path=$1 url=$2
	download_script "$path" "$url" || return 1
	if ! bash "./$path"; then
		report_error "Installer failed: $path"
		return 1
	fi
}
#install xray
run_installer Xray ins-xray.sh "https://${akbarvpnnnnnn}/ins-xray.sh" || exit 1
#install ssh ovpn
run_installer SSH-VPN ssh-vpn.sh "https://${akbarvpn}/ssh-vpn.sh" || exit 1
run_installer SSTP sstp.sh "https://${akbarvpnn}/sstp.sh" || exit 1
#install ssr
run_installer SSR ssr.sh "https://${akbarvpnnn}/ssr.sh" || exit 1
run_installer Shadowsocks sodosok.sh "https://${akbarvpnnnn}/sodosok.sh" || exit 1
#installwg
run_installer WireGuard wg.sh "https://${akbarvpnnnnn}/wg.sh" || exit 1
#install L2TP
run_installer IPsec ipsec.sh "https://${akbarvpnnnnnnn}/ipsec.sh" || exit 1
run_script set-br.sh "https://${akbarvpnnnnnnnn}/set-br.sh" || exit 1
# Websocket
run_script edu.sh "https://${akbarvpnnnnnnnnn}/edu.sh" || exit 1
# Ohp Server
run_script ohp.sh "https://${akbarvpnnnnnnnnnn}/ohp.sh" || exit 1
# SlowDNS is not installed automatically: the upstream hop installer points at
# missing files and its legacy SLDNS installer can delete data under /root.
echo "SlowDNS skipped: the upstream installer is incomplete and unsafe."
# Install the VVV-compatible UDP Custom service (Ubuntu 20.04 x86_64).
if ! wget -q --tries=3 --timeout=30 -O /tmp/ssh-one-udp-install.sh "${SSH_ONE_RAW_BASE}/udp-custom/install.sh"; then
		report_error "Could not download the UDP Custom installer."
		exit 1
fi
if ! bash /tmp/ssh-one-udp-install.sh; then
		report_error "UDP Custom installation failed; see the message above."
		exit 1
fi
rm -f /tmp/ssh-one-udp-install.sh
# Informasi IP Saya dan Semua Port TCP UDP
# wget ${SSH_ONE_RAW_BASE}/ipsaya.sh && chmod +x ipsaya.sh
#
# install xray sl-grpc
# wget ${SSH_ONE_RAW_BASE}/grpc/sl-grpc.sh && chmod +x sl-grpc.sh && screen -S sl-grpc ./sl-grpc.sh
# install xray grpc
# wget ${SSH_ONE_RAW_BASE}/grpc/xray-grpc.sh && chmod +x xray-grpc.sh && screen -S xray-grpc ./xray-grpc.sh
# install shadowsocks plugin
# wget ${SSH_ONE_RAW_BASE}/shadowsocks-plugin/install-ss-plugin.sh && chmod +x install-ss-plugin.sh && ./install-ss-plugin.sh


rm -f /root/ssh-vpn.sh
rm -f /root/sstp.sh
rm -f /root/wg.sh
rm -f /root/ss.sh
rm -f /root/ssr.sh
rm -f /root/ins-xray.sh
rm -f /root/ipsec.sh
rm -f /root/set-br.sh
rm -f /root/edu.sh
rm -f /root/ohp.sh
rm -f /root/install
rm -f /root/sl-grpc.sh
rm -f /root/install-sldns
rm -f /root/install-ss-plugin.sh
# Upstream setup references ssh/set.sh, which is absent from both upstream
# and this repository. Never enable a service whose ExecStart points at it.
autosett_unit=/etc/systemd/system/autosett.service
if [[ -f "$autosett_unit" ]] && grep -Fq 'ExecStart=/bin/bash /etc/set.sh' "$autosett_unit"; then
	systemctl disable --now autosett.service >/dev/null 2>&1 || true
	rm -f "$autosett_unit" /etc/systemd/system/multi-user.target.wants/autosett.service /etc/set.sh
	if ! systemctl daemon-reload; then
		report_error "Could not reload systemd after removing the broken autosett unit."
		exit 1
	fi
	systemctl reset-failed autosett.service >/dev/null 2>&1 || true
fi
echo "Autosett skipped: upstream ssh/set.sh is unavailable." | tee -a /root/log-install.txt
if ! bash "$SSH_ONE_SOURCE_ROOT/update/install-managed-files.sh"; then
	report_error "Could not safely install the SSH-one command inventory."
	exit 1
fi
if [[ ! -x /usr/bin/menu ]] || ! /usr/bin/menu --check; then
	report_error "The main menu failed its post-installation check. Run /usr/bin/menu --check for details."
	exit 1
fi
resolved_menu=$(type -P menu 2>/dev/null || true)
if [[ -n "$resolved_menu" && "$resolved_menu" != /usr/bin/menu ]]; then
	report_error "The command 'menu' currently resolves to $resolved_menu instead of /usr/bin/menu. Use /usr/bin/menu or remove the conflicting command from PATH."
fi
if [[ -n ${SSH_ONE_DOMAIN_HOST:-} ]]; then
	printf '%s\n' "$SSH_ONE_DOMAIN_HOST" > /etc/ssh-one/host || { report_error "Could not save the configured host name."; exit 1; }
fi
printf "Main menu installed. Run 'menu' after installation, or use /usr/bin/menu.\n" | tee -a /root/log-install.txt
history -c
echo "1.2" > /home/ver
echo " "
echo "Installation has been completed!!"
echo "============================================================================" | tee -a /root/log-install.txt
echo "" | tee -a /root/log-install.txt
echo "----------------------------------------------------------------------------" | tee -a /root/log-install.txt
echo ""  | tee -a /root/log-install.txt
echo "   >>> Service & Port"  | tee -a /root/log-install.txt
echo "   - OpenSSH                 : 22, 2253"  | tee -a /root/log-install.txt
echo "   - OpenVPN                 : TCP 1194, UDP 2200, TLS/TCP 990"  | tee -a /root/log-install.txt
echo "   - SSLH / SSH Websocket    : TCP 443 (TLS multiplex), HTTP 8880"  | tee -a /root/log-install.txt
echo "   - Stunnel5                : TCP 445, 777, 990"  | tee -a /root/log-install.txt
echo "   - Dropbear                : TCP 109, 143, 1153"  | tee -a /root/log-install.txt
echo "   - CloudFront Websocket    : "  | tee -a /root/log-install.txt
echo "   - SSH Websocket TLS       : 443"  | tee -a /root/log-install.txt
echo "   - SSH Websocket HTTP      : 8880"  | tee -a /root/log-install.txt
echo "   - Websocket OpenVPN       : 2086"  | tee -a /root/log-install.txt
echo "   - BadVPN UDPGW            : TCP 7100, 7200, 7300 (loopback gateway)"  | tee -a /root/log-install.txt
echo "   - Nginx                   : 89"  | tee -a /root/log-install.txt
echo "   - Wireguard               : 7070"  | tee -a /root/log-install.txt
echo "   - L2TP/IPsec              : UDP 500, 1701, 4500"  | tee -a /root/log-install.txt
echo "   - PPTP VPN                : 1732"  | tee -a /root/log-install.txt
echo "   - SSTP VPN                : 444"  | tee -a /root/log-install.txt
echo "   - Shadowsocks-R           : 1443-1543"  | tee -a /root/log-install.txt
echo "   - SS-OBFS TLS             : 2443-2543"  | tee -a /root/log-install.txt
echo "   - SS-OBFS HTTP            : 3443-3543"  | tee -a /root/log-install.txt
echo "   - XRAYS Vmess TLS         : 8443"  | tee -a /root/log-install.txt
echo "   - XRAYS Vmess None TLS    : 80"  | tee -a /root/log-install.txt
echo "   - XRAYS Vless TLS         : 8444"  | tee -a /root/log-install.txt
echo "   - XRAYS Vless None TLS    : 81"  | tee -a /root/log-install.txt
echo "   - XRAYS Trojan            : 2083"  | tee -a /root/log-install.txt
echo "   - XRAYS VMESS/VLESS GRPC  : OFF (upstream reports broken)"  | tee -a /root/log-install.txt
echo "   - OHP SSH                 : 8181"  | tee -a /root/log-install.txt
echo "   - OHP Dropbear            : 8282"  | tee -a /root/log-install.txt
echo "   - OHP OpenVPN             : 8383"  | tee -a /root/log-install.txt
echo "   - TrojanGo                : 2087"  | tee -a /root/log-install.txt
echo "   - UDP Custom              : UDP 1-65535 by default; excludes 500, 1701, 2200, 4500, 7070; config listener defaults to 36712" | tee -a /root/log-install.txt
echo ""  | tee -a /root/log-install.txt
echo "   >>> Server Information & Other Features"  | tee -a /root/log-install.txt
echo "   - Timezone                : Asia/Kuala_Lumpur (GMT +8)"  | tee -a /root/log-install.txt
echo "   - Fail2Ban                : [ON]"  | tee -a /root/log-install.txt
echo "   - Dflate                  : [ON]"  | tee -a /root/log-install.txt
echo "   - IPtables                : [ON]"  | tee -a /root/log-install.txt
echo "   - Auto-Reboot             : [ON]"  | tee -a /root/log-install.txt
echo "   - IPv6                    : preserved (not disabled by installer)"  | tee -a /root/log-install.txt
echo "   - Autoreboot On 05.00 GMT +8" | tee -a /root/log-install.txt
echo "   - Autobackup Data" | tee -a /root/log-install.txt
echo "   - Restore Data" | tee -a /root/log-install.txt
echo "   - Auto Delete Expired Account" | tee -a /root/log-install.txt
echo "   - Full Orders For Various Services" | tee -a /root/log-install.txt
echo "   - White Label" | tee -a /root/log-install.txt
echo "   - Installation Log --> /root/log-install.txt"  | tee -a /root/log-install.txt
echo ""
echo ""

verify_ssh_access() {
	local effective setting port
	if ! command -v sshd >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then
		report_error "SSH verification tools are missing (sshd or ss)."
		return 1
	fi
	if ! sshd -t; then
		report_error "OpenSSH configuration validation failed; VPS will not be rebooted."
		return 1
	fi
	if ! systemctl is-active --quiet ssh; then
		report_error "OpenSSH service is not active; VPS will not be rebooted."
		return 1
	fi
	effective=$(sshd -T 2>/dev/null) || {
		report_error "Could not read effective OpenSSH settings; VPS will not be rebooted."
		return 1
	}
	for setting in 'permitrootlogin yes' 'passwordauthentication yes' 'pubkeyauthentication yes' 'port 22' 'port 2253'; do
		if ! printf '%s\n' "$effective" | grep -Fxq "$setting"; then
			report_error "Required OpenSSH setting is not active: $setting. VPS will not be rebooted."
			return 1
		fi
	done
	for port in 22 2253; do
		if ! ss -H -ltn | awk -v p="$port" '$4 ~ (":" p "$") && $4 !~ /^127\.0\.0\.1:/ && $4 !~ /^\[::1\]:/ && $4 !~ /^::1:/ { found=1 } END { exit !found }'; then
			report_error "OpenSSH is not listening on public-capable TCP port $port. VPS will not be rebooted."
			return 1
		fi
	done
	for port in 22 2253; do
		if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
			report_error "Host firewall is not allowing TCP port $port. VPS will not be rebooted."
			return 1
		fi
	done
	return 0
}

if ! verify_ssh_access; then
	exit 1
fi
if passwd -S root 2>/dev/null | awk '$2 == "L" || $2 == "NP" { locked=1 } END { exit !locked }'; then
	report_error "Warning: root has no usable password; password login cannot work until you set one in the VPS console. SSH key access may still work."
fi

source_commit=${SSH_ONE_SOURCE_COMMIT:-unknown}
if [[ ! $source_commit =~ ^[a-f0-9]{40}$ ]]; then source_commit='unknown'; fi
printf '%s\n' "$source_commit" > /etc/ssh-one/.source-commit.new || { report_error "Could not prepare the GitHub source reference."; exit 1; }
chmod 0644 /etc/ssh-one/.source-commit.new || { report_error "Could not set permissions on the GitHub source reference."; exit 1; }
mv -fT -- /etc/ssh-one/.source-commit.new /etc/ssh-one/source-commit || { report_error "Could not activate the GitHub source reference."; exit 1; }
printf 'v25\n' > /etc/ssh-one/.installation-complete.new || { report_error "Could not prepare the installation marker."; exit 1; }
mv -fT -- /etc/ssh-one/.installation-complete.new /etc/ssh-one/installation-complete || { report_error "Could not activate the installation marker."; exit 1; }
rm -f /etc/ssh-one/install-in-progress || { report_error "Could not remove the installation-in-progress marker."; exit 1; }
printf 'Installation complete. SSH config and TCP 22/2253 listeners passed checks. VPS will reboot in 10 seconds.\n' | tee -a /root/log-install.txt
for remaining in {10..1}; do
	printf '\rRestarting VPS in %2d seconds...' "$remaining"
	sleep 1
done
printf '\nRebooting VPS now.\n' | tee -a /root/log-install.txt
if ! systemctl reboot; then
	report_error "systemctl reboot failed; attempting /sbin/reboot."
	if [ -x /sbin/reboot ]; then
		/sbin/reboot
	else
		exit 1
	fi
fi
