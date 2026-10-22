#!/usr/bin/env bash
set -Eeuo pipefail
exec /usr/bin/ssh-one-bbr "$@"
