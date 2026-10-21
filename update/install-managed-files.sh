#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() { printf 'SSH-one file setup: %s\n' "$*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run as root.'
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_root/update/managed-files.tsv"
[[ -r $manifest ]] || fail 'managed-files.tsv is missing.'
if [[ -e /etc/ssh-one/installation-complete ]]; then
  fail 'SSH-one is already installed; use ssh-one-update to refresh managed files.'
fi
install -d -m 0755 /usr/bin /etc/ssh-one
stage_dir=$(mktemp -d /usr/bin/.ssh-one-files.XXXXXX) || fail 'could not create the command staging directory.'
declare -a installed_targets=()
declare -A targets=() had_target=()
rollback() {
  local target restore
  for target in "${installed_targets[@]}"; do
    restore="/etc/ssh-one/backups/managed-bin/$target"
    if [[ -f $restore && ! -L $restore ]]; then
      cp -a -- "$restore" "/usr/bin/.ssh-one-restore-$target" &&
        mv -fT -- "/usr/bin/.ssh-one-restore-$target" "/usr/bin/$target" ||
        printf 'SSH-one file setup: warning: could not restore previous %s\n' "/usr/bin/$target" >&2
    elif [[ ${had_target[$target]:-0} == 0 ]]; then
      rm -f -- "/usr/bin/$target" || printf 'SSH-one file setup: warning: could not remove partial %s\n' "/usr/bin/$target" >&2
    fi
  done
  for state_file in managed-files.tsv managed-files.sha256 runtime-files.sha256; do
    if [[ -f $stage_dir/state-backup/$state_file ]]; then
      cp -a -- "$stage_dir/state-backup/$state_file" "/etc/ssh-one/.$state_file.restore" &&
        mv -fT -- "/etc/ssh-one/.$state_file.restore" "/etc/ssh-one/$state_file" ||
        printf 'SSH-one file setup: warning: could not restore state file %s\n' "$state_file" >&2
    else
      rm -f -- "/etc/ssh-one/$state_file"
    fi
  done
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if (( status != 0 )); then rollback; fi
  rm -f -- /etc/ssh-one/.managed-files.tsv.new /etc/ssh-one/.managed-files.sha256.new \
    /etc/ssh-one/.runtime-files.sha256.new /etc/ssh-one/.managed-files.tsv.restore \
    /etc/ssh-one/.managed-files.sha256.restore /etc/ssh-one/.runtime-files.sha256.restore
  rm -rf -- "$stage_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$stage_dir/new" "$stage_dir/state-backup"

for state_file in managed-files.tsv managed-files.sha256 runtime-files.sha256; do
  if [[ -f /etc/ssh-one/$state_file ]]; then cp -a -- "/etc/ssh-one/$state_file" "$stage_dir/state-backup/$state_file"; fi
done

while IFS=$'\t' read -r source target mode kind extra; do
  source=${source%$'\r'}
  [[ -n $source && $source != \#* ]] || continue
  [[ -z ${extra:-} ]] || fail "invalid extra manifest field for $source."
  [[ $source =~ ^[A-Za-z0-9._/-]+$ && $source != /* && $source != *..* ]] || fail "unsafe source path: $source"
  [[ $target =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && -z ${targets[$target]:-} ]] || fail "invalid or duplicate command: $target"
  [[ $mode == 0755 || $mode == 0644 ]] || fail "invalid mode for $target."
  [[ $kind == shell || $kind == python || $kind == binary ]] || fail "unsupported file type for $target."
  source_file="$repo_root/$source"
  [[ -f $source_file && ! -L $source_file && -s $source_file ]] || fail "repository file is missing or invalid: $source"
  case $kind in
    shell) bash -n "$source_file" || fail "shell syntax check failed: $source" ;;
    python)
      command -v python3 >/dev/null 2>&1 || fail 'python3 is required to validate the RAM command.'
      PYTHONPYCACHEPREFIX="$stage_dir/python-cache" python3 -m py_compile "$source_file" || fail "Python syntax check failed: $source"
      ;;
    binary) : ;;
  esac
  if [[ -e /usr/bin/$target || -L /usr/bin/$target ]]; then
    [[ -f /usr/bin/$target && ! -L /usr/bin/$target ]] || fail "refusing a non-regular file or symbolic-link command path: /usr/bin/$target"
    had_target[$target]=1
    [[ -f /etc/ssh-one/backups/managed-bin/$target && ! -L /etc/ssh-one/backups/managed-bin/$target ]] ||
      fail "a pre-existing command has no safe backup: /usr/bin/$target"
  else
    had_target[$target]=0
  fi
  install -m "$mode" -- "$source_file" "$stage_dir/new/$target" || fail "could not stage $target."
  targets[$target]=1
done < "$manifest"
(( ${#targets[@]} > 0 )) || fail 'the managed-file manifest is empty.'
[[ -n ${targets[menu]:-} ]] || fail 'the main menu is not included in the managed-file manifest.'
[[ -n ${targets[ssh-one-uninstall]:-} ]] || fail 'the uninstaller is not included in the managed-file manifest.'

install -m 0644 -- "$manifest" "$stage_dir/managed-files.tsv"
: > "$stage_dir/managed-files.sha256"
for target in "${!targets[@]}"; do
  hash=$(sha256sum -- "$stage_dir/new/$target" | awk '{print $1}')
  printf '%s\t%s\n' "$target" "$hash" >> "$stage_dir/managed-files.sha256"
done
: > "$stage_dir/runtime-files.sha256"
for path in /usr/local/bin/xray /usr/local/bin/trojan-go /usr/local/bin/ws-tls /usr/local/bin/ws-nontls /usr/local/bin/ws-ovpn /usr/local/bin/ohpserver /bin/udpgw /root/udp/udp-custom; do
  if [[ -f $path && ! -L $path ]]; then
    hash=$(sha256sum -- "$path" | awk '{print $1}')
    printf '%s\t%s\n' "$path" "$hash" >> "$stage_dir/runtime-files.sha256"
  fi
done
chmod 0600 "$stage_dir/runtime-files.sha256"

for target in "${!targets[@]}"; do
  installed_targets+=("$target")
  mv -fT -- "$stage_dir/new/$target" "/usr/bin/$target" || fail "could not install /usr/bin/$target."
done

install -m 0644 -- "$stage_dir/managed-files.tsv" /etc/ssh-one/.managed-files.tsv.new
install -m 0644 -- "$stage_dir/managed-files.sha256" /etc/ssh-one/.managed-files.sha256.new
install -m 0600 -- "$stage_dir/runtime-files.sha256" /etc/ssh-one/.runtime-files.sha256.new
mv -fT -- /etc/ssh-one/.managed-files.tsv.new /etc/ssh-one/managed-files.tsv
mv -fT -- /etc/ssh-one/.managed-files.sha256.new /etc/ssh-one/managed-files.sha256
mv -fT -- /etc/ssh-one/.runtime-files.sha256.new /etc/ssh-one/runtime-files.sha256

[[ -x /usr/bin/menu ]] || fail 'menu command was not installed as an executable.'
/usr/bin/menu --check >/dev/null || fail 'the installed menu did not pass its startup check.'
resolved_menu=$(type -P menu 2>/dev/null || true)
if [[ -n $resolved_menu && $resolved_menu != /usr/bin/menu ]]; then
  printf 'SSH-one file setup: warning: PATH resolves "menu" to %s before /usr/bin/menu.\n' "$resolved_menu" >&2
  printf 'SSH-one file setup: use /usr/bin/menu or remove the conflicting command so the short menu command works.\n' >&2
fi
printf 'Installed and registered %s SSH-one commands and menus.\n' "${#targets[@]}"
