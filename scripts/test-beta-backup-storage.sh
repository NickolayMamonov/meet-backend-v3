#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-backup-storage.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
digest=$(printf x | sha256sum | awk '{print $1}')
cat >"$tmp/point.json" <<EOF
{"capture":{"capturedAt":1790000000,"sourceRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"contractDigest":"$digest","pointId":"slot-1790000000","proofDigest":"$digest","runtimeRevision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","schema":"meet-backend/beta-recovery-point/v2","slotId":"1790000000"}
EOF
"$root/scripts/run-beta-backup-storage.sh" validate-point --file "$tmp/point.json" >/dev/null ||
  fail "valid point rejected"
cat >"$tmp/inventory.json" <<'EOF'
[{"bytes":10,"key":"points/a/postgres.dump.age","versions":2},{"bytes":20,"key":"control/capture-head.json","versions":1}]
EOF
[ "$("$root/scripts/run-beta-backup-storage.sh" inventory --file "$tmp/inventory.json" --budget 41)" = 40 ] ||
  fail "version accounting is incorrect"
if "$root/scripts/run-beta-backup-storage.sh" inventory --file "$tmp/inventory.json" --budget 39 >/dev/null 2>&1; then
  fail "budget overflow was accepted"
fi
printf 'test-beta-backup-storage.sh: passed\n'
