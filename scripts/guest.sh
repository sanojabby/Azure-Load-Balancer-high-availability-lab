#!/usr/bin/env bash
#
# guest.sh - run a command on a lab guest over SSH
# ---------------------------------------------------------------------------
# Usage:
#   ./guest.sh lb01 "ip -br addr"             # unprivileged
#   ./guest.sh lb01 --root "apt-get update"   # root inside the guest
#
# Notes for anyone reading this later:
#
# 1. No associative arrays. macOS ships bash 3.2, which cannot parse
#    `declare -A`, so guest addressing uses a plain case statement.
# 2. The remote command is base64 encoded before it crosses SSH. Nesting
#    quotes for bash -c inside an SSH argument is where fragile scripts come
#    from, and a base64 blob has nothing for a shell to misread.
# 3. The root password is fed on stdin, so it never appears in argv, in shell
#    history or in the guest's process list.
# ---------------------------------------------------------------------------

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$ROOT_DIR/.secrets"
KEY="$SECRETS/lab_ed25519"
PASS_FILE="$SECRETS/lab.pass"
ENV_FILE="$SECRETS/lab.env"

[[ -f "$ENV_FILE" ]] || { echo "missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

target="${1:?usage: guest.sh <lb01|web01|web02|client01> [--root] <command>}"
shift

root=no
if [[ "${1:-}" == "--root" ]]; then
  root=yes
  shift
fi
[[ $# -gt 0 ]] || { echo "no command given" >&2; exit 1; }
remote_cmd="$*"

case "$target" in
  lb01)     ip=192.168.56.10 ;;
  web01)    ip=192.168.56.21 ;;
  web02)    ip=192.168.56.22 ;;
  client01) ip=192.168.56.31 ;;
  *) echo "unknown guest: $target" >&2; exit 1 ;;
esac

SSH_OPTS=(
  -i "$KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o BatchMode=yes
  -o ConnectTimeout=8
)

if [[ "$root" == "yes" ]]; then
  encoded="$(printf '%s' "$remote_cmd" | base64)"
  # base64 -d is available on Ubuntu; the decoded script runs under bash -l.
  ssh "${SSH_OPTS[@]}" "$LAB_USER@$ip" \
    "echo $encoded | base64 -d > /tmp/.lab-cmd.sh; sudo -S -p '' bash /tmp/.lab-cmd.sh" \
    < "$PASS_FILE"
else
  encoded="$(printf '%s' "$remote_cmd" | base64)"
  ssh "${SSH_OPTS[@]}" "$LAB_USER@$ip" \
    "echo $encoded | base64 -d > /tmp/.lab-cmd.sh; bash /tmp/.lab-cmd.sh"
fi
