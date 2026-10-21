#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'gRPC account removal: %s\n' "$*" >&2; exit 1; }
vmess_config=/etc/xray/sl-vmessgrpc.json
vless_config=/etc/xray/sl-vlessgrpc.json
[[ -r $vmess_config && -r $vless_config ]] || fail 'gRPC account files are missing.'
mapfile -t users < <(grep -E '^### [A-Za-z0-9_]+ ' "$vmess_config" | awk '{print $2}')
(( ${#users[@]} > 0 )) || fail 'no gRPC accounts were found.'
printf 'Accounts configured for VMess gRPC and VLESS gRPC:\n'
for index in "${!users[@]}"; do printf '  %d) %s\n' "$((index + 1))" "${users[$index]}"; done
read -r -p "Select account [1-${#users[@]}]: " selection
[[ $selection =~ ^[0-9]+$ ]] || fail 'enter a number from the list.'
(( selection >= 1 && selection <= ${#users[@]} )) || fail 'selection is outside the account list.'
user=${users[$((selection - 1))]}
grep -Fq "### $user " "$vless_config" || fail "the matching VLESS gRPC account is missing: $user"
sed -i "/^### $user /,/^},{/d" "$vmess_config"
sed -i "/^### $user /,/^},{/d" "$vless_config"
rm -f -- "/etc/xray/$user-tls.json"
systemctl restart sl-vmess-grpc.service || fail 'could not restart the VMess gRPC service.'
systemctl restart sl-vless-grpc.service || fail 'could not restart the VLESS gRPC service.'
printf 'Removed gRPC account %s from both protocol files.\n' "$user"
