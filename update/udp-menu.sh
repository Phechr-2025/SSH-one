#!/usr/bin/env bash

set -Eeuo pipefail
export LC_ALL=C

fail() {
  printf 'SSH-one UDP: %s\n' "$*" >&2
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  fail 'Run this menu as root.'
  exit 1
fi

repo_owner='Phechr-2025'
repo_name='SSH-one'
repo_branch='main'
repo_config=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
if [[ -r $repo_config ]]; then
  # This root-owned file is created by the SSH-one installer.
  # shellcheck disable=SC1090
  . "$repo_config"
  repo_owner=${SSH_ONE_OWNER:-$repo_owner}
  repo_name=${SSH_ONE_NAME:-$repo_name}
  repo_branch=${SSH_ONE_BRANCH:-$repo_branch}
fi

if [[ ! $repo_owner =~ ^[A-Za-z0-9-]+$ || ! $repo_name =~ ^[A-Za-z0-9._-]+$ || ! $repo_branch =~ ^[A-Za-z0-9._/-]+$ || $repo_branch == *..* ]]; then
  fail 'The saved GitHub repository settings are invalid. Check /etc/ssh-one/repository.conf.'
  exit 1
fi

raw_base="https://raw.githubusercontent.com/${repo_owner}/${repo_name}/${repo_branch}"
udp_group='ssh-one-udp'
pause() {
  local unused
  read -r -p 'Press Enter to continue...' unused || true
}

show_status() {
  local service state listen='unknown'
  printf '\nUDP Custom service status\n'
  for service in udp-custom.service udpgw.service; do
    if systemctl is-active --quiet "$service"; then state='active'; else state='inactive'; fi
    printf '  %-20s %s\n' "$service" "$state"
  done
  if [[ -r /root/udp/config.json ]]; then
    listen=$(sed -n 's/.*"listen"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /root/udp/config.json | head -n 1)
    [[ -n $listen ]] || listen='unknown'
    printf '  Server listen address: %s/UDP\n' "$listen"
  else
    printf '  UDP Custom config: not found\n'
  fi
  if [[ -x /root/udp/udp-custom ]]; then
    printf '  UDP Custom binary: installed\n'
  else
    printf '  UDP Custom binary: missing\n'
  fi
  printf '\n'
  pause
}

install_udp() {
  local answer tmp
  if [[ -x /root/udp/udp-custom && -f /etc/systemd/system/udp-custom.service && -f /etc/systemd/system/udpgw.service ]]; then
    printf 'UDP Custom is already installed. Reinstall/repair it now? Existing /root/udp/config.json will be preserved. [y/N] '
    read -r answer || return 0
    [[ ${answer,,} == y || ${answer,,} == yes ]] || return 0
  else
    printf 'Install UDP Custom now? The default SSH-one installation already installs it automatically. [y/N] '
    read -r answer || return 0
    [[ ${answer,,} == y || ${answer,,} == yes ]] || return 0
  fi

  command -v curl >/dev/null 2>&1 || { fail 'curl is required. Install it with: apt-get install -y curl'; return 1; }
  tmp=$(mktemp -d /tmp/ssh-one-udp-menu.XXXXXX) || { fail 'Could not create a temporary directory.'; return 1; }
  if ! curl --fail --location --retry 3 --silent --show-error \
    "$raw_base/udp-custom/install.sh" -o "$tmp/install.sh"; then
    rm -rf -- "$tmp"
    fail 'Could not download the UDP Custom installer. Check outbound HTTPS and repository settings.'
    return 1
  fi
  if bash "$tmp/install.sh"; then
    rm -rf -- "$tmp"
    printf 'UDP Custom installation/repair completed.\n'
  else
    rm -rf -- "$tmp"
    fail 'UDP Custom installation failed. Review the error above and /root/log-install.txt.'
    return 1
  fi
  pause
}

normalize_ports() {
  local raw=$1 token first last start end
  local -a tokens
  normalized_ports=()
  raw=${raw//[[:space:]]/}
  raw=${raw//-/:}
  if [[ -z $raw || $raw == ,* || $raw == *, || $raw == *,,* ]]; then
    fail 'Enter a non-empty comma-separated list without empty items.'
    return 1
  fi
  IFS=',' read -r -a tokens <<<"$raw"
  if (( ${#tokens[@]} == 0 || ${#tokens[@]} > 64 )); then
    fail 'Enter between 1 and 64 ports/ranges, separated by commas.'
    return 1
  fi
  for token in "${tokens[@]}"; do
    if [[ ! $token =~ ^([0-9]{1,5})(:([0-9]{1,5}))?$ ]]; then
      fail "Invalid port or range: $token"
      return 1
    fi
    first=${BASH_REMATCH[1]}
    last=${BASH_REMATCH[3]:-$first}
    start=$((10#$first))
    end=$((10#$last))
    if (( start < 1 || end > 65535 || start > end )); then
      fail "Port/range must be within 1-65535 and start must not exceed end: $token"
      return 1
    fi
    if (( start == end )); then
      normalized_ports+=("$start")
    else
      normalized_ports+=("$start:$end")
    fi
  done
}

save_iptables_rules() {
  if command -v netfilter-persistent >/dev/null 2>&1; then
    if netfilter-persistent save; then
      printf 'Firewall rules saved for reboot.\n'
    else
      fail 'Ports were opened in the running firewall, but netfilter-persistent could not save them.'
      return 1
    fi
  elif command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
    if iptables-save > /etc/iptables/rules.v4; then
      chmod 600 /etc/iptables/rules.v4
      printf 'IPv4 firewall rules saved to /etc/iptables/rules.v4.\n'
    else
      fail 'Ports were opened in the running firewall, but the rules could not be saved.'
      return 1
    fi
  else
    fail 'Ports were opened for this session, but no persistent firewall saver is available. Install iptables-persistent to keep them after reboot.'
    return 1
  fi
}

open_ports() {
  local raw_protocol entry proto rule_added=0
  local -a protocols
  printf '\nProtocol [tcp/udp/both]: '
  read -r raw_protocol || return 0
  raw_protocol=${raw_protocol,,}
  case $raw_protocol in
    tcp) protocols=(tcp) ;;
    udp) protocols=(udp) ;;
    both) protocols=(tcp udp) ;;
    *) fail 'Choose tcp, udp, or both.'; pause; return 1 ;;
  esac

  printf 'Ports/ranges (examples: 53,443 or 10000-10100): '
  read -r raw_protocol || return 0
  if ! normalize_ports "$raw_protocol"; then pause; return 1; fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for proto in "${protocols[@]}"; do
      for entry in "${normalized_ports[@]}"; do
        ufw allow "$entry/$proto" || { fail "Could not open $entry/$proto in UFW."; pause; return 1; }
      done
    done
    printf 'Host firewall: UFW\n'
  elif command -v iptables >/dev/null 2>&1; then
    for proto in "${protocols[@]}"; do
      for entry in "${normalized_ports[@]}"; do
        if iptables -w -C INPUT -p "$proto" --dport "$entry" -j ACCEPT 2>/dev/null; then
          printf 'Already allowed by iptables: %s/%s\n' "$entry" "$proto"
        else
          iptables -w -I INPUT 1 -p "$proto" --dport "$entry" -j ACCEPT || { fail "Could not open $entry/$proto in iptables."; pause; return 1; }
          rule_added=1
        fi
      done
    done
    if (( rule_added )); then save_iptables_rules || true; fi
    printf 'Host firewall: iptables\n'
  else
    fail 'Neither active UFW nor iptables is available; no firewall rule was changed.'
    pause
    return 1
  fi
  printf 'Remember to allow these ports/protocols in the VPS provider firewall/security group too. Opening a firewall port does not start a service on that port.\n'
  pause
}

create_udp_user() {
  local username password confirmation
  [[ -x /root/udp/udp-custom ]] || { fail 'UDP Custom is not installed. Choose Install/repair UDP Custom first.'; pause; return 1; }
  printf 'Username (4-32 letters/numbers/._-): '
  read -r username || return 0
  [[ $username =~ ^[A-Za-z0-9][A-Za-z0-9._-]{3,31}$ ]] || { fail 'Username must be 4-32 characters and start with a letter or number.'; pause; return 1; }
  if getent passwd "$username" >/dev/null; then
    fail 'That username already exists. Choose another name.'
    pause
    return 1
  fi
  printf 'Password (8-128 characters; colon is not allowed): '
  IFS= read -r -s password || return 0
  printf '\nConfirm password: '
  IFS= read -r -s confirmation || return 0
  printf '\n'
  if (( ${#password} < 8 || ${#password} > 128 )) || [[ $password == *:* ]] || [[ $password != "$confirmation" ]]; then
    unset password confirmation
    fail 'Passwords must match, contain 8-128 characters, and not contain a colon.'
    pause
    return 1
  fi
  if ! getent group "$udp_group" >/dev/null; then
    groupadd --system "$udp_group" || { unset password confirmation; fail 'Could not create the UDP account group.'; pause; return 1; }
  fi
  if ! useradd -M -s /bin/false -G "$udp_group" "$username"; then
    unset password confirmation
    fail 'Could not create the system account.'
    pause
    return 1
  fi
  if ! printf '%s:%s\n' "$username" "$password" | chpasswd; then
    userdel "$username" >/dev/null 2>&1 || true
    unset password confirmation
    fail 'Could not set the account password; the incomplete account was removed.'
    pause
    return 1
  fi
  unset password confirmation
  printf 'UDP Custom account created: %s\n' "$username"
  printf 'Use this username/password with a client that supports UDP Custom. The default server port is 36712/UDP.\n'
  pause
}

list_udp_users() {
  local members username
  if ! getent group "$udp_group" >/dev/null; then
    printf 'No SSH-one UDP Custom accounts have been created from this menu.\n'
    pause
    return 0
  fi
  members=$(getent group "$udp_group" | awk -F: '{print $4}')
  if [[ -z $members ]]; then
    printf 'No SSH-one UDP Custom accounts have been created from this menu.\n'
  else
    printf '\nUDP Custom accounts managed by this menu:\n'
    IFS=',' read -r -a user_list <<<"$members"
    for username in "${user_list[@]}"; do printf '  %s\n' "$username"; done
  fi
  pause
}

delete_udp_user() {
  local username answer
  printf 'Username to delete (only accounts created in this UDP menu): '
  read -r username || return 0
  if ! getent passwd "$username" >/dev/null || ! id -nG "$username" | tr ' ' '\n' | grep -Fxq "$udp_group"; then
    fail 'That account is not managed by the SSH-one UDP menu.'
    pause
    return 1
  fi
  printf 'Delete UDP account %s? This disconnects its running processes. [y/N] ' "$username"
  read -r answer || return 0
  [[ ${answer,,} == y || ${answer,,} == yes ]] || return 0
  pkill -KILL -u "$username" 2>/dev/null || true
  if userdel "$username"; then
    printf 'Account deleted: %s\n' "$username"
  else
    fail "Could not delete account: $username"
  fi
  pause
}

restart_udp() {
  if ! systemctl list-unit-files udp-custom.service udpgw.service --no-legend 2>/dev/null | grep -q 'udp-custom\|udpgw'; then
    fail 'UDP Custom service units are not installed. Choose Install/repair UDP Custom first.'
    pause
    return 1
  fi
  if systemctl restart udp-custom.service udpgw.service; then
    printf 'UDP Custom services restarted.\n'
    systemctl --no-pager --full status udp-custom.service udpgw.service || true
  else
    fail 'Could not restart one or more UDP Custom services.'
  fi
  pause
}

while true; do
  clear 2>/dev/null || true
  printf '%s\n' '================ SSH-one UDP & Port Menu ================'
  printf '%s\n' '1. Check UDP Custom service status'
  printf '%s\n' '2. Install/repair UDP Custom'
  printf '%s\n' '3. Open port(s) in host firewall (TCP, UDP, or both)'
  printf '%s\n' '4. Create UDP Custom account'
  printf '%s\n' '5. List UDP Custom accounts'
  printf '%s\n' '6. Delete UDP Custom account'
  printf '%s\n' '7. Restart UDP Custom services'
  printf '%s\n' '0. Back to main menu'
  printf '%s\n' '=========================================================='
  read -r -p 'Select an option: ' choice || exit 0
  case $choice in
    1) show_status ;;
    2) install_udp || true ;;
    3) open_ports || true ;;
    4) create_udp_user || true ;;
    5) list_udp_users ;;
    6) delete_udp_user || true ;;
    7) restart_udp || true ;;
    0) exit 0 ;;
    *) fail 'Invalid option.'; pause ;;
  esac
done
