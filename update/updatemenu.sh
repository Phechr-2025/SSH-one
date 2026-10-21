#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

fail() { printf 'SSH-one update: %s\n' "$*" >&2; exit 1; }
read_setting() {
  local key=$1 file=$2
  sed -n "s/^$key='\\([^']*\\)'$/\\1/p" "$file"
}
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail 'run this command as root.'
if [[ ! -x /usr/bin/ssh-one-update ]]; then
  config=${SSH_ONE_REPO_CONFIG:-/etc/ssh-one/repository.conf}
  [[ -r $config ]] || fail 'repository settings are missing.'
  owner=$(read_setting SSH_ONE_OWNER "$config")
  name=$(read_setting SSH_ONE_NAME "$config")
  branch=$(read_setting SSH_ONE_BRANCH "$config")
  [[ $owner =~ ^[A-Za-z0-9-]+$ && $name =~ ^[A-Za-z0-9._-]+$ && $branch =~ ^[A-Za-z0-9._/-]+$ && $branch != *..* ]] || fail 'saved GitHub repository settings are invalid.'
  for tool in curl unzip bash install mv find; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required to initialize the updater."; done
  work_dir=$(mktemp -d /tmp/ssh-one-update-bootstrap.XXXXXX) || fail 'could not create a temporary directory.'
  updater_tmp="/usr/bin/.ssh-one-update.new.$$"
  trap 'rm -rf -- "$work_dir"; rm -f -- "$updater_tmp"' EXIT
  archive="$work_dir/source.zip"
  extract="$work_dir/extract"
  mkdir -p "$extract"
  curl --fail --location --retry 3 --silent --show-error "https://codeload.github.com/$owner/$name/zip/refs/heads/$branch" -o "$archive" || fail 'could not download the updater package.'
  unzip -q "$archive" -d "$extract" || fail 'the updater package could not be extracted.'
  mapfile -t versions < <(find "$extract" -mindepth 2 -maxdepth 3 -type f -name VERSION -print)
  (( ${#versions[@]} == 1 )) || fail 'the repository archive has an invalid layout.'
  root=${versions[0]%/VERSION}
  downloaded_owner=$(read_setting SSH_ONE_OWNER "$root/repository.conf")
  downloaded_name=$(read_setting SSH_ONE_NAME "$root/repository.conf")
  downloaded_branch=$(read_setting SSH_ONE_BRANCH "$root/repository.conf")
  [[ $downloaded_owner == "$owner" && $downloaded_name == "$name" && $downloaded_branch == "$branch" ]] || fail 'the downloaded repository settings do not match the saved settings.'
  [[ -s $root/update/ssh-one-update.sh ]] || fail 'the updater script is missing from the repository.'
  bash -n "$root/update/ssh-one-update.sh" || fail 'the downloaded updater has a shell syntax error.'
  install -m 0755 -- "$root/update/ssh-one-update.sh" "$updater_tmp" || fail 'could not stage the updater.'
  mv -fT -- "$updater_tmp" /usr/bin/ssh-one-update || fail 'could not install the updater.'
fi
set +e
/usr/bin/ssh-one-update "$@"
status=$?
exit "$status"
