#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() { printf 'SSH-one update: %s\n' "$*" >&2; exit 1; }
note() { printf 'SSH-one update: %s\n' "$*"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run this command as root.'
[[ -r /etc/ssh-one/installation-complete ]] || fail 'SSH-one is not marked as installed on this server.'
[[ -r /etc/ssh-one/repository.conf ]] || fail 'repository settings are missing at /etc/ssh-one/repository.conf.'
for tool in curl unzip sha256sum flock; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required."; done

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

install -d -m 0755 /etc/ssh-one /run/lock
exec 9>/run/lock/ssh-one-update.lock || fail 'could not create the update lock.'
flock -n 9 || fail 'another SSH-one update is already running.'
work_dir=$(mktemp -d /tmp/ssh-one-update.XXXXXX) || fail 'could not create a temporary download directory.'
stage_dir=$(mktemp -d /usr/bin/.ssh-one-update.XXXXXX) || { rm -rf -- "$work_dir"; fail 'could not stage files under /usr/bin.'; }
committed=0
state_touched=0
declare -a changed_targets=() removed_targets=()
declare -A target_had_file=() new_target=() previous_hash=()

rollback() {
  local target state_file rollback_failed=0
  set +e
  for target in "${changed_targets[@]}"; do
    if [[ ${target_had_file[$target]:-0} == 1 && -f $stage_dir/backup/$target ]]; then
      if ! cp -a -- "$stage_dir/backup/$target" "$stage_dir/restore-$target" ||
         ! mv -fT -- "$stage_dir/restore-$target" "/usr/bin/$target"; then
        printf 'SSH-one update: rollback could not restore /usr/bin/%s\n' "$target" >&2
        rollback_failed=1
      fi
    else
      if ! rm -f -- "/usr/bin/$target"; then
        printf 'SSH-one update: rollback could not remove /usr/bin/%s\n' "$target" >&2
        rollback_failed=1
      fi
    fi
  done
  for target in "${removed_targets[@]}"; do
    if [[ -f $stage_dir/backup/$target ]]; then
      if ! cp -a -- "$stage_dir/backup/$target" "$stage_dir/restore-$target" ||
         ! mv -fT -- "$stage_dir/restore-$target" "/usr/bin/$target"; then
        printf 'SSH-one update: rollback could not restore removed /usr/bin/%s\n' "$target" >&2
        rollback_failed=1
      fi
    fi
  done
  if (( state_touched == 1 )); then
    for state_file in managed-files.tsv managed-files.sha256 runtime-files.sha256 installation-complete; do
      if [[ -f $stage_dir/state-backup/$state_file ]]; then
        if ! cp -a -- "$stage_dir/state-backup/$state_file" "/etc/ssh-one/.$state_file.restore" ||
           ! mv -fT -- "/etc/ssh-one/.$state_file.restore" "/etc/ssh-one/$state_file"; then
          printf 'SSH-one update: rollback could not restore state file %s\n' "$state_file" >&2
          rollback_failed=1
        fi
      else
        if ! rm -f -- "/etc/ssh-one/$state_file"; then
          printf 'SSH-one update: rollback could not remove state file %s\n' "$state_file" >&2
          rollback_failed=1
        fi
      fi
    done
  fi
  set -e
  (( rollback_failed == 0 )) || note 'rollback was incomplete; inspect the warnings and restore files from the temporary backup if needed.'
}
cleanup() {
  local status=$?
  trap - EXIT INT TERM
  set +e
  if (( committed == 0 )); then rollback; fi
  rm -f -- /etc/ssh-one/.managed-files.tsv.new /etc/ssh-one/.managed-files.sha256.new \
    /etc/ssh-one/.runtime-files.sha256.new /etc/ssh-one/.installation-complete.new \
    /etc/ssh-one/.managed-files.tsv.restore /etc/ssh-one/.managed-files.sha256.restore \
    /etc/ssh-one/.runtime-files.sha256.restore /etc/ssh-one/.installation-complete.restore
  rm -rf -- "$stage_dir" "$work_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$stage_dir/new" "$stage_dir/backup" "$stage_dir/state-backup"

archive="$work_dir/source.zip"
extract_dir="$work_dir/extracted"
mkdir -p "$extract_dir"
archive_url="https://codeload.github.com/${repo_owner}/${repo_name}/zip/refs/heads/${repo_branch}"
curl --fail --location --retry 3 --silent --show-error "$archive_url" -o "$archive" || fail 'could not download the repository archive. Check outbound HTTPS and the saved GitHub settings.'
unzip -q "$archive" -d "$extract_dir" || fail 'the downloaded repository archive could not be extracted.'
mapfile -t version_files < <(find "$extract_dir" -mindepth 2 -maxdepth 3 -type f -name VERSION -print)
(( ${#version_files[@]} == 1 )) || fail 'the archive must contain exactly one project VERSION file.'
repo_root=${version_files[0]%/VERSION}
manifest="$repo_root/update/managed-files.tsv"
[[ -r $manifest && -r $repo_root/repository.conf ]] || fail 'the downloaded project is missing its updater manifest or repository settings.'
downloaded_owner=$(read_setting SSH_ONE_OWNER "$repo_root/repository.conf")
downloaded_name=$(read_setting SSH_ONE_NAME "$repo_root/repository.conf")
downloaded_branch=$(read_setting SSH_ONE_BRANCH "$repo_root/repository.conf")
[[ $downloaded_owner == "$repo_owner" && $downloaded_name == "$repo_name" && $downloaded_branch == "$repo_branch" ]] || fail 'repository.conf in the archive does not match the saved repository settings.'
release_version=$(tr -d '\r\n' < "$repo_root/VERSION")
installed_version=$(tr -d '\r\n' < /etc/ssh-one/installation-complete)
[[ $release_version =~ ^v[0-9]+$ ]] || fail 'the downloaded VERSION file is malformed.'
[[ $installed_version =~ ^v[0-9]+$ ]] || fail 'the installed version marker is malformed; no files were changed.'
if (( ${release_version#v} < ${installed_version#v} )); then fail "repository version $release_version is older than installed version $installed_version."; fi

if [[ -r /etc/ssh-one/managed-files.sha256 ]]; then
  while IFS=$'\t' read -r target hash extra; do
    [[ -n ${target:-} && -n ${hash:-} ]] || continue
    [[ $target =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && $hash =~ ^[a-f0-9]{64}$ && -z ${extra:-} ]] || fail 'the saved managed-file checksum list is invalid.'
    previous_hash[$target]=$hash
  done < /etc/ssh-one/managed-files.sha256
fi

while IFS=$'\t' read -r source target mode kind extra; do
  source=${source%$'\r'}
  [[ -n $source && $source != \#* ]] || continue
  [[ -z ${extra:-} ]] || fail "invalid extra column in updater manifest for $source."
  [[ $source =~ ^[A-Za-z0-9._/-]+$ && $source != /* && $source != *..* ]] || fail "unsafe source path in updater manifest: $source"
  [[ $target =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || fail "unsafe command name in updater manifest: $target"
  [[ $mode == 0755 || $mode == 0644 ]] || fail "unsupported file mode for $target."
  [[ $kind == shell || $kind == python || $kind == binary ]] || fail "unsupported file type for $target."
  [[ -z ${new_target[$target]:-} ]] || fail "duplicate command in updater manifest: $target"
  file="$repo_root/$source"
  [[ -f $file && ! -L $file && -s $file ]] || fail "required repository file is missing, empty, or not regular: $source"
  case $kind in
    shell) bash -n "$file" || fail "shell syntax check failed: $source" ;;
    python) command -v python3 >/dev/null 2>&1 || fail 'python3 is required to validate this update.'; PYTHONPYCACHEPREFIX="$stage_dir/python-cache" python3 -m py_compile "$file" || fail "Python syntax check failed: $source" ;;
    binary) : ;;
  esac
  install -m "$mode" -- "$file" "$stage_dir/new/$target" || fail "could not stage $target."
  new_target[$target]=1
done < "$manifest"
(( ${#new_target[@]} > 0 )) || fail 'the updater manifest has no files.'

for target in "${!new_target[@]}"; do
  dest="/usr/bin/$target"
  if [[ -e $dest || -L $dest ]]; then
    [[ -f $dest && ! -L $dest ]] || fail "refusing to replace a non-regular file or symbolic link: $dest"
    cp -a -- "$dest" "$stage_dir/backup/$target" || fail "could not back up $dest."
    target_had_file[$target]=1
  else
    target_had_file[$target]=0
  fi
done

# Remove obsolete commands only when their previous installed checksum still matches.
if [[ -r /etc/ssh-one/managed-files.tsv ]]; then
  while IFS=$'\t' read -r _ target _ _ _; do
    [[ -n ${target:-} && $target =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || continue
    [[ -z ${new_target[$target]:-} ]] || continue
    dest="/usr/bin/$target"
    [[ -f $dest && ! -L $dest ]] || continue
    expected=${previous_hash[$target]:-}
    if [[ -z $expected ]]; then note "preserving obsolete command without a recorded checksum: $dest"; continue; fi
    actual=$(sha256sum -- "$dest" | awk '{print $1}')
    if [[ $actual != "$expected" ]]; then note "preserving obsolete command with local changes: $dest"; continue; fi
    cp -a -- "$dest" "$stage_dir/backup/$target" || fail "could not back up obsolete command $target."
    removed_targets+=("$target")
    rm -f -- "$dest" || fail "could not remove obsolete command $target."
  done < /etc/ssh-one/managed-files.tsv
fi

for target in "${!new_target[@]}"; do
  changed_targets+=("$target")
  mv -fT -- "$stage_dir/new/$target" "/usr/bin/$target" || fail "could not install $target; rolling back."
done

for state_file in managed-files.tsv managed-files.sha256 runtime-files.sha256 installation-complete; do
  if [[ -f /etc/ssh-one/$state_file ]]; then cp -a -- "/etc/ssh-one/$state_file" "$stage_dir/state-backup/$state_file"; fi
done
install -m 0644 -- "$manifest" "$stage_dir/managed-files.tsv" || fail 'could not prepare the file inventory.'
: > "$stage_dir/managed-files.sha256"
for target in "${!new_target[@]}"; do
  hash=$(sha256sum -- "/usr/bin/$target" | awk '{print $1}')
  printf '%s\t%s\n' "$target" "$hash" >> "$stage_dir/managed-files.sha256"
done
install -m 0644 -- "$stage_dir/managed-files.tsv" /etc/ssh-one/.managed-files.tsv.new || fail 'could not write the file inventory.'
install -m 0644 -- "$stage_dir/managed-files.sha256" /etc/ssh-one/.managed-files.sha256.new || fail 'could not write the command checksums.'
printf '%s\n' "$release_version" > /etc/ssh-one/.installation-complete.new || fail 'could not prepare the version marker.'
state_touched=1
mv -fT -- /etc/ssh-one/.managed-files.tsv.new /etc/ssh-one/managed-files.tsv || fail 'could not activate the file inventory.'
mv -fT -- /etc/ssh-one/.managed-files.sha256.new /etc/ssh-one/managed-files.sha256 || fail 'could not activate the command checksums.'
if [[ ! -s /etc/ssh-one/runtime-files.sha256 ]]; then
  : > /etc/ssh-one/.runtime-files.sha256.new
  for runtime_path in /usr/local/bin/xray /usr/local/bin/trojan-go /usr/local/bin/ws-tls /usr/local/bin/ws-nontls /usr/local/bin/ws-ovpn /usr/local/bin/ohpserver /bin/udpgw /root/udp/udp-custom; do
    if [[ -f $runtime_path && ! -L $runtime_path ]]; then
      runtime_hash=$(sha256sum -- "$runtime_path" | awk '{print $1}')
      printf '%s\t%s\n' "$runtime_path" "$runtime_hash" >> /etc/ssh-one/.runtime-files.sha256.new
    fi
  done
  chmod 0600 /etc/ssh-one/.runtime-files.sha256.new
  mv -fT -- /etc/ssh-one/.runtime-files.sha256.new /etc/ssh-one/runtime-files.sha256 || fail 'could not save runtime-file checksums.'
fi
mv -fT -- /etc/ssh-one/.installation-complete.new /etc/ssh-one/installation-complete || fail 'could not activate the version marker.'
committed=1
note "updated ${#new_target[@]} managed commands and menus to $release_version."
note 'VPN binaries, account/configuration data, operating-system packages, and firewall rules were preserved.'
