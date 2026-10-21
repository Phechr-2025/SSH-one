#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'SSH-one DNS setup: %s\n' "$*" >&2
  if [[ -w /root/log-install.txt ]]; then printf 'SSH-one DNS setup: %s\n' "$*" >> /root/log-install.txt; fi
  exit 1
}
trap 'status=$?; message="SSH-one DNS setup: command failed at line $LINENO (exit $status)."; printf "%s\n" "$message" >&2; if [[ -w /root/log-install.txt ]]; then printf "%s\n" "$message" >> /root/log-install.txt; fi' ERR

SSH_ONE_REPO_CONFIG=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
[[ -r $SSH_ONE_REPO_CONFIG ]] || fail "repository config not found: $SSH_ONE_REPO_CONFIG"
. "$SSH_ONE_REPO_CONFIG"

if [[ -z ${SSH_ONE_DOMAIN_HOST:-} || -z ${CF_API_TOKEN:-} ]]; then
  [[ -r /dev/tty && -w /dev/tty ]] || fail 'interactive terminal required to collect the host and Cloudflare API token.'
fi
if [[ -z ${SSH_ONE_DOMAIN_HOST:-} ]]; then
  IFS= read -r -p 'Host/subdomain to use (for example node.example.com): ' SSH_ONE_DOMAIN_HOST </dev/tty || fail 'could not read the host name.'
fi
if [[ -z ${CF_API_TOKEN:-} ]]; then
  IFS= read -r -s -p 'Cloudflare API token from the account managing this domain (Zone Read + DNS Write; hidden): ' CF_API_TOKEN </dev/tty || fail 'could not read the Cloudflare token.'
  printf '\n' >/dev/tty
fi

SSH_ONE_DOMAIN_HOST=${SSH_ONE_DOMAIN_HOST,,}
# Always discover the Cloudflare zone from the host; it is no longer a prompt.
CF_ZONE_DOMAIN=
valid_fqdn() {
  local value=$1 label
  local -a labels
  [[ ${#value} -le 253 && $value == *.* && $value != .* && $value != *. && $value =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  IFS='.' read -r -a labels <<<"$value"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 && $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}
valid_fqdn "$SSH_ONE_DOMAIN_HOST" || fail 'invalid host name; use a full DNS name such as node.example.com.'
[[ -n $CF_API_TOKEN ]] || fail 'Cloudflare API token cannot be empty.'
[[ $CF_API_TOKEN != *$'\n'* && $CF_API_TOKEN != *$'\r'* ]] || fail 'Cloudflare API token contains an invalid line break.'
command -v curl >/dev/null 2>&1 || fail 'curl is missing.'
command -v jq >/dev/null 2>&1 || fail 'jq is missing.'

umask 077
token_file=$(mktemp /tmp/ssh-one-cloudflare-token.XXXXXX) || fail 'could not create a protected temporary token file.'
cleanup() { rm -f -- "$token_file"; }
trap cleanup EXIT
printf 'Authorization: Bearer %s\n' "$CF_API_TOKEN" > "$token_file"
unset CF_API_TOKEN

api='https://api.cloudflare.com/client/v4'
cf_api() {
  curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --header "@${token_file}" \
    -H 'Content-Type: application/json' "$@"
}
check_response() {
  local response=$1 action=$2
  if ! jq -e '.success == true' >/dev/null <<<"$response"; then
    printf 'Cloudflare rejected %s:\n' "$action" >&2
    jq -r '(.errors // [])[] | "  [\(.code // "?")] \(.message // "unknown API error")"' <<<"$response" >&2 || true
    fail "$action failed. Use a Cloudflare API token authorized by the account that manages $SSH_ONE_DOMAIN_HOST, with Zone:Read and DNS:Write for its zone. Remove conflicting DNS records if needed."
  fi
}

find_active_zone() {
  local candidate=$SSH_ONE_DOMAIN_HOST zone_response candidate_id candidate_account_id candidate_account_name candidate_nameservers
  while [[ $candidate == *.* ]]; do
    zone_response=$(cf_api --get \
      --data-urlencode "name=${candidate}" \
      --data-urlencode 'status=active' "$api/zones") || fail "could not query Cloudflare zone $candidate."
    check_response "$zone_response" "zone lookup for $candidate"
    candidate_id=$(jq -er --arg zone "$candidate" '[.result[] | select(.name == $zone)] | if length == 1 then .[0].id else empty end' <<<"$zone_response") || candidate_id=
    if [[ -n $candidate_id ]]; then
      candidate_account_id=$(jq -er --arg zone "$candidate" '[.result[] | select(.name == $zone)] | if length == 1 then .[0].account.id // empty else empty end' <<<"$zone_response") || candidate_account_id=
      candidate_account_name=$(jq -er --arg zone "$candidate" '[.result[] | select(.name == $zone)] | if length == 1 then .[0].account.name // empty else empty end' <<<"$zone_response") || candidate_account_name=
      candidate_nameservers=$(jq -cer --arg zone "$candidate" '[.result[] | select(.name == $zone)] | if length == 1 then (.[0].name_servers // [] | map(ascii_downcase | sub("\\.$"; "")) | unique | sort) else empty end' <<<"$zone_response") || candidate_nameservers=
      [[ -n $candidate_account_id ]] || fail "Cloudflare did not return the account that owns zone $candidate. Verify the token and zone access."
      [[ -n $candidate_nameservers ]] && jq -e 'length > 0' <<<"$candidate_nameservers" >/dev/null || fail "Cloudflare did not return authoritative nameservers for zone $candidate. Verify the token and zone access."
      CF_ZONE_DOMAIN=$candidate
      ZONE=$candidate_id
      CF_ACCOUNT_ID=$candidate_account_id
      CF_ACCOUNT_NAME=${candidate_account_name:-$candidate_account_id}
      CF_ZONE_NAMESERVERS_JSON=$candidate_nameservers
      return 0
    fi
    candidate=${candidate#*.}
  done
  return 1
}

verify_zone_delegation() {
  local response public_nameservers_json expected_nameservers current_nameservers
  response=$(curl --ipv4 --fail --silent --show-error --connect-timeout 5 --max-time 10 \
    --header 'accept: application/dns-json' --get \
    --data-urlencode "name=${CF_ZONE_DOMAIN}" \
    --data-urlencode 'type=NS' 'https://dns.google/resolve') \
    || fail "could not check public nameserver delegation for $CF_ZONE_DOMAIN. Verify outbound HTTPS access and retry."
  if ! jq -e '.Status == 0 and ([.Answer[]? | select(.type == 2)] | length > 0)' <<<"$response" >/dev/null; then
    fail "public DNS did not return nameserver records for $CF_ZONE_DOMAIN. Check its Cloudflare nameserver delegation before continuing."
  fi
  public_nameservers_json=$(jq -c '[.Answer[]? | select(.type == 2) | .data | ascii_downcase | sub("\\.$"; "")] | unique | sort' <<<"$response")
  if ! jq -n -e --argjson expected "$CF_ZONE_NAMESERVERS_JSON" --argjson actual "$public_nameservers_json" \
    '($expected | length > 0) and ($expected == $actual)' >/dev/null; then
    expected_nameservers=$(jq -r 'join(", ")' <<<"$CF_ZONE_NAMESERVERS_JSON")
    current_nameservers=$(jq -r 'join(", ")' <<<"$public_nameservers_json")
    printf 'Expected Cloudflare nameservers: %s\nCurrent public nameservers: %s\n' "$expected_nameservers" "$current_nameservers" >&2
    fail "public DNS is delegated to a different nameserver set than the Cloudflare zone accessed by this token. Use the account managing the live DNS zone, or correct delegation, then retry."
  fi
  printf 'Public DNS delegation matches the Cloudflare zone in account %s.\n' "$CF_ACCOUNT_NAME"
}

printf 'Finding the active Cloudflare zone for %s...\n' "$SSH_ONE_DOMAIN_HOST"
find_active_zone || fail "no active Cloudflare zone was found for $SSH_ONE_DOMAIN_HOST. Use a token authorized by the Cloudflare account that manages this domain, and grant it Zone:Read access to the zone."
printf 'Cloudflare account confirmed: %s (ID %s) manages active zone %s.\n' "$CF_ACCOUNT_NAME" "$CF_ACCOUNT_ID" "$CF_ZONE_DOMAIN"
verify_zone_delegation
install -d -m 0755 /etc/ssh-one
printf '%s\n' "$CF_ZONE_DOMAIN" > /etc/ssh-one/cloudflare-zone

IP=$(curl --ipv4 --fail --silent --show-error --connect-timeout 10 --max-time 20 https://api.ipify.org) || fail 'could not detect the VPS public IPv4 address.'
[[ $IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || fail "public IP lookup returned an invalid IPv4 address: $IP"
IFS='.' read -r -a ip_octets <<<"$IP"
for octet in "${ip_octets[@]}"; do
  (( 10#$octet <= 255 )) || fail "public IP lookup returned an invalid IPv4 address: $IP"
done

ensure_record() {
  local type=$1 name=$2 content=$3 response record_ids record_id payload
  response=$(cf_api --get \
    --data-urlencode "type=${type}" \
    --data-urlencode "name=${name}" "$api/zones/${ZONE}/dns_records") || fail "could not look up DNS record $name."
  check_response "$response" "DNS lookup for $name"
  record_ids=$(jq -r '.result[]?.id // empty' <<<"$response")
  payload=$(jq -cn --arg type "$type" --arg name "$name" --arg content "$content" \
    '{type:$type,name:$name,content:$content,ttl:120,proxied:false}')
  if [[ -z $record_ids ]]; then
    response=$(cf_api --request POST --data "$payload" "$api/zones/${ZONE}/dns_records") || fail "could not create DNS record $name."
    check_response "$response" "DNS creation for $name"
  else
    while IFS= read -r record_id; do
      [[ -n $record_id ]] || continue
      response=$(cf_api --request PUT --data "$payload" "$api/zones/${ZONE}/dns_records/${record_id}") || fail "could not update DNS record $name."
      check_response "$response" "DNS update for $name"
    done <<<"$record_ids"
  fi
}

verify_cloudflare_record() {
  local response
  response=$(cf_api --get \
    --data-urlencode 'type=A' \
    --data-urlencode "name=${SSH_ONE_DOMAIN_HOST}" "$api/zones/${ZONE}/dns_records") || fail "could not read back DNS record $SSH_ONE_DOMAIN_HOST."
  check_response "$response" "DNS read-back for $SSH_ONE_DOMAIN_HOST"
  jq -e --arg host "$SSH_ONE_DOMAIN_HOST" --arg ip "$IP" \
    '(.result | length) > 0 and (.result | all(.[]; .type == "A" and .name == $host and .content == $ip and .proxied == false))' \
    <<<"$response" >/dev/null || fail "Cloudflare read-back did not confirm an unproxied A record for $SSH_ONE_DOMAIN_HOST pointing to $IP."
}

verify_public_dns() {
  local attempt response=
  for ((attempt = 1; attempt <= 12; attempt++)); do
    response=$(curl --ipv4 --fail --silent --connect-timeout 5 --max-time 5 \
      --header 'accept: application/dns-json' --get \
      --data-urlencode "name=${SSH_ONE_DOMAIN_HOST}" \
      --data-urlencode 'type=A' 'https://dns.google/resolve' 2>/dev/null) || response=
    if [[ -n $response ]] && jq -e --arg ip "$IP" \
      '.Status == 0 and ([.Answer[]? | select(.type == 1) | .data] as $addresses | ($addresses | length) > 0 and ($addresses | all(.[]; . == $ip)))' \
      <<<"$response" >/dev/null; then
      return 0
    fi
    [[ $attempt -eq 12 ]] || sleep 5
  done
  return 1
}

printf 'Updating DNS A record %s to %s...\n' "$SSH_ONE_DOMAIN_HOST" "$IP"
ensure_record A "$SSH_ONE_DOMAIN_HOST" "$IP"
printf 'Verifying the saved Cloudflare A record...\n'
verify_cloudflare_record
printf 'Cloudflare confirmed the DNS-only A record %s -> %s in account %s.\n' "$SSH_ONE_DOMAIN_HOST" "$IP" "$CF_ACCOUNT_NAME"
printf 'Checking public DNS resolution for %s...\n' "$SSH_ONE_DOMAIN_HOST"
verify_public_dns || fail "public DNS did not resolve $SSH_ONE_DOMAIN_HOST to $IP after repeated checks. Check nameserver delegation and DNS propagation, then retry."
printf 'Public DNS confirms %s resolves to %s.\n' "$SSH_ONE_DOMAIN_HOST" "$IP"

# Write host configuration only after Cloudflare and public DNS both confirm the A record.
install -d -m 0755 /etc/xray /etc/v2ray /var/lib/crot /etc/ssh-one
printf '%s\n' "$IP" > /etc/ssh-one/public-ip || fail 'could not save the verified VPS public IPv4 address.'
printf 'IP=%s\n' "$SSH_ONE_DOMAIN_HOST" > /var/lib/crot/ipvps.conf
printf '%s\n' "$SSH_ONE_DOMAIN_HOST" > /etc/xray/domain
printf '%s\n' "$SSH_ONE_DOMAIN_HOST" > /etc/v2ray/domain
printf '%s\n' "$SSH_ONE_DOMAIN_HOST" > /root/domain
# SlowDNS is not installed in this build; clear a stale legacy value.
: > /root/nsdomain
printf 'DNS setup complete. Host: %s\n' "$SSH_ONE_DOMAIN_HOST"
