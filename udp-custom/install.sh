#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'UDP Custom: %s\n' "$*" >&2; exit 1; }
note() { printf 'UDP Custom: %s\n' "$*"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
[[ -r /etc/os-release ]] || fail 'cannot identify the operating system.'
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 20.04 ]] || fail 'the pinned upstream UDP Custom binary supports Ubuntu 20.04 only.'
[[ $(uname -m) == x86_64 ]] || fail 'the pinned upstream UDP Custom binary is x86_64 only.'
command -v systemctl >/dev/null || fail 'systemd is required.'
missing_packages=()
command -v curl >/dev/null || missing_packages+=(curl)
command -v sha256sum >/dev/null || missing_packages+=(coreutils)
command -v python3 >/dev/null || missing_packages+=(python3)
[[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing_packages+=(ca-certificates)
if (( ${#missing_packages[@]} > 0 )); then
  command -v apt-get >/dev/null || fail 'apt-get is required to install missing UDP Custom dependencies.'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update || fail 'could not refresh package lists for UDP Custom dependencies.'
  apt-get install -y --no-install-recommends "${missing_packages[@]}" || fail 'could not install UDP Custom dependencies.'
fi

# VVV's UDP installer uses this binary, the same default config, and the
# server-side -exclude option. Pin the source revision and verify both files.
repo='https://raw.githubusercontent.com/NevermoreSSH/Vergil/9a8df2ede26b052608478abcd6c112dff0f210f4/Tunnel'
default_exclusions='500,1701,2200,4500,7070'
tmp=$(mktemp -d /tmp/ssh-one-udp.XXXXXX) || fail 'could not create a temporary directory.'
cleanup() {
  for staged_path in "${binary_stage:-}" "${unit_stage:-}" "${config_stage:-}" "${exclude_stage:-}" "${inventory_tmp:-}"; do
    [[ -z $staged_path ]] || rm -f -- "$staged_path"
  done
  rm -rf -- "$tmp"
}
trap cleanup EXIT

fetch() {
  local path=$1 output=$2 expected=$3 actual
  curl --fail --location --retry 3 --silent --show-error "$repo/$path" -o "$output" || fail "download failed: $path"
  actual=$(sha256sum "$output" | awk '{print $1}')
  [[ $actual == "$expected" ]] || fail "checksum mismatch: $path"
}

fetch 'udp-custom-linux-amd64' "$tmp/udp-custom" '57baac486818fe0295397fc648df7c525e735e491185aa45aa141a928d39e620'
fetch 'config.json' "$tmp/config.json" 'b464f10436bd79f6dca9f5434e6ef4e529c48c91abf99ebb66999af2c1334eae'

normalize_exclusions() {
  local raw=$1 token port
  local -a tokens cleaned
  local -A seen=()
  exclude_ports=''
  [[ -n $raw ]] || return 0
  [[ $raw != ,* && $raw != *, && $raw != *,,* ]] || fail 'saved UDP exclusions contain an empty item.'
  IFS=',' read -r -a tokens <<< "$raw"
  (( ${#tokens[@]} <= 256 )) || fail 'no more than 256 excluded UDP ports are supported.'
  cleaned=()
  for token in "${tokens[@]}"; do
    [[ $token =~ ^[0-9]{1,5}$ ]] || fail "invalid excluded UDP port: $token"
    port=$((10#$token))
    (( port >= 1 && port <= 65535 )) || fail "excluded UDP port must be from 1 to 65535: $token"
    if [[ -z ${seen[$port]+x} ]]; then
      seen[$port]=1
      cleaned+=("$port")
    fi
  done
  local IFS=,
  exclude_ports="${cleaned[*]}"
}

read_listener_port() {
  python3 - "$1" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        listen = json.load(stream).get('listen', '')
    match = re.fullmatch(r'.*:([0-9]{1,5})', listen)
    if not match or not 1 <= int(match.group(1)) <= 65535:
        raise ValueError('unsupported listen address')
    print(int(match.group(1)))
except Exception as error:
    print(f'cannot read listener port: {error}', file=sys.stderr)
    sys.exit(1)
PY
}

install -d -m 0755 /root/udp /etc/systemd/system /etc/ssh-one
service_file=/etc/systemd/system/udp-custom.service
exclude_file=/etc/ssh-one/udp-exclude-ports
runtime_inventory=/etc/ssh-one/runtime-files.sha256
for path in "$exclude_file" "$runtime_inventory"; do
  [[ ! -L $path ]] || fail "refusing to follow a symbolic link: $path"
done
[[ ! -e $exclude_file || -f $exclude_file ]] || fail 'UDP exclusion state is not a regular file.'
[[ ! -e $runtime_inventory || -f $runtime_inventory ]] || fail 'runtime checksum inventory is not a regular file.'
exclude_raw=''
if [[ -r $exclude_file ]]; then
  exclude_raw=$(tr -d '\r\n' < "$exclude_file")
elif [[ -f $service_file && ! -L $service_file ]]; then
  existing_exclusions=$(sed -n 's|^ExecStart=/root/udp/udp-custom server -exclude ||p' "$service_file" | head -n 1)
  if [[ -n $existing_exclusions ]]; then
    exclude_raw="$default_exclusions,$existing_exclusions"
  else
    exclude_raw=$default_exclusions
  fi
else
  exclude_raw=$default_exclusions
fi
normalize_exclusions "$exclude_raw"

for path in /root/udp/udp-custom "$service_file"; do
  [[ ! -L $path ]] || fail "refusing to replace a symbolic link: $path"
  [[ ! -e $path || -f $path ]] || fail "refusing to replace a non-file path: $path"
done
if [[ -e $service_file ]] && ! grep -Eq '^ExecStart=/root/udp/udp-custom server([[:space:]]+-exclude[[:space:]][0-9,]+)?$' "$service_file"; then
  fail 'refusing to replace an unrecognized UDP Custom service unit.'
fi
config_file=/root/udp/config.json
[[ ! -L $config_file ]] || fail "refusing to follow a symbolic link: $config_file"
[[ ! -e $config_file || -f $config_file ]] || fail "UDP Custom config is not a regular file: $config_file"

had_binary=0
had_config=0
had_service=0
had_exclude=0
[[ ! -e /root/udp/udp-custom ]] || { had_binary=1; cp -a -- /root/udp/udp-custom "$tmp/old-binary"; }
[[ ! -e $config_file ]] || had_config=1
[[ ! -e $service_file ]] || { had_service=1; cp -a -- "$service_file" "$tmp/old-service"; }
[[ ! -e $exclude_file ]] || { had_exclude=1; cp -a -- "$exclude_file" "$tmp/old-exclusions"; }
was_active=0
was_enabled=0
systemctl is-active --quiet udp-custom.service && was_active=1 || true
systemctl is-enabled --quiet udp-custom.service && was_enabled=1 || true

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

binary_stage=$(mktemp /root/udp/.udp-custom.new.XXXXXX) || fail 'could not stage the UDP Custom binary.'
install -m 0755 "$tmp/udp-custom" "$binary_stage" || fail 'could not stage the UDP Custom binary.'
unit_stage=$(mktemp /etc/systemd/system/.udp-custom.service.new.XXXXXX) || fail 'could not stage the UDP Custom service unit.'
exclude_arg=''
[[ -z $exclude_ports ]] || exclude_arg=" -exclude $exclude_ports"
cat > "$unit_stage" <<UNIT
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
chmod 0644 "$unit_stage" || fail 'could not prepare the UDP Custom service unit.'
config_stage=''
if (( had_config == 0 )); then
  config_stage=$(mktemp /root/udp/.config.json.new.XXXXXX) || fail 'could not stage the default config.'
  install -m 0600 "$tmp/config.json" "$config_stage" || fail 'could not stage the default config.'
fi
config_for_validation=$config_file
(( had_config )) || config_for_validation=$config_stage
listener_port=$(read_listener_port "$config_for_validation") || fail 'UDP Custom config does not contain a valid listener port.'
if [[ ,$exclude_ports, == *,$listener_port,* ]]; then
  fail "UDP Custom listener port $listener_port is also excluded. Choose another listener or change excluded ports."
fi
exclude_stage=$(mktemp /etc/ssh-one/.udp-exclude-ports.new.XXXXXX) || fail 'could not stage the UDP exclusion list.'
printf '%s\n' "$exclude_ports" > "$exclude_stage" || fail 'could not stage the UDP exclusion list.'
chmod 0600 "$exclude_stage" || fail 'could not stage the UDP exclusion list.'

rollback() {
  local rollback_failed=0 staged_path
  if (( had_binary )); then
    cp -a -- "$tmp/old-binary" /root/udp/.udp-custom.rollback && mv -fT -- /root/udp/.udp-custom.rollback /root/udp/udp-custom || rollback_failed=1
  else rm -f -- /root/udp/udp-custom || rollback_failed=1; fi
  if (( had_service )); then
    cp -a -- "$tmp/old-service" /etc/systemd/system/.udp-custom.service.rollback && mv -fT -- /etc/systemd/system/.udp-custom.service.rollback "$service_file" || rollback_failed=1
  else rm -f -- "$service_file" || rollback_failed=1; fi
  if (( had_exclude )); then
    cp -a -- "$tmp/old-exclusions" /etc/ssh-one/.udp-exclude-ports.rollback && mv -fT -- /etc/ssh-one/.udp-exclude-ports.rollback "$exclude_file" || rollback_failed=1
  else rm -f -- "$exclude_file" || rollback_failed=1; fi
  if (( had_config == 0 )); then rm -f -- "$config_file" || rollback_failed=1; fi
  for staged_path in "${binary_stage:-}" "${unit_stage:-}" "${config_stage:-}" "${exclude_stage:-}"; do
    [[ -z $staged_path ]] || rm -f -- "$staged_path"
  done
  systemctl daemon-reload >/dev/null 2>&1 || rollback_failed=1
  if (( was_enabled )); then systemctl enable udp-custom.service >/dev/null 2>&1 || rollback_failed=1
  else systemctl disable udp-custom.service >/dev/null 2>&1 || true; fi
  if (( was_active )); then systemctl restart udp-custom.service >/dev/null 2>&1 && wait_for_udp_custom || rollback_failed=1
  else systemctl stop udp-custom.service >/dev/null 2>&1 || true; fi
  if (( rollback_failed )); then
    recovery_dir=$(mktemp -d /etc/ssh-one/udp-custom-recovery.XXXXXX) || recovery_dir=''
    if [[ -n $recovery_dir ]]; then
      [[ ! -f $tmp/old-binary ]] || cp -a -- "$tmp/old-binary" "$recovery_dir/udp-custom.binary" || true
      [[ ! -f $tmp/old-service ]] || cp -a -- "$tmp/old-service" "$recovery_dir/udp-custom.service" || true
      [[ ! -f $tmp/old-exclusions ]] || cp -a -- "$tmp/old-exclusions" "$recovery_dir/udp-exclude-ports" || true
      note "rollback was incomplete; previous files were saved in $recovery_dir."
    else
      note 'rollback was incomplete and emergency backup directory could not be created.'
    fi
  fi
  return "$rollback_failed"
}

if ! mv -fT -- "$binary_stage" /root/udp/udp-custom; then
  if rollback; then fail 'could not install the UDP Custom binary; previous settings were restored.'
  else fail 'could not install the UDP Custom binary; rollback was incomplete. Review the recovery path reported above.'; fi
fi
if (( had_config == 0 )); then
  if ! mv -fT -- "$config_stage" "$config_file"; then
    if rollback; then fail 'could not install the default config; previous settings were restored.'
    else fail 'could not install the default config; rollback was incomplete. Review the recovery path reported above.'; fi
  fi
fi
if ! mv -fT -- "$exclude_stage" "$exclude_file"; then
  if rollback; then fail 'could not save the UDP exclusion list; previous settings were restored.'
  else fail 'could not save the UDP exclusion list; rollback was incomplete. Review the recovery path reported above.'; fi
fi
if ! mv -fT -- "$unit_stage" "$service_file"; then
  if rollback; then fail 'could not install the UDP Custom service unit; previous settings were restored.'
  else fail 'could not install the UDP Custom service unit; rollback was incomplete. Review the recovery path reported above.'; fi
fi

if ! systemctl daemon-reload || ! systemctl enable udp-custom.service >/dev/null || ! systemctl restart udp-custom.service || ! wait_for_udp_custom; then
  if rollback; then
    fail 'UDP Custom could not start. Previous binary, service, config, and exclusion settings were restored.'
  else
    fail 'UDP Custom could not start, and rollback was incomplete. Review the recovery path reported above.'
  fi
fi

# Remove the legacy UDP gateway only when both its v20 unit and registered
# binary match; keep similarly named services and binaries owned by others.
legacy_unit=/etc/systemd/system/udpgw.service
legacy_expected_unit="$tmp/udpgw-v20.service"
cat > "$legacy_expected_unit" <<'UNIT'
[Unit]
Description=UDP Custom gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/udpgw --listen-addr 127.0.0.1:7800 --max-clients 1000 --max-connections-for-client 100
Restart=on-failure
RestartSec=2s
User=root

[Install]
WantedBy=multi-user.target
UNIT
if [[ -f $legacy_unit && ! -L $legacy_unit ]] && cmp -s "$legacy_expected_unit" "$legacy_unit"; then
  expected=''
  if [[ -f $runtime_inventory && ! -L $runtime_inventory ]]; then
    expected=$(awk -F '\t' '$1 == "/bin/udpgw" { print $2; exit }' "$runtime_inventory" 2>/dev/null || true)
  fi
  legacy_binary_verified=0
  if [[ $expected =~ ^[a-f0-9]{64}$ ]]; then
    if [[ -f /bin/udpgw && ! -L /bin/udpgw ]]; then
      actual=$(sha256sum /bin/udpgw | awk '{print $1}')
      [[ $actual == "$expected" ]] && legacy_binary_verified=1
    elif [[ ! -e /bin/udpgw && ! -L /bin/udpgw ]]; then
      legacy_binary_verified=1
    fi
  fi
  if (( legacy_binary_verified )) && systemctl disable --now udpgw.service >/dev/null 2>&1; then
    rm -f -- "$legacy_unit"
    legacy_wants=/etc/systemd/system/multi-user.target.wants/udpgw.service
    if [[ -L $legacy_wants ]]; then
      legacy_wants_target=$(readlink -- "$legacy_wants")
      if [[ $legacy_wants_target == '../udpgw.service' || $legacy_wants_target == /etc/systemd/system/udpgw.service ]]; then
        rm -f -- "$legacy_wants"
      else
        note 'preserving the unrelated udpgw enablement link.'
      fi
    fi
    if systemctl daemon-reload; then
      if (( legacy_binary_verified )) && [[ -f /bin/udpgw && ! -L /bin/udpgw ]]; then
        actual=$(sha256sum /bin/udpgw | awk '{print $1}')
        if [[ $actual == "$expected" ]]; then
          if [[ -f /etc/ssh-one/backups/runtime/udpgw && ! -L /etc/ssh-one/backups/runtime/udpgw ]]; then
            cp -a -- /etc/ssh-one/backups/runtime/udpgw /bin/.udpgw.restore
            mv -fT -- /bin/.udpgw.restore /bin/udpgw
          else
            rm -f -- /bin/udpgw
          fi
        else
          note 'preserving /bin/udpgw because it changed during cleanup.'
        fi
      fi
    else
      note 'legacy udpgw service stopped, but systemd could not reload; review /etc/systemd/system/udpgw.service.'
    fi
  elif (( legacy_binary_verified == 0 )); then
    note 'preserving udpgw.service because /bin/udpgw does not match SSH-one v20 runtime inventory.'
  else
    note 'could not stop the legacy udpgw.service; it was left unchanged.'
  fi
elif [[ -e $legacy_unit ]]; then
  note 'preserving udpgw.service because it does not match the SSH-one v20 unit.'
fi

if [[ -f $runtime_inventory && ! -L $runtime_inventory ]]; then
  if inventory_tmp=$(mktemp /etc/ssh-one/.runtime-files.XXXXXX); then
    if awk -F '\t' '$1 != "/root/udp/udp-custom" && $1 != "/bin/udpgw" { print }' "$runtime_inventory" > "$inventory_tmp" &&
      binary_hash=$(sha256sum /root/udp/udp-custom | awk '{print $1}') &&
      printf '/root/udp/udp-custom\t%s\n' "$binary_hash" >> "$inventory_tmp" &&
      chmod 0600 "$inventory_tmp" &&
      mv -fT -- "$inventory_tmp" "$runtime_inventory"; then
      inventory_tmp=''
    else
      rm -f -- "$inventory_tmp"
      inventory_tmp=''
      note 'could not refresh runtime checksums.'
    fi
  else
    note 'could not refresh runtime checksums.'
  fi
fi

# Preserve the existing firewall. If UFW is active, allow the UDP range used by VVV's UDP Custom.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if ! ufw allow 1:65535/udp comment 'SSH-one UDP Custom'; then
    note 'service is running, but UFW could not open UDP 1-65535; open the required UDP ports manually.'
  fi
fi

printf 'UDP Custom is running. Excluded UDP ports: %s. Check the VPS provider firewall/security group for inbound UDP ports 1-65535.\n' "${exclude_ports:-none}"
