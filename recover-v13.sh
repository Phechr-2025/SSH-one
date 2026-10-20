#!/usr/bin/env bash
set -Eeuo pipefail

log_file=/root/log-install.txt
unit_file=/etc/systemd/system/autosett.service

log_message() {
	printf 'SSH-one recovery: %s\n' "$*" | tee -a "$log_file"
}

fail() {
	printf 'SSH-one recovery: %s\n' "$*" | tee -a "$log_file" >&2
	exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run this recovery script as root.'
touch "$log_file" || fail "cannot write $log_file."
printf '\n==== SSH-one v13 recovery attempt: %s ====\n' "$(date -Is)" >> "$log_file"

[[ -s /etc/xray/domain ]] || fail 'this does not look like a v13 partial install: /etc/xray/domain is missing.'
[[ ! -e /etc/ssh-one/installation-complete ]] || fail 'installation is already marked complete; recovery is not needed.'
if [[ -f "$unit_file" ]] && ! grep -Fqx 'ExecStart=/bin/bash /etc/set.sh' "$unit_file"; then
	fail "$unit_file does not match the broken v13 autosett unit; left it unchanged."
fi

log_message 'Removing the broken autosett unit that references missing /etc/set.sh.'
systemctl disable --now autosett.service >/dev/null 2>&1 || true
rm -f "$unit_file" /etc/set.sh /etc/systemd/system/multi-user.target.wants/autosett.service
systemctl daemon-reload || fail 'systemd could not reload after removing autosett.'
systemctl reset-failed autosett.service >/dev/null 2>&1 || true

command -v sshd >/dev/null 2>&1 || fail 'sshd is missing; VPS will not reboot.'
command -v ss >/dev/null 2>&1 || fail 'ss is missing; VPS will not reboot.'
command -v iptables >/dev/null 2>&1 || fail 'iptables is missing; VPS will not reboot.'
sshd -t || fail 'OpenSSH configuration is invalid; VPS will not reboot.'
systemctl is-active --quiet ssh || fail 'OpenSSH is not active; VPS will not reboot.'

effective=$(sshd -T 2>/dev/null) || fail 'could not read effective OpenSSH settings; VPS will not reboot.'
for setting in 'permitrootlogin yes' 'passwordauthentication yes' 'pubkeyauthentication yes' 'port 22' 'port 2253'; do
	if ! printf '%s\n' "$effective" | grep -Fxq "$setting"; then
		fail "required OpenSSH setting is not active: $setting. VPS will not reboot."
	fi
done

for port in 22 2253; do
	if ! ss -H -ltn | awk -v p="$port" '{ n=split($4, parts, ":"); if (parts[n] == p && $4 !~ /^127\.0\.0\.1:/ && $4 !~ /^\[::1\]:/ && $4 !~ /^::1:/) found=1 } END { exit !found }'; then
		fail "OpenSSH is not listening on a public-capable TCP port $port. VPS will not reboot."
	fi
	if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
		fail "host firewall is not allowing TCP port $port. VPS will not reboot."
	fi
done

if passwd -S root 2>/dev/null | awk '$2 == "L" || $2 == "NP" { locked=1 } END { exit !locked }'; then
	log_message 'Warning: root password is locked or unset. Confirm SSH key access or set a root password in the VPS provider console before relying on password login.'
fi

printf 'v14-recovered-v13\n' > /etc/ssh-one/installation-complete || fail 'could not write the installation marker.'
log_message 'SSH checks passed. VPS will reboot in 10 seconds; confirm the provider firewall allows TCP 22 or 2253.'
for remaining in {10..1}; do
	printf '\rRestarting VPS in %2d seconds...' "$remaining"
	sleep 1
done
printf '\nRebooting VPS now.\n' | tee -a "$log_file"
if ! systemctl reboot; then
	log_message 'systemctl reboot failed; attempting /sbin/reboot.'
	if [[ -x /sbin/reboot ]]; then
		/sbin/reboot
	else
		fail '/sbin/reboot is unavailable.'
	fi
fi
