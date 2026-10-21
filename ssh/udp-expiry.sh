#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'SSH-one UDP expiry: run as root.\n' >&2; exit 1; }
state_file=/etc/ssh-one/udp-expirations.tsv
[[ -e $state_file ]] || exit 0
[[ -f $state_file && ! -L $state_file ]] || { printf 'SSH-one UDP expiry: refusing an unsafe expiry state file.\n' >&2; exit 1; }
install -d -m 0755 /run/lock
exec 9>/run/lock/ssh-one-udp-expiry.lock
flock -n 9 || exit 0
state_tmp=$(mktemp /etc/ssh-one/.udp-expirations.XXXXXX)
trap 'rm -f -- "$state_tmp"' EXIT
chmod 0600 "$state_tmp"
now=$(date +%s)
while IFS= read -r record || [[ -n $record ]]; do
  [[ -n $record ]] || continue
  IFS=$'\t' read -r username expires extra <<< "$record"
  if [[ ! $username =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ || ! $expires =~ ^[0-9]{1,12}$ || -n ${extra:-} ]]; then
    printf 'SSH-one UDP expiry: preserving an invalid record.\n' >&2
    printf '%s\n' "$record" >> "$state_tmp"
    continue
  fi
  if ! getent passwd "$username" >/dev/null 2>&1; then continue; fi
  if ! id -nG "$username" 2>/dev/null | tr ' ' '\n' | grep -Fxq ssh-one-udp; then continue; fi
  if (( expires > now )); then
    printf '%s\n' "$record" >> "$state_tmp"
    continue
  fi
  pkill -KILL -u "$username" 2>/dev/null || true
  if userdel "$username"; then
    printf 'Expired UDP Custom account removed: %s\n' "$username"
  else
    printf 'SSH-one UDP expiry: could not remove expired account %s; will retry.\n' "$username" >&2
    printf '%s\n' "$record" >> "$state_tmp"
  fi
done < "$state_file"
if ! chmod 0600 "$state_tmp" || ! mv -fT -- "$state_tmp" "$state_file"; then
  printf 'SSH-one UDP expiry: could not save the expiry state file.\n' >&2
  exit 1
fi
