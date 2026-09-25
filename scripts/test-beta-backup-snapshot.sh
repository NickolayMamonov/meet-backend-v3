#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-backup-snapshot.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
now=1790001000
digest=$(printf authority | sha256sum | awk '{print $1}')
cat >"$tmp/input.json" <<EOF
{"authorityDigest":"$digest","authorityGeneration":1,"capture":{"capturedAt":1790000000,"id":"point-1","state":"VALID"},"environment":"closed-beta","observedAt":1790001000,"schema":"meet-backend/beta-backup-status/v1","verified":{"capturedAt":1790000000,"id":"point-1","state":"VALID"}}
EOF
"$root/scripts/receive-beta-backup-status.sh" --input "$tmp/input.json" \
  --root "$tmp/root" --environment closed-beta --now "$now" >/dev/null ||
  fail "valid snapshot was rejected"
cp -- "$tmp/root/status.json" "$tmp/first.json"
"$root/scripts/receive-beta-backup-status.sh" --input "$tmp/input.json" \
  --root "$tmp/root" --environment closed-beta --now "$now" >/dev/null ||
  fail "equal replay was not idempotent"
cmp -s "$tmp/first.json" "$tmp/root/status.json" || fail "equal replay changed status"
sed 's/"observedAt":1790001000/"observedAt":1790002801/' "$tmp/input.json" >"$tmp/invalid.json"
if "$root/scripts/receive-beta-backup-status.sh" --input "$tmp/invalid.json" \
  --root "$tmp/root" --environment closed-beta --now "$now" >/dev/null 2>&1; then
  fail "future snapshot was accepted"
fi
printf 'test-beta-backup-snapshot.sh: passed\n'
