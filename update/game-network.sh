#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 022

fail() { printf 'BadVPN setup: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail 'run as root.'
for tool in systemctl ss awk grep mktemp mv rm cp chmod chown install pkill sleep; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done

base=ssh-one-badvpn-udpgw
template=/etc/systemd/system/ssh-one-badvpn-udpgw@.service
legacy=/etc/systemd/system/ssh-one-badvpn-udpgw.service
description='Description=SSH-one BadVPN UDP gateway on loopback port %i'
legacy_description='Description=SSH-one BadVPN UDP gateway for compatible SSH clients'

stop_legacy() {
  [[ -e $legacy || -L $legacy ]] || return 0
  [[ -f $legacy && ! -L $legacy ]] || fail "unexpected path: $legacy"
  grep -Fqx "$legacy_description" "$legacy" && grep -Fq 'ExecStart=/usr/bin/badvpn-udpgw' "$legacy" ||
    fail 'the legacy BadVPN unit does not match SSH-one; it was left unchanged.'
  if ! systemctl disable --now "$base.service" >/dev/null 2>&1 && systemctl is-active --quiet "$base.service"; then
    fail 'could not stop the legacy BadVPN unit.'
  fi
  rm -f -- "$legacy" "/etc/systemd/system/multi-user.target.wants/$base.service"
  systemctl daemon-reload || fail 'systemd reload failed after removing the legacy BadVPN unit.'
}

stop_old_processes() {
  pkill -f '(^|/)badvpn-udpgw --listen-addr 127\.0\.0\.1:(7100|7200|7300)( |$)' >/dev/null 2>&1 || true
  sleep 1
}

stop_instances() {
  local port unit
  for port in 7100 7200 7300; do
    unit="$base@$port.service"
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$unit" && fail "could not stop $unit."
  done
}

clean_legacy_rc_local() {
  local rc=/etc/rc.local backup=/etc/ssh-one/backups/rc.local.pre-badvpn-v2 tmp
  [[ -f $rc && ! -L $rc ]] || return 0
  grep -Eq 'screen -dmS badvpn badvpn-udpgw --listen-addr 127\.0\.0\.1:(7100|7200|7300) --max-clients (500|1000)' "$rc" || return 0
  install -d -m 0700 /etc/ssh-one/backups || fail 'could not create a backup directory for /etc/rc.local.'
  [[ -e $backup ]] || cp -a -- "$rc" "$backup" || fail 'could not back up /etc/rc.local.'
  tmp=$(mktemp /etc/rc.local.ssh-one.XXXXXX) || fail 'could not stage /etc/rc.local.'
  awk '!/screen -dmS badvpn badvpn-udpgw --listen-addr 127\.0\.0\.1:(7100|7200|7300) --max-clients (500|1000)/ { print }' "$rc" > "$tmp" ||
    { rm -f -- "$tmp"; fail 'could not remove old BadVPN startup lines from /etc/rc.local.'; }
  chmod --reference="$rc" "$tmp"
  chown --reference="$rc" "$tmp"
  mv -fT -- "$tmp" "$rc" || { rm -f -- "$tmp"; fail 'could not update /etc/rc.local.'; }
}

write_template() {
  local tmp
  if [[ -e $template || -L $template ]]; then
    [[ -f $template && ! -L $template ]] || fail "unexpected path: $template"
    grep -Fqx "$description" "$template" &&
      grep -Fq 'ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:%i --max-clients 500' "$template" ||
      fail 'the existing BadVPN template is unrelated or modified; it was left unchanged.'
  fi
  tmp=$(mktemp /etc/systemd/system/.ssh-one-badvpn-udpgw.XXXXXX) || fail 'could not stage the BadVPN template.'
  cat > "$tmp" <<'UNIT'
[Unit]
Description=SSH-one BadVPN UDP gateway on loopback port %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:%i --max-clients 500
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
  mv -fT -- "$tmp" "$template" || fail 'could not install the BadVPN template.'
}

apply_services() {
  [[ -x /usr/bin/badvpn-udpgw ]] || fail 'BadVPN binary is missing at /usr/bin/badvpn-udpgw.'
  stop_legacy
  stop_instances
  stop_old_processes
  clean_legacy_rc_local
  write_template
  systemctl daemon-reload || fail 'systemd could not load the BadVPN template.'
  for port in 7100 7200 7300; do
    systemctl enable --now "$base@$port.service" >/dev/null ||
      fail "could not start the independent BadVPN listener at 127.0.0.1:$port."
    systemctl is-active --quiet "$base@$port.service" ||
      fail "BadVPN listener at 127.0.0.1:$port is not active."
    ss -H -ltn | awk -v p="127.0.0.1:$port" '$4 == p { found=1 } END { exit !found }' ||
      fail "BadVPN is not listening at 127.0.0.1:$port."
  done
  printf 'BadVPN is running as three separate listeners on loopback TCP 7100, 7200, and 7300.\n'
}

show_status() {
  for port in 7100 7200 7300; do
    printf '\n--- %s@%s.service ---\n' "$base" "$port"
    systemctl --no-pager --full status "$base@$port.service" || true
  done
}

remove_services() {
  stop_legacy
  for port in 7100 7200 7300; do
    unit="$base@$port.service"
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$unit" && fail "could not stop $unit; its unit files were retained."
  done
  stop_old_processes
  clean_legacy_rc_local
  if [[ -e $template || -L $template ]]; then
    [[ -f $template && ! -L $template ]] || fail "unexpected path: $template"
    grep -Fqx "$description" "$template" &&
      grep -Fq 'ExecStart=/usr/bin/badvpn-udpgw --listen-addr 127.0.0.1:%i --max-clients 500' "$template" ||
      fail 'BadVPN template verification failed; it was left in place.'
    rm -f -- "$template"
  fi
  systemctl daemon-reload || fail 'systemd reload failed after removing BadVPN.'
  printf 'SSH-one BadVPN listeners and verified systemd units were removed.\n'
}

action=apply
[[ $# -eq 0 ]] || action=$1
case "$action" in
  apply|repair) apply_services ;;
  restart)
    for port in 7100 7200 7300; do systemctl restart "$base@$port.service" || fail "could not restart BadVPN on port $port."; done
    printf 'Three BadVPN listeners restarted.\n'
    ;;
  status) show_status ;;
  remove) remove_services ;;
  *) fail "unknown action '$action'; use apply, restart, status, or remove." ;;
esac
