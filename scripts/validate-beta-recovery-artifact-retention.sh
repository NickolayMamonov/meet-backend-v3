#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

fail() {
  printf 'artifact retention validation failed: %s\n' "$1" >&2
  exit 1
}

for tool in jq date; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is unavailable"
done

[ "$#" -eq 0 ] || fail "arguments are not accepted"
metadata=$(cat)
jq -e -s 'length == 1 and (.[0] | type == "object")' <<<"$metadata" \
  >/dev/null 2>/dev/null ||
  fail "metadata is invalid"

if ! created_at=$(jq -er '
  if (.created_at | type == "string" and length > 0) then .created_at
  else error("created_at is invalid")
  end
' <<<"$metadata" 2>/dev/null); then
  fail "created timestamp is invalid"
fi

if ! expires_at=$(jq -er '
  if (.expires_at | type == "string" and length > 0) then .expires_at
  else error("expires_at is invalid")
  end
' <<<"$metadata" 2>/dev/null); then
  fail "expiry timestamp is invalid"
fi

if ! created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null); then
  fail "created timestamp could not be parsed"
fi
[[ "$created_epoch" =~ ^[0-9]+$ ]] || fail "created timestamp parse is not decimal"

if ! expires_epoch=$(date -u -d "$expires_at" +%s 2>/dev/null); then
  fail "expiry timestamp could not be parsed"
fi
[[ "$expires_epoch" =~ ^[0-9]+$ ]] || fail "expiry timestamp parse is not decimal"

created_epoch=$((10#$created_epoch))
expires_epoch=$((10#$expires_epoch))
retention_seconds=$((expires_epoch - created_epoch))
if [ "$retention_seconds" -lt 2591940 ]; then
  fail "retention is below the allowed interval"
fi
[ "$retention_seconds" -le 2592000 ] || fail "retention exceeds 30 days"
