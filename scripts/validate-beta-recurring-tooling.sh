#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --role capture|restore --path PATH --allowlist PATH" >&2
  exit 2
}

role='' path='' allowlist=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --role) [ "$#" -ge 2 ] || usage; role=$2; shift 2 ;;
    --path) [ "$#" -ge 2 ] || usage; path=$2; shift 2 ;;
    --allowlist) [ "$#" -ge 2 ] || usage; allowlist=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$role" = capture || "$role" = restore ]] || usage
[[ "$path" = /* && "$allowlist" = /* && "$path" != *$'\n'* &&
  "$allowlist" != *$'\n'* && "$path" != *..* && "$allowlist" != *..* ]] || usage
[ -f "$path" ] && [ ! -L "$path" ] && [ -x "$path" ] ||
  { echo 'BACKUP_CUSTODY_BLOCKED:tooling_unavailable' >&2; exit 1; }
[ -f "$allowlist" ] && [ ! -L "$allowlist" ] ||
  { echo 'BACKUP_CUSTODY_BLOCKED:tooling_allowlist_unavailable' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || {
  echo 'BACKUP_CUSTODY_BLOCKED:strict_json_unavailable' >&2; exit 1;
}
timeout --foreground 5s python3 - "$allowlist" <<'PY'
import json
import sys

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream, object_pairs_hook=reject_duplicates)
PY
real_path=$(realpath -e -- "$path") || exit 1
[ "$real_path" = "$path" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:tooling_path_changed' >&2
  exit 1
}
workspace=${GITHUB_WORKSPACE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
workspace=$(realpath -e -- "$workspace") || exit 1
case "$path" in
  "$workspace/"*) relative=${path#"$workspace/"} ;;
  *) echo 'BACKUP_CUSTODY_BLOCKED:tooling_outside_checkout' >&2; exit 1 ;;
esac
digest=$(sha256sum "$path" | awk '{print $1}')
jq -e --arg role "$role" --arg path "$relative" --arg digest "$digest" '
  type=="object" and (keys|sort)==["awsCli","schema","tools"] and
  .schema=="meet-backend/beta-recurring-tooling-allowlist/v1" and
  (.awsCli|type=="object" and
    (keys|sort)==["archiveUrl","platform","publisher","sha256","version"] and
    .publisher=="amazon-aws" and .platform=="linux-x86_64" and
    (.version|test("^2\\.[0-9]+\\.[0-9]+$")) and
    (.archiveUrl|test("^https://awscli\\.amazonaws\\.com/awscli-exe-linux-x86_64-2\\.[0-9]+\\.[0-9]+\\.zip$")) and
    (.sha256|test("^[0-9a-f]{64}$"))) and
  ([.tools[] | select(.role==$role and .path==$path and .sha256==$digest)] | length)==1
' "$allowlist" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:tooling_digest_mismatch' >&2
  exit 1
}
printf 'tooling_role=%s path=%s sha256=%s\n' "$role" "$path" "$digest"
