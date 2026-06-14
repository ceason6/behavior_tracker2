#!/usr/bin/env bash
#
# Anthropic API key rotation helper for the ABC Behavior Tracker proxy.
#
# Anthropic's Admin API CANNOT create keys (Console-only, by design), so the
# create step is always manual: make a new key in console.anthropic.com first,
# then use this script to (1) install it into the proxy's secret file — which
# the proxy hot-reloads on the next request, no restart — and (2) disable the
# old key via the Admin API.
#
# Requirements:
#   - bash, curl, python3
#   - An *organization* account (the Admin API is unavailable on individual
#     accounts) for the list/disable commands.
#
# Environment:
#   ANTHROPIC_API_KEY_FILE  Path the proxy reads the key from.
#                           Default: ./secrets/anthropic.key
#   ANTHROPIC_ADMIN_KEY     Admin API key (starts with sk-ant-admin...) used for
#                           the list/disable commands. Not needed for `set`.
#
# Usage:
#   ./rotate-key.sh set     <new-key>            Install a new key into the secret file
#   ./rotate-key.sh list                         List active org API keys (id | name | status | hint)
#   ./rotate-key.sh disable <api_key_id>         Deactivate a key by id (apikey_...)
#   ./rotate-key.sh rotate  <new-key> <old_id>   set <new-key>, then disable <old_id>
#
# Typical rotation:
#   1) Create a new key in the Console.
#   2) ./rotate-key.sh list                      # find the OLD key's id
#   3) ./rotate-key.sh rotate sk-ant-NEWKEY apikey_OLDID
#
set -euo pipefail

KEY_FILE="${ANTHROPIC_API_KEY_FILE:-./secrets/anthropic.key}"
API="https://api.anthropic.com/v1/organizations/api_keys"
VER="2023-06-01"

usage() { sed -n '2,40p' "$0"; }

need_admin() {
  if [[ -z "${ANTHROPIC_ADMIN_KEY:-}" ]]; then
    echo "Error: set ANTHROPIC_ADMIN_KEY (sk-ant-admin...) for Admin API calls." >&2
    exit 1
  fi
}

do_set() {
  local new="${1:?usage: set <new-key>}"
  mkdir -p "$(dirname "$KEY_FILE")"
  ( umask 077; printf '%s' "$new" > "$KEY_FILE" )
  chmod 600 "$KEY_FILE"
  echo "Installed new key into $KEY_FILE (proxy uses it on the next request)."
}

do_list() {
  need_admin
  curl -fsS "$API?status=active&limit=100" \
    -H "anthropic-version: $VER" \
    -H "x-api-key: $ANTHROPIC_ADMIN_KEY" \
  | python3 -c '
import sys, json
data = json.load(sys.stdin).get("data", [])
if not data:
    print("(no active keys)")
for k in data:
    print(" | ".join(str(k.get(f, "")) for f in ("id", "name", "status", "partial_key_hint")))'
}

do_disable() {
  need_admin
  local id="${1:?usage: disable <api_key_id>}"
  curl -fsS -X POST "$API/$id" \
    -H "anthropic-version: $VER" \
    -H "content-type: application/json" \
    -H "x-api-key: $ANTHROPIC_ADMIN_KEY" \
    -d '{"status":"inactive"}' >/dev/null
  echo "Disabled $id."
}

case "${1:-}" in
  set)     do_set "${2:-}" ;;
  list)    do_list ;;
  disable) do_disable "${2:-}" ;;
  rotate)
    do_set "${2:?usage: rotate <new-key> <old_id>}"
    do_disable "${3:?usage: rotate <new-key> <old_id>}"
    echo "Rotation complete: new key installed, old key ${3} disabled."
    ;;
  *) usage; exit 1 ;;
esac
