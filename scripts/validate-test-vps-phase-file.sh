#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --root PATH --state-dir PATH --phase predecessor|candidate|rollback|final --output PATH" >&2
  exit 2
}

fail() {
  echo "test VPS phase validation failed: $*" >&2
  exit 1
}

root=
state_dir=
phase=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --state-dir) [ "$#" -ge 2 ] || usage; state_dir=$2; shift 2 ;;
    --phase) [ "$#" -ge 2 ] || usage; phase=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$state_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$state_dir" != *..* ]] || usage
case "$phase" in predecessor|candidate|rollback|final) ;; *) usage ;; esac
[[ "$output" = "$state_dir/$phase.json" ]] || usage
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -d "$root" ] && [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || fail "phase root is unavailable"
[ -f "$output" ] && [ ! -L "$output" ] || fail "phase file is missing or unsafe"
owner=$(stat -c '%u:%g' "$output") || fail "phase owner cannot be read"
[ "$owner" = "0:0" ] || fail "phase owner is not root"
mode=$(stat -c '%a' "$output") || fail "phase mode cannot be read"
[ "$mode" -le 600 ] || fail "phase mode is too broad"
size=$(stat -c '%s' "$output") || fail "phase size cannot be read"
[ "$size" -le 65536 ] || fail "phase file is too large"
canonical=$(realpath -e -- "$output") || fail "phase path cannot be canonicalized"
case "$canonical" in "$state_dir/$phase.json") ;; *) fail "phase path escaped state directory" ;; esac
jq -e --arg phase "$phase" '
  type == "object" and
  .schema == "meet-backend/test-vps-closed-beta-state/v1" and
  .phase == $phase and
  .containerHealthy == true and
  .environmentMatched == true
' "$output" >/dev/null || fail "phase schema is invalid"
