#!/usr/bin/env bash
#
# Anthropic API key rotation helper for the ABC Behavior Tracker proxy.
#
# Anthropic's Admin API CANNOT create keys (Console-only, by design), and the
# proxy reads its key from the ANTHROPIC_API_KEY environment variable (set in the
# Render dashboard), not from a file. So rotation is:
#
#   1) Create a new key in console.anthropic.com (in the workspace that holds
#      your credits).
#   2) Paste it into ANTHROPIC_API_KEY in Render (Environment → Environment
#      Variables → Save → it redeploys). The startup log prints the last 4 chars
#      so you can confirm the new key is live.
#   3) Disable the OLD key with this script (so a leaked old key is dead).
#
# This script handles step 3 (and listing keys to find the old id).
#
# Requirements:
#   - bash, curl, python3
#   - An *organization* account (the Admin API is unavailable on individual
#     accounts).
#
# Environment:
#   ANTHROPIC_ADMIN_KEY   Admin API key (starts with sk-ant-admin...).
#
# Usage:
#   ./rotate-key.sh list                    List active org API keys (id | name | status | hint)
#   ./rotate-key.sh disable <api_key_id>    Deactivate a key by id (apikey_...)
#
# Typical rotation (after pasting the new key into Render):
#   ./rotate-key.sh list                    # find the OLD key's id
#   ./rotate-key.sh disable apikey_OLDID
#
set -euo pipefail

API="https://api.anthropic.com/v1/organizations/api_keys"
VER="2023-06-01"

usage() { sed -n '2,33p' "$0"; }

need_admin() {
  if [[ -z "${ANTHROPIC_ADMIN_KEY:-}" ]]; then
    echo "Error: set ANTHROPIC_ADMIN_KEY (sk-ant-admin...) for Admin API calls." >&2
    exit 1
  fi
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
  list)    do_list ;;
  disable) do_disable "${2:-}" ;;
  *) usage; exit 1 ;;
esac
