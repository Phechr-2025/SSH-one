#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
umask 077

fail() { printf 'SSH access update: %s\n' "$*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || fail 'run as root.'
for tool in awk chmod chown cp grep install iptables mktemp mv netfilter-persistent rm ss sshd systemctl; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."
done

config=/etc/ssh/sshd_config
backup_dir=/etc/ssh-one/backups
backup=/etc/ssh-one/backups/sshd_config.pre-v28
[[ -f $config && ! -L $config && -s $config ]] || fail "OpenSSH config is missing, empty, or not a regular file: $config"
install -d -m 0700 "$backup_dir" || fail 'could not create the SSH config backup directory.'
if [[ ! -e $backup && ! -L $backup ]]; then
  cp -a -- "$config" "$backup" || fail 'could not back up the current OpenSSH config.'
fi
[[ -f $backup && ! -L $backup ]] || fail 'the v28 OpenSSH backup path exists but is not a regular file.'
rollback_backup=$(mktemp "$backup_dir/sshd_config.v28.rollback.XXXXXX") || fail 'could not stage a rollback copy of the active OpenSSH config.'
cp -a -- "$config" "$rollback_backup" || { rm -f -- "$rollback_backup"; fail 'could not save the active OpenSSH config for rollback.'; }

tmp=$(mktemp /etc/ssh/sshd_config.ssh-one-v28.XXXXXX) || fail 'could not stage the OpenSSH config.'
{
  cat <<'SSH_ONE_ACCESS'
# BEGIN SSH-one managed access settings
Port 22
Port 2253
Port 42
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
# END SSH-one managed access settings
SSH_ONE_ACCESS
  awk '
    /^# BEGIN SSH-one managed access settings$/ { skip=1; next }
    /^# END SSH-one managed access settings$/ { skip=0; next }
    !skip { print }
  ' "$config"
} > "$tmp" || { rm -f -- "$tmp"; fail 'could not prepare the OpenSSH config.'; }
chmod --reference="$config" "$tmp" || { rm -f -- "$tmp"; fail 'could not preserve the OpenSSH config mode.'; }
chown --reference="$config" "$tmp" || { rm -f -- "$tmp"; fail 'could not preserve the OpenSSH config owner.'; }
mv -fT -- "$tmp" "$config" || { rm -f -- "$tmp"; fail 'could not activate the OpenSSH config.'; }

added_ipv4=0
added_ipv6=0
restore() {
  cp -a -- "$rollback_backup" "$config" || printf 'SSH access update: could not restore %s\n' "$config" >&2
  systemctl restart ssh >/dev/null 2>&1 || true
  if (( added_ipv4 )); then
    while iptables -w -C INPUT -p tcp --dport 42 -j ACCEPT 2>/dev/null; do
      iptables -w -D INPUT -p tcp --dport 42 -j ACCEPT || break
    done
  fi
  if (( added_ipv6 )); then
    while ip6tables -w -C INPUT -p tcp --dport 42 -j ACCEPT 2>/dev/null; do
      ip6tables -w -D INPUT -p tcp --dport 42 -j ACCEPT || break
    done
  fi
  netfilter-persistent save >/dev/null 2>&1 || true
}

if ! sshd -t -f "$config"; then
  restore
  fail 'sshd rejected the updated config; the previous config was restored.'
fi
effective=$(sshd -T -f "$config" 2>/dev/null) || { restore; fail 'could not read the effective OpenSSH settings.'; }
for setting in 'port 22' 'port 2253' 'port 42' 'permitrootlogin yes' 'passwordauthentication yes' 'pubkeyauthentication yes'; do
  if ! printf '%s\n' "$effective" | grep -Fxq "$setting"; then
    restore
    fail "required OpenSSH setting is missing: $setting"
  fi
done

if ! iptables -w -C INPUT -p tcp --dport 42 -j ACCEPT 2>/dev/null; then
  iptables -w -I INPUT 1 -p tcp --dport 42 -j ACCEPT || { restore; fail 'could not allow TCP port 42 in the IPv4 host firewall.'; }
  added_ipv4=1
fi
if command -v ip6tables >/dev/null 2>&1 && ip6tables -S INPUT >/dev/null 2>&1 &&
   ! ip6tables -w -C INPUT -p tcp --dport 42 -j ACCEPT 2>/dev/null; then
  ip6tables -w -I INPUT 1 -p tcp --dport 42 -j ACCEPT || { restore; fail 'could not allow TCP port 42 in the IPv6 host firewall.'; }
  added_ipv6=1
fi
netfilter-persistent save >/dev/null || { restore; fail 'could not save the SSH firewall rule.'; }
systemctl restart ssh || { restore; fail 'OpenSSH failed to restart; the previous config was restored.'; }
systemctl is-active --quiet ssh || { restore; fail 'OpenSSH is not active after restart; the previous config was restored.'; }
for port in 22 2253 42; do
  if ! ss -H -ltn | awk -v p="$port" '$4 ~ (":" p "$") && $4 !~ /^127\.0\.0\.1:/ && $4 !~ /^\[::1\]:/ && $4 !~ /^::1:/ { found=1 } END { exit !found }'; then
    restore
    fail "OpenSSH is not listening on a non-loopback address at TCP port $port; the previous config was restored."
  fi
done
rm -f -- "$rollback_backup"
printf 'OpenSSH is active on TCP 22, 2253, and 42. Allow TCP 42 in the VPS provider firewall/security group too.\n'
