#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'SSH-one: %s\n' "$*" >&2
  if [[ -w /root/log-install.txt ]]; then printf 'SSH-one: %s\n' "$*" >> /root/log-install.txt; fi
  exit 1
}
# ShellCheck cannot follow the assignments inside this quoted ERR trap.
# shellcheck disable=SC2154
trap 'status=$?; message="SSH-one: command failed at line $LINENO (exit $status)."; printf "%s\n" "$message" >&2; if [[ -w /root/log-install.txt ]]; then printf "%s\n" "$message" >> /root/log-install.txt; fi' ERR

valid_fqdn() {
  local value=$1 label
  local -a labels
  [[ ${#value} -le 253 && $value == *.* && $value != .* && $value != *. && $value =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  IFS='.' read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

check_host_dns() {
  local dns_response
  dns_response=$(curl --ipv4 --fail --silent --connect-timeout 5 --max-time 10 \
    --header 'accept: application/dns-json' --get \
    --data-urlencode "name=${SSH_ONE_DOMAIN_HOST}" \
    --data-urlencode 'type=A' 'https://dns.google/resolve' 2>/dev/null) || {
      DNS_LOOKUP_STATUS=unavailable
      RESOLVED_IPV4S=unavailable
      return 1
    }
  if ! jq -e 'type == "object" and (.Status | type == "number")' <<<"$dns_response" >/dev/null 2>&1; then
    DNS_LOOKUP_STATUS=unavailable
    RESOLVED_IPV4S=unavailable
    return 1
  fi
  if ! jq -e '.Status == 0 or .Status == 3' <<<"$dns_response" >/dev/null 2>&1; then
    DNS_LOOKUP_STATUS=unavailable
    RESOLVED_IPV4S=unavailable
    return 1
  fi
  DNS_LOOKUP_STATUS=available
  RESOLVED_IPV4S=$(jq -r '[.Answer[]? | select(.type == 1) | .data] | unique | if length == 0 then "none" else join(", ") end' <<<"$dns_response" 2>/dev/null || printf 'none')
  jq -e --arg ip "$VPS_PUBLIC_IPV4" \
    '.Status == 0 and ([.Answer[]? | select(.type == 1) | .data] as $addresses | ($addresses | length) > 0 and ($addresses | all(.[]; . == $ip))) and ([.Answer[]? | select(.type == 5)] | length == 0)' \
    <<<"$dns_response" >/dev/null 2>&1
}

detect_public_ipv4() {
  local octet
  VPS_PUBLIC_IPV4=$(curl --ipv4 --fail --silent --show-error --connect-timeout 10 --max-time 20 https://api.ipify.org) \
    || fail 'could not detect this VPS public IPv4 address.'
  [[ $VPS_PUBLIC_IPV4 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail 'public IP lookup returned an invalid IPv4 address.'
  IFS='.' read -r -a public_ip_octets <<<"$VPS_PUBLIC_IPV4"
  for octet in "${public_ip_octets[@]}"; do
    (( 10#$octet <= 255 )) || fail 'public IP lookup returned an invalid IPv4 address.'
  done
}

verify_host_dns() {
  local answer
  while ! check_host_dns; do
    if [[ ${DNS_LOOKUP_STATUS:-unavailable} == available ]]; then
      printf '\nWARNING: %s does not have a direct DNS A record pointing to this VPS.\n' "$SSH_ONE_DOMAIN_HOST" >&2
      printf 'Expected public IPv4: %s\nCurrent public A record(s): %s\n' "$VPS_PUBLIC_IPV4" "$RESOLVED_IPV4S" >&2
    else
      printf '\nWARNING: public DNS lookup for %s is unavailable.\n' "$SSH_ONE_DOMAIN_HOST" >&2
      printf 'Check outbound HTTPS access from the VPS, then retry. Expected public IPv4: %s\n' "$VPS_PUBLIC_IPV4" >&2
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
      if [[ ${DNS_LOOKUP_STATUS:-unavailable} == available ]]; then
        fail 'DNS verification failed. Create a DNS-only A record for this host pointing to the expected IPv4 address, then run the installer again.'
      fi
      fail 'DNS verification could not reach the public resolver. Check outbound HTTPS access from this VPS, then run the installer again.'
    fi
    if [[ ${DNS_LOOKUP_STATUS:-unavailable} == available ]]; then
      IFS= read -r -p 'Correct the DNS record, then press Enter to retry; enter another host; or type Q to quit: ' answer </dev/tty \
        || fail 'could not read DNS verification response from the terminal.'
    else
      IFS= read -r -p 'Restore outbound HTTPS access, then press Enter to retry; enter another host; or type Q to quit: ' answer </dev/tty \
        || fail 'could not read DNS verification response from the terminal.'
    fi
    case ${answer,,} in
      q) fail 'installation cancelled because the host DNS does not point to this VPS.' ;;
      '') ;;
      *)
        SSH_ONE_DOMAIN_HOST=${answer,,}
        valid_fqdn "$SSH_ONE_DOMAIN_HOST" || fail 'invalid host name. Enter a full DNS name such as node.example.com.'
        export SSH_ONE_DOMAIN_HOST
        ;;
    esac
  done
  printf 'DNS verification passed: %s resolves to %s.\n' "$SSH_ONE_DOMAIN_HOST" "$VPS_PUBLIC_IPV4"
}

repo_owner=${1:-Phechr-2025}
repo_name=${2:-SSH-one}
repo_branch=${3:-main}
[[ $repo_owner =~ ^[A-Za-z0-9-]+$ ]] || fail 'invalid GitHub owner.'
[[ $repo_name =~ ^[A-Za-z0-9._-]+$ ]] || fail 'invalid GitHub repository name.'
[[ $repo_branch =~ ^[A-Za-z0-9._/-]+$ && $repo_branch != *..* ]] || fail 'invalid Git branch name.'
export SSH_ONE_OWNER="$repo_owner" SSH_ONE_NAME="$repo_name" SSH_ONE_BRANCH="$repo_branch"

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run this installer as root.'
touch /root/log-install.txt || fail 'cannot create /root/log-install.txt.'
command -v flock >/dev/null 2>&1 || fail 'flock is required; install util-linux and try again.'
exec 9>/run/lock/ssh-one-install.lock || fail 'cannot create the SSH-one installation lock.'
flock -n 9 || fail 'another SSH-one installation is already running.'
printf '\n==== SSH-one v19 install attempt: %s ====\n' "$(date -Is)" >> /root/log-install.txt

if [[ -e /etc/ssh-one/installation-complete ]]; then
  fail 'SSH-one is already installed. This installer will not run a second time.'
fi
if [[ -e /etc/ssh-one/install-in-progress ]]; then
  fail 'an earlier SSH-one installation is incomplete. This installer cannot safely resume it; use a fresh VPS unless a recovery procedure specifically covers that version.'
fi
if [[ -e /etc/xray/domain || -e /etc/v2ray/domain || -e /root/domain || -e /var/lib/crot/ipvps.conf ]]; then
  fail 'SSH/VPN installation files already exist. This may be an existing or partial installation; use a fresh VPS unless a recovery procedure specifically covers that version.'
fi

# Collect the domain settings before OS or existing-install checks so that
# interactive users always get the requested prompts before a preflight exit.
if [[ -z ${SSH_ONE_DOMAIN_HOST:-} || -z ${CF_API_TOKEN:-} ]]; then
  [[ -r /dev/tty && -w /dev/tty ]] || fail 'interactive terminal required. Set SSH_ONE_DOMAIN_HOST and CF_API_TOKEN to run unattended.'
fi
if [[ -z ${SSH_ONE_DOMAIN_HOST:-} ]]; then
  IFS= read -r -p 'Host/subdomain to use (for example node.example.com): ' SSH_ONE_DOMAIN_HOST </dev/tty || fail 'could not read the host name from the terminal.'
fi
SSH_ONE_DOMAIN_HOST=${SSH_ONE_DOMAIN_HOST,,}
valid_fqdn "$SSH_ONE_DOMAIN_HOST" || fail 'invalid host name. Enter a full DNS name such as node.example.com.'
export SSH_ONE_DOMAIN_HOST

[[ -r /etc/os-release ]] || fail 'cannot identify this Linux distribution.'
. /etc/os-release
printf 'Detected system: %s %s (%s)\n' "${PRETTY_NAME:-${ID:-unknown}}" "${VERSION_ID:-unknown}" "$(uname -m)"
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 20.04 ]] || fail 'unsupported OS. This build requires Ubuntu 20.04 x86_64; it exits before changing the VPS.'
[[ $(uname -m) == x86_64 ]] || fail 'unsupported CPU architecture. This build requires x86_64.'
command -v systemctl >/dev/null || fail 'systemd is required.'
virt=$(systemd-detect-virt 2>/dev/null || true)
[[ $virt != openvz ]] || fail 'OpenVZ is not supported by the original setup scripts.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq unzip wget screen

detect_public_ipv4
printf 'Checking public DNS for %s against this VPS...\n' "$SSH_ONE_DOMAIN_HOST"
verify_host_dns
if [[ -z ${CF_API_TOKEN:-} ]]; then
  IFS= read -r -s -p 'Cloudflare API token from the account managing this domain (Zone Read + DNS Write; hidden): ' CF_API_TOKEN </dev/tty \
    || fail 'could not read the Cloudflare token from the terminal.'
  printf '\n' >/dev/tty
fi
[[ -n ${CF_API_TOKEN:-} ]] || fail 'Cloudflare API token cannot be empty.'
export SSH_ONE_DOMAIN_HOST CF_API_TOKEN

work_dir=$(mktemp -d /tmp/ssh-one.XXXXXX)
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT
archive="$work_dir/ssh-one.zip"
curl --fail --location --retry 3 --output "$archive" \
  "https://codeload.github.com/${repo_owner}/${repo_name}/zip/refs/heads/${repo_branch}"
unzip -q "$archive" -d "$work_dir"
source_dir="$work_dir/${repo_name}-${repo_branch}"
[[ -f "$source_dir/setup.sh" ]] || fail 'repository archive does not contain setup.sh.'
[[ -f "$source_dir/repository.conf" ]] || fail 'repository archive does not contain repository.conf.'
install -d -m 0755 /etc/ssh-one
unset SSH_ONE_OWNER SSH_ONE_NAME SSH_ONE_BRANCH
. "$source_dir/repository.conf"
[[ $SSH_ONE_OWNER == "$repo_owner" && $SSH_ONE_NAME == "$repo_name" && $SSH_ONE_BRANCH == "$repo_branch" ]] || fail 'repository.conf must match the owner, repository and branch passed to install.sh.'
install -m 0644 "$source_dir/repository.conf" /etc/ssh-one/repository.conf
export SSH_ONE_OWNER SSH_ONE_NAME SSH_ONE_BRANCH
cd "$source_dir"
if ! bash ./setup.sh; then
  fail 'setup.sh failed. The VPS may now be partially configured; see the error above and /root/log-install.txt.'
fi
