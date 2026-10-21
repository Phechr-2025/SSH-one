#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() {
  printf 'SSH-one recovery: %s\n' "$*" >&2
  if [[ -w /root/log-install.txt ]]; then printf 'SSH-one recovery: %s\n' "$*" >> /root/log-install.txt; fi
  exit 1
}
note() {
  printf 'SSH-one recovery: %s\n' "$*"
  printf 'SSH-one recovery: %s\n' "$*" >> /root/log-install.txt
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run this command as root.'
[[ -r /etc/ssh-one/install-in-progress ]] || fail 'the v18 incomplete-install marker was not found.'
[[ ! -e /etc/ssh-one/installation-complete ]] || fail 'SSH-one is already marked as installed; use ssh-one-update instead.'
grep -Eq '^v18 started at ' /etc/ssh-one/install-in-progress ||
  fail 'this recovery only handles a v18 install stopped during final command setup.'
[[ -r /etc/ssh-one/repository.conf ]] || fail 'saved repository settings are missing.'
for tool in curl unzip sha256sum flock; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done

install -d -m 0755 /run/lock
exec 9>/run/lock/ssh-one-install.lock || fail 'could not create the installer lock.'
flock -n 9 || fail 'another SSH-one installation, recovery, or update is running.'

read_setting() {
  local key=$1 file=$2
  sed -n "s/^$key='\\([^']*\\)'$/\\1/p" "$file"
}
repo_owner=$(read_setting SSH_ONE_OWNER /etc/ssh-one/repository.conf)
repo_name=$(read_setting SSH_ONE_NAME /etc/ssh-one/repository.conf)
repo_branch=$(read_setting SSH_ONE_BRANCH /etc/ssh-one/repository.conf)
[[ $repo_owner =~ ^[A-Za-z0-9-]+$ ]] || fail 'saved GitHub owner is invalid.'
[[ $repo_name =~ ^[A-Za-z0-9._-]+$ ]] || fail 'saved GitHub repository name is invalid.'
[[ $repo_branch =~ ^[A-Za-z0-9._/-]+$ && $repo_branch != *..* ]] || fail 'saved Git branch is invalid.'

work_dir=$(mktemp -d /tmp/ssh-one-recovery.XXXXXX) || fail 'could not create a temporary directory.'
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT
archive="$work_dir/source.zip"
extract_dir="$work_dir/extracted"
mkdir -p "$extract_dir"
curl --fail --location --retry 3 --silent --show-error \
  "https://codeload.github.com/${repo_owner}/${repo_name}/zip/refs/heads/${repo_branch}" \
  -o "$archive" || fail 'could not download the saved repository archive.'
unzip -q "$archive" -d "$extract_dir" || fail 'the repository archive could not be extracted.'
mapfile -t version_files < <(find "$extract_dir" -mindepth 2 -maxdepth 3 -type f -name VERSION -print)
(( ${#version_files[@]} == 1 )) || fail 'the archive must contain exactly one VERSION file.'
repo_root=${version_files[0]%/VERSION}
[[ -r $repo_root/repository.conf && -r $repo_root/update/install-managed-files.sh ]] ||
  fail 'the archive is missing repository settings or the command installer.'

downloaded_owner=$(read_setting SSH_ONE_OWNER "$repo_root/repository.conf")
downloaded_name=$(read_setting SSH_ONE_NAME "$repo_root/repository.conf")
downloaded_branch=$(read_setting SSH_ONE_BRANCH "$repo_root/repository.conf")
[[ $downloaded_owner == "$repo_owner" && $downloaded_name == "$repo_name" && $downloaded_branch == "$repo_branch" ]] ||
  fail 'repository settings in the archive do not match the saved settings on this VPS.'
release_version=$(tr -d '\r\n' < "$repo_root/VERSION")
[[ $release_version =~ ^v[0-9]+$ && ${release_version#v} -ge 19 ]] ||
  fail 'the repository does not contain a recovery-capable v19 or newer release.'

note "repairing the managed command inventory from $release_version; installed VPN services and user data will not be reinstalled."
bash "$repo_root/update/install-managed-files.sh" || fail 'managed command setup failed; the incomplete marker was kept so recovery can be retried.'
[[ -x /usr/bin/menu ]] && /usr/bin/menu --check >/dev/null || fail 'the installed menu did not pass its startup check.'

if ! command -v sshd >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1; then
  fail 'SSH verification tools are missing; the VPS will not be rebooted.'
fi
sshd -t || fail 'OpenSSH configuration validation failed; the VPS will not be rebooted.'
systemctl is-active --quiet ssh || fail 'OpenSSH is not active; the VPS will not be rebooted.'
effective=$(sshd -T 2>/dev/null) || fail 'could not read effective OpenSSH settings; the VPS will not be rebooted.'
for setting in 'permitrootlogin yes' 'passwordauthentication yes' 'pubkeyauthentication yes' 'port 22' 'port 2253'; do
  printf '%s\n' "$effective" | grep -Fxq "$setting" || fail "required OpenSSH setting is not active: $setting. The VPS will not be rebooted."
done
for port in 22 2253; do
  if ! ss -H -ltn | grep -Eq ":${port}[[:space:]]"; then
    fail "OpenSSH is not listening on public-capable TCP port $port; the VPS will not be rebooted."
  fi
  iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null ||
    fail "the host firewall is not allowing TCP port $port; the VPS will not be rebooted."
done

if [[ ! -s /etc/ssh-one/host ]]; then
  host=
  for host_file in /etc/xray/domain /etc/v2ray/domain /root/domain; do
    [[ -r $host_file ]] || continue
    candidate=$(tr -d '\r\n' < "$host_file")
    if [[ $candidate == *.* && $candidate =~ ^[A-Za-z0-9.-]+$ ]]; then
      host=${candidate,,}
      break
    fi
  done
  [[ -n $host ]] || fail 'the configured host could not be recovered from the existing service files.'
  printf '%s\n' "$host" > /etc/ssh-one/.host.new || fail 'could not save the recovered host name.'
  mv -fT -- /etc/ssh-one/.host.new /etc/ssh-one/host || fail 'could not activate the recovered host name.'
fi

printf '%s\n' "$release_version" > /etc/ssh-one/.installation-complete.new || fail 'could not prepare the installation marker.'
chmod 0644 /etc/ssh-one/.installation-complete.new
mv -fT -- /etc/ssh-one/.installation-complete.new /etc/ssh-one/installation-complete || fail 'could not activate the installation marker.'
rm -f -- /etc/ssh-one/install-in-progress || fail 'could not remove the incomplete-install marker.'
note "recovery completed. SSH config, listeners, and menu passed checks. VPS will reboot in 10 seconds."
for remaining in {10..1}; do
  printf '\rRestarting VPS in %2d seconds...' "$remaining"
  sleep 1
done
printf '\nRebooting VPS now.\n'
if ! systemctl reboot; then
  note 'systemctl reboot failed; attempting /sbin/reboot.'
  [[ -x /sbin/reboot ]] && /sbin/reboot || fail 'could not restart the VPS.'
fi
