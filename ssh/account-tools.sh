#!/usr/bin/env bash
set -Eeuo pipefail

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || { printf 'SSH-one account tools: run as root.\n' >&2; exit 1; }
}

group_users() {
  local group=$1
  getent group "$group" | awk -F: -v group="$group" '
    $1 == group && $4 != "" {
      count = split($4, members, ",")
      for (i = 1; i <= count; i++) if (members[i] != "") print members[i]
    }
  ' | sort -u
}

udp_users() {
  local user
  while IFS= read -r user; do
    [[ -n $user ]] || continue
    getent passwd "$user" >/dev/null 2>&1 && printf '%s\n' "$user"
  done < <(group_users ssh-one-udp)
}

ssh_users() {
  awk -F: '
    FILENAME == ARGV[1] {
      if ($1 != "nobody" && $3 ~ /^[0-9]+$/ && $3 >= 1000) {
        uid[$1] = $3
        shell[$1] = $7
      }
      next
    }
    FILENAME == ARGV[2] {
      password[$1] = $2
      expires[$1] = $8
      next
    }
    FILENAME == ARGV[3] {
      if ($1 == "ssh-one-udp" || $1 == "ssh-one-ssh") {
        count = split($4, users, ",")
        for (i = 1; i <= count; i++) {
          if (users[i] == "") continue
          if ($1 == "ssh-one-udp") udp[users[i]] = 1
          else ssh[users[i]] = 1
        }
      }
    }
    END {
      for (user in uid) {
        if (udp[user] || password[user] ~ /^[!*]/) continue
        legacy = (shell[user] ~ /\/(false|nologin)$/ && expires[user] ~ /^[0-9]+$/ && expires[user] > 0)
        if (ssh[user] || legacy) print user
      }
    }
  ' /etc/passwd /etc/shadow /etc/group | sort -u
}

case ${1:-} in
  list)
    require_root
    ssh_users
    ;;
  count)
    require_root
    ssh_users | awk 'END { print NR + 0 }'
    ;;
  list-udp)
    require_root
    udp_users
    ;;
  count-udp)
    require_root
    udp_users | awk 'END { print NR + 0 }'
    ;;
  mark-created)
    [[ ${SSH_ONE_MENU_ACTIVE:-0} == 1 ]] || exit 0
    [[ ${EUID:-$(id -u)} -eq 0 ]] || exit 0
    category=${2:-account}
    [[ $category =~ ^[A-Za-z0-9_-]{1,32}$ ]] || exit 0
    install -d -m 0755 /run/ssh-one
    printf '%s\n' "$category" >> /run/ssh-one/account-created
    ;;
  *)
    printf 'Usage: ssh-one-account-tools {list|count|list-udp|count-udp|mark-created [category]}\n' >&2
    exit 2
    ;;
esac
