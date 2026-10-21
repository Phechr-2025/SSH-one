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
default_udp_exclusions='500,1701,2200,4500,7070'
# Keep action call sites simple while returning to the menu immediately.
pause() {
  :
}

wait_for_udp_custom() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if systemctl is-active --quiet udp-custom.service; then
      sleep 1
      systemctl is-active --quiet udp-custom.service && return 0
    else
      sleep 1
    fi
  done
  return 1
}

current_udp_exclusions() {
  local configured=''
  if [[ -r /etc/ssh-one/udp-exclude-ports ]]; then
    tr -d '\r\n' < /etc/ssh-one/udp-exclude-ports
    return
  fi
  if [[ -r /etc/systemd/system/udp-custom.service ]]; then
    configured=$(sed -n 's|^ExecStart=/root/udp/udp-custom server -exclude ||p' /etc/systemd/system/udp-custom.service | head -n 1)
  fi
  printf '%s' "${configured:-$default_udp_exclusions}"
}

ensure_python3() {
  command -v python3 >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || return 1
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y --no-install-recommends python3
}

read_listener_port() {
  python3 - /root/udp/config.json <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        listen = json.load(stream).get('listen', '')
    match = re.fullmatch(r'.*:([0-9]{1,5})', listen)
    if not match or not 1 <= int(match.group(1)) <= 65535:
        raise ValueError('unsupported listen address')
    print(int(match.group(1)))
except Exception as error:
    print(f'Could not read the UDP Custom listener port: {error}', file=sys.stderr)
    sys.exit(1)
PY
}

show_status() {
  local service state listen='unknown' members='' account_count=0 exclusions='none'
  printf '\nUDP Custom service status\n'
  service=udp-custom.service
  if systemctl is-active --quiet "$service"; then state='active'; else state='inactive'; fi
  printf '  %-20s %s\n' "$service" "$state"
  exclusions=$(current_udp_exclusions)
  [[ -n $exclusions ]] || exclusions='none'
  printf '  UDP Custom excluded ports: %s\n' "$exclusions"
  if getent group "$udp_group" >/dev/null 2>&1; then
    members=$(getent group "$udp_group" | awk -F: 'NR == 1 { print $4 }')
    if [[ -n $members ]]; then
      local -a udp_accounts=()
      IFS=',' read -r -a udp_accounts <<< "$members"
      account_count=${#udp_accounts[@]}
    fi
  fi
  printf '  SSH UDP Custom accounts: %s (managed by this menu)\n' "$account_count"
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
  local answer tmp installer_url
  if [[ -x /root/udp/udp-custom && -f /etc/systemd/system/udp-custom.service ]]; then
    printf 'UDP Custom is already installed. Reinstall/repair it now? Existing /root/udp/config.json will be preserved. [y/N] '
    read -r answer || return 0
    [[ ${answer,,} == y || ${answer,,} == yes ]] || return 0
  else
    printf 'Install UDP Custom now? The default SSH-one installation already installs it automatically. [y/N] '
    read -r answer || return 0
    [[ ${answer,,} == y || ${answer,,} == yes ]] || return 0
  fi

  tmp=$(mktemp -d /tmp/ssh-one-udp-menu.XXXXXX) || { fail 'Could not create a temporary directory.'; return 1; }
  installer_url="$raw_base/udp-custom/install.sh"
  if command -v curl >/dev/null 2>&1; then
    if ! curl --fail --location --retry 3 --silent --show-error "$installer_url" -o "$tmp/install.sh"; then
      rm -rf -- "$tmp"
      fail 'Could not download the UDP Custom installer. Check outbound HTTPS and repository settings.'
      return 1
    fi
  elif command -v wget >/dev/null 2>&1; then
    if ! wget --quiet --tries=3 --timeout=30 -O "$tmp/install.sh" "$installer_url"; then
      rm -rf -- "$tmp"
      fail 'Could not download the UDP Custom installer. Check outbound HTTPS and repository settings.'
      return 1
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update || ! apt-get install -y --no-install-recommends ca-certificates curl || ! curl --fail --location --retry 3 --silent --show-error "$installer_url" -o "$tmp/install.sh"; then
      rm -rf -- "$tmp"
      fail 'Could not install a download tool or fetch the UDP Custom installer.'
      return 1
    fi
  else
    rm -rf -- "$tmp"
    fail 'curl or wget is required, and apt-get is unavailable to install it.'
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

normalize_exclusions() {
  local raw=$1 token port
  local -a tokens
  local -A seen=()
  normalized_exclusions=()
  raw=${raw//[[:space:]]/}
  [[ -z $raw ]] && return 0
  if [[ $raw == ,* || $raw == *, || $raw == *,,* ]]; then
    fail 'Enter excluded UDP ports as a comma-separated list without empty items.'
    return 1
  fi
  IFS=',' read -r -a tokens <<< "$raw"
  if (( ${#tokens[@]} > 256 )); then
    fail 'Enter no more than 256 excluded UDP ports.'
    return 1
  fi
  for token in "${tokens[@]}"; do
    if [[ ! $token =~ ^[0-9]{1,5}$ ]]; then
      fail "Invalid excluded UDP port: $token"
      return 1
    fi
    port=$((10#$token))
    if (( port < 1 || port > 65535 )); then
      fail "Excluded UDP ports must be from 1 to 65535: $token"
      return 1
    fi
    if [[ -z ${seen[$port]+x} ]]; then
      seen[$port]=1
      normalized_exclusions+=("$port")
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
  local raw_protocol port_input entry proto rule_added=0
  local -a protocols
  printf '\nProtocol [udp/tcp/both; default udp]: '
  read -r raw_protocol || return 0
  raw_protocol=${raw_protocol,,}
  raw_protocol=${raw_protocol:-udp}
  case $raw_protocol in
    tcp) protocols=(tcp) ;;
    udp) protocols=(udp) ;;
    both) protocols=(tcp udp) ;;
    *) fail 'Choose tcp, udp, or both.'; pause; return 1 ;;
  esac

  printf 'Ports/ranges [default 1-65535] (examples: 53,443 or 10000-10100): '
  read -r port_input || return 0
  if [[ -z $port_input ]]; then
    if [[ $raw_protocol == tcp || $raw_protocol == both ]]; then
      fail 'Enter the TCP port/range explicitly; the 1-65535 default applies to UDP only.'
      pause
      return 1
    fi
    port_input='1-65535'
  fi
  if ! normalize_ports "$port_input"; then pause; return 1; fi

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

change_listener_port() {
  local config=/root/udp/config.json current new_port port_number backup exclusions
  [[ -f $config && ! -L $config && -r $config ]] || { fail 'A regular UDP Custom config was not found. Install/repair UDP Custom first.'; pause; return 1; }
  if ! ensure_python3; then
    fail 'Could not install python3, which is needed to safely edit the UDP Custom config.'
    pause
    return 1
  fi
  current=$(read_listener_port) || { fail 'Could not read the UDP Custom listener from config.json.'; pause; return 1; }
  printf 'New UDP Custom listener port [current %s]: ' "$current"
  read -r new_port || return 0
  new_port=${new_port:-$current}
  [[ $new_port =~ ^[0-9]{1,5}$ ]] || { fail 'Enter one port number from 1 to 65535.'; pause; return 1; }
  port_number=$((10#$new_port))
  (( port_number >= 1 && port_number <= 65535 )) || { fail 'Listener port must be from 1 to 65535.'; pause; return 1; }
  exclusions=$(current_udp_exclusions)
  if [[ ,$exclusions, == *,$port_number,* ]]; then
    fail "UDP port $port_number is reserved in the exclusion list. Remove it from exclusions before making it the listener."
    pause
    return 1
  fi
  if [[ $port_number == "$current" ]]; then
    printf 'UDP Custom already listens on UDP %s.\n' "$current"
    pause
    return 0
  fi
  if ! command -v ss >/dev/null 2>&1; then
    if ! command -v apt-get >/dev/null 2>&1 || ! apt-get update || ! apt-get install -y --no-install-recommends iproute2; then
      fail 'Could not install iproute2 to check whether the UDP port is already in use.'
      pause
      return 1
    fi
  fi
  local port_listeners
  port_listeners=$(ss -H -lun "sport = :$port_number" 2>/dev/null) || { fail 'Could not inspect UDP listening sockets with ss.'; pause; return 1; }
  if [[ -n $port_listeners ]]; then
    fail "UDP port $port_number is already in use. Choose an unused port."
    pause
    return 1
  fi
  backup=$(mktemp /root/udp/config.json.ssh-one-bak.XXXXXX) || { fail 'Could not create a config backup.'; pause; return 1; }
  cp -p -- "$config" "$backup" || { rm -f -- "$backup"; fail 'Could not back up config.json.'; pause; return 1; }
  restore_listener_config() {
    local restore_tmp
    restore_tmp=$(mktemp /root/udp/.config.json.restore.XXXXXX) || return 1
    if cp -p -- "$backup" "$restore_tmp" && mv -fT -- "$restore_tmp" "$config"; then
      return 0
    fi
    rm -f -- "$restore_tmp"
    return 1
  }
  if ! python3 - "$config" "$port_number" <<'PY'
import json, os, stat, sys, tempfile
path, port = sys.argv[1], sys.argv[2]
with open(path, encoding='utf-8') as stream:
    data = json.load(stream)
listen = data.get('listen')
if not isinstance(listen, str) or ':' not in listen:
    raise SystemExit('Unsupported listen address in config.json.')
host, _, _old_port = listen.rpartition(':')
data['listen'] = f'{host}:{port}'
mode = stat.S_IMODE(os.stat(path).st_mode)
fd, temp_path = tempfile.mkstemp(prefix='.config.json.', dir=os.path.dirname(path))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')
    os.chmod(temp_path, mode)
    os.replace(temp_path, path)
except BaseException:
    try:
        os.unlink(temp_path)
    except FileNotFoundError:
        pass
    raise
PY
  then
    if restore_listener_config && systemctl restart udp-custom.service && wait_for_udp_custom; then
      rm -f -- "$backup"
      fail 'Could not update config.json; the original config was restored and the service is active.'
    else
      fail "Could not update config.json or restore it; the backup remains at $backup."
    fi
    pause
    return 1
  fi
  if systemctl restart udp-custom.service && wait_for_udp_custom; then
    rm -f -- "$backup"
    printf 'UDP Custom now listens on UDP %s. Open this port in the host and provider firewalls if needed.\n' "$port_number"
  else
    if restore_listener_config && systemctl restart udp-custom.service && wait_for_udp_custom; then
      rm -f -- "$backup"
      fail 'UDP Custom did not stay active on the new port. The previous config was restored.'
    else
      fail "UDP Custom failed after the port change; recovery backup remains at $backup."
    fi
    pause
    return 1
  fi
  pause
}

write_udp_service_unit() {
  local excluded_ports=$1 target=$2 exclude_arg=''
  [[ -z $excluded_ports ]] || exclude_arg=" -exclude $excluded_ports"
  cat > "$target" <<UNIT
[Unit]
Description=UDP Custom

[Service]
Type=simple
WorkingDirectory=/root/udp
ExecStart=/root/udp/udp-custom server$exclude_arg
Restart=always
RestartSec=2s
User=root

[Install]
WantedBy=default.target
UNIT
}

configure_exclusions() {
  local config=/etc/ssh-one/udp-exclude-ports unit=/etc/systemd/system/udp-custom.service
  local current='' input new='' unit_backup state_backup='' unit_tmp state_tmp='' state_existed=0 listener_port port
  [[ -x /root/udp/udp-custom && -f $unit && ! -L $unit ]] || { fail 'Install/repair UDP Custom before changing excluded ports.'; pause; return 1; }
  [[ ! -L $config ]] || { fail 'The UDP exclusion file is a symbolic link; it was not changed.'; pause; return 1; }
  if ! grep -Eq '^ExecStart=/root/udp/udp-custom server([[:space:]]+-exclude[[:space:]][0-9,]+)?$' "$unit"; then
    fail 'The UDP Custom service unit is not managed by SSH-one; excluded ports were not changed.'
    pause
    return 1
  fi
  current=$(current_udp_exclusions)
  if ! ensure_python3; then
    fail 'Could not install python3 to validate excluded ports against the listener.'
    pause
    return 1
  fi
  listener_port=$(read_listener_port) || { fail 'Could not read the UDP Custom listener from config.json.'; pause; return 1; }
  printf 'UDP ports to exclude from UDP Custom (comma-separated; leave empty for none) [current: %s]: ' "${current:-none}"
  IFS= read -r input || return 0
  if ! normalize_exclusions "$input"; then pause; return 1; fi
  if (( ${#normalized_exclusions[@]} > 0 )); then
    local IFS=,
    new="${normalized_exclusions[*]}"
  fi
  for port in "${normalized_exclusions[@]}"; do
    if [[ $port == "$listener_port" ]]; then
      fail "UDP port $listener_port is the UDP Custom listener and cannot be excluded."
      pause
      return 1
    fi
  done
  if [[ $new == "$current" ]]; then
    printf 'UDP Custom exclusions are unchanged.\n'
    pause
    return 0
  fi

  unit_backup=$(mktemp /etc/systemd/system/.udp-custom.backup.XXXXXX) || { fail 'Could not back up the UDP Custom service unit.'; pause; return 1; }
  cp -a -- "$unit" "$unit_backup" || { rm -f -- "$unit_backup"; fail 'Could not back up the UDP Custom service unit.'; pause; return 1; }
  if [[ -e $config ]]; then
    [[ -f $config && ! -L $config ]] || { rm -f -- "$unit_backup"; fail 'The UDP exclusion file is not a regular file.'; pause; return 1; }
    state_backup=$(mktemp /etc/ssh-one/.udp-exclude.backup.XXXXXX) || { rm -f -- "$unit_backup"; fail 'Could not back up UDP exclusions.'; pause; return 1; }
    cp -a -- "$config" "$state_backup" || { rm -f -- "$unit_backup" "$state_backup"; fail 'Could not back up UDP exclusions.'; pause; return 1; }
    state_existed=1
  fi

  unit_tmp=$(mktemp /etc/systemd/system/.udp-custom.service.XXXXXX) || { rm -f -- "$unit_backup" "$state_backup"; fail 'Could not stage the UDP Custom service unit.'; pause; return 1; }
  if ! write_udp_service_unit "$new" "$unit_tmp"; then
    rm -f -- "$unit_tmp"
    rm -f -- "$unit_backup" "$state_backup"
    fail 'Could not prepare the UDP Custom service unit.'
    pause
    return 1
  fi
  if ! chmod 0644 "$unit_tmp"; then
    rm -f -- "$unit_tmp" "$unit_backup" "$state_backup"
    fail 'Could not prepare the UDP Custom service unit.'
    pause
    return 1
  fi
  state_tmp=$(mktemp /etc/ssh-one/.udp-exclude-ports.new.XXXXXX) || { rm -f -- "$unit_tmp" "$unit_backup" "$state_backup"; fail 'Could not stage UDP exclusions.'; pause; return 1; }
  if ! printf '%s\n' "$new" > "$state_tmp" || ! chmod 0600 "$state_tmp"; then
    rm -f -- "$state_tmp" "$unit_tmp" "$unit_backup" "$state_backup"
    fail 'Could not prepare UDP exclusions.'
    pause
    return 1
  fi

  restore_previous_settings() {
    local failed=0
    if (( state_existed )); then
      cp -a -- "$state_backup" /etc/ssh-one/.udp-exclude-ports.rollback && mv -fT -- /etc/ssh-one/.udp-exclude-ports.rollback "$config" || failed=1
    else
      rm -f -- "$config" || failed=1
    fi
    cp -a -- "$unit_backup" /etc/systemd/system/.udp-custom.service.rollback && mv -fT -- /etc/systemd/system/.udp-custom.service.rollback "$unit" || failed=1
    systemctl daemon-reload >/dev/null 2>&1 || failed=1
    systemctl restart udp-custom.service >/dev/null 2>&1 && wait_for_udp_custom || failed=1
    return "$failed"
  }

  if ! mv -fT -- "$state_tmp" "$config"; then
    rm -f -- "$state_tmp" "$unit_tmp" "$unit_backup" "$state_backup"
    fail 'Could not save UDP exclusions; the previous settings were kept.'
    pause
    return 1
  fi

  if ! mv -fT -- "$unit_tmp" "$unit" || ! systemctl daemon-reload || ! systemctl restart udp-custom.service || ! wait_for_udp_custom; then
    if restore_previous_settings; then
      rm -f -- "$unit_backup" "$state_backup" "$state_tmp"
      fail 'UDP Custom did not stay active with the new exclusions. The previous settings were restored.'
    else
      fail "UDP Custom could not be restored. Recovery copies remain at $unit_backup and ${state_backup:-no previous exclusion file}."
    fi
    pause
    return 1
  fi
  rm -f -- "$unit_backup" "$state_backup" "$state_tmp"
  printf 'UDP Custom exclusion list updated and service restarted: %s\n' "${new:-none}"
  pause
}

create_udp_user() {
  local username password confirmation server_port
  [[ -x /root/udp/udp-custom ]] || { fail 'UDP Custom is not installed. Choose Install/repair UDP Custom first.'; pause; return 1; }
  printf 'Username (letters/numbers/._-; Linux limit is 32 characters): '
  read -r username || return 0
  [[ $username =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || { fail 'Username must be 1-32 characters, start with a letter or number, and contain only letters, numbers, dot, underscore, or hyphen.'; pause; return 1; }
  [[ ! $username =~ ^[0-9]+$ ]] || { fail 'Username cannot contain only numbers.'; pause; return 1; }
  if getent passwd "$username" >/dev/null; then
    fail 'That username already exists. Choose another name.'
    pause
    return 1
  fi
  printf 'Password (any non-empty length; colon is not allowed): '
  IFS= read -r password || return 0
  printf 'Confirm password: '
  IFS= read -r confirmation || return 0
  if [[ -z $password || $password == *:* || $password != "$confirmation" ]]; then
    unset password confirmation
    fail 'Passwords must match, must not be empty, and must not contain a colon.'
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
    unset password confirmation
    if userdel "$username" >/dev/null 2>&1; then
      fail 'Could not set the account password; the incomplete account was removed.'
    else
      fail "Could not set the account password or remove the incomplete account. Review and remove $username manually."
    fi
    pause
    return 1
  fi
  unset password confirmation
  printf 'UDP Custom account created: %s\n' "$username"
  server_port=$(python3 - /root/udp/config.json <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        listen = json.load(stream).get('listen', '')
    match = re.fullmatch(r'.*:([0-9]{1,5})', listen)
    if not match:
        raise ValueError('unsupported listen address')
    print(match.group(1))
except Exception:
    print('unknown')
PY
  )
  printf 'Use this username/password with a client that supports UDP Custom. Current server listener: UDP %s.\n' "$server_port"
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
  if ! systemctl list-unit-files udp-custom.service --no-legend 2>/dev/null | grep -q 'udp-custom'; then
    fail 'The UDP Custom service unit is not installed. Choose Install/repair UDP Custom first.'
    pause
    return 1
  fi
  if systemctl restart udp-custom.service && wait_for_udp_custom; then
    printf 'UDP Custom service restarted.\n'
    systemctl --no-pager --full status udp-custom.service || true
  else
    fail 'UDP Custom did not stay active after restart.'
  fi
  pause
}

first_menu_iteration=1
while true; do
  if (( first_menu_iteration )) && [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then clear 2>/dev/null || true; fi
  first_menu_iteration=0
  printf '%s\n' '================ SSH-one UDP & Port Menu ================'
  printf '%s\n' '1. Open port(s) in host firewall (default UDP 1-65535; customizable)'
  printf '%s\n' '2. Change UDP Custom listener port (default 36712)'
  printf '%s\n' '3. Configure excluded UDP ports (defaults: 500, 1701, 2200, 4500, 7070)'
  printf '%s\n' '4. Check UDP Custom service status'
  printf '%s\n' '5. Install/repair UDP Custom'
  printf '%s\n' '6. Create UDP Custom account'
  printf '%s\n' '7. List UDP Custom accounts'
  printf '%s\n' '8. Delete UDP Custom account'
  printf '%s\n' '9. Restart UDP Custom service'
  printf '%s\n' '0. Back to main menu'
  printf '%s\n' '=========================================================='
  read -r -p 'Select an option: ' choice || exit 0
  case $choice in
    1) open_ports || true ;;
    2) change_listener_port || true ;;
    3) configure_exclusions || true ;;
    4) show_status ;;
    5) install_udp || true ;;
    6) create_udp_user || true ;;
    7) list_udp_users ;;
    8) delete_udp_user || true ;;
    9) restart_udp || true ;;
    0) exit 0 ;;
    *) fail 'Invalid option.'; pause ;;
  esac
done
