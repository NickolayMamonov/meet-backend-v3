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
mkdir -p "$tmp/point"
dd if=/dev/zero of="$tmp/point/postgres.dump.age" bs=1 count=8 status=none
dd if=/dev/zero of="$tmp/point/uploads.tar.gz.age" bs=1 count=8 status=none
cp "$tmp/point.json" "$tmp/point/recovery-point.json"
mkdir -p "$tmp/storage"
"$root/scripts/run-beta-backup-storage.sh" publish --source "$tmp/point" \
  --storage-root "$tmp/storage" --point-id slot-1790000000 --slot 1790000000 \
  --captured-at 1790000000 --owner test >/dev/null || fail "durable publish failed"
[ -s "$tmp/storage/points/slot-1790000000/point.json" ] ||
  fail "manifest-last descriptor was not published"
if "$root/scripts/run-beta-backup-storage.sh" publish --source "$tmp/point" \
  --storage-root "$tmp/storage" --point-id slot-1790000000 --slot 1790000000 \
  --captured-at 1790000000 --owner test >/dev/null 2>&1; then
  :
else
  fail "idempotent publish was rejected"
fi
jq -cnS \
  '{schema:"meet-backend/beta-backup-receipt/v1",receiptId:"receipt-1",
    pointId:"slot-1790000000",captureRevision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    restoreRevision:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    proofDigest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    verifiedCapturedAt:1790000000}' >"$tmp/receipt.json"
"$root/scripts/run-beta-backup-storage.sh" promote --storage-root "$tmp/storage" \
  --receipt "$tmp/receipt.json" --owner test >/dev/null || fail "promotion failed"
"$root/scripts/run-beta-backup-storage.sh" promote --storage-root "$tmp/storage" \
  --receipt "$tmp/receipt.json" --owner test | grep -Fq 'storage_promote=idempotent' ||
  fail "promotion replay was not idempotent"
mkdir "$tmp/storage/control/.writer.lock"
if "$root/scripts/run-beta-backup-storage.sh" publish --source "$tmp/point" \
  --storage-root "$tmp/storage" --point-id slot-1790000001 --slot 1790000001 \
  --captured-at 1790000001 --owner race >/dev/null 2>&1; then
  fail "writer race was accepted"
fi
rmdir "$tmp/storage/control/.writer.lock"
mkdir "$tmp/storage/points/incomplete"
if "$root/scripts/run-beta-backup-storage.sh" reconcile --storage-root "$tmp/storage" \
  >/dev/null 2>&1; then
  fail "incomplete point was reconciled as clean"
fi
rm -r "$tmp/storage/points/incomplete"
"$root/scripts/run-beta-backup-monitor.sh" --storage-root "$tmp/storage" \
  --environment closed-beta --now 1790000001 --receiver-root "$tmp/receiver" \
  --incident-state "$tmp/incident.json" --deadman-url '' >/dev/null ||
  fail "monitor delivery failed"
[ "$(jq -er '.schema' "$tmp/receiver/status.json")" = meet-backend/beta-backup-status/v1 ] ||
  fail "monitor status was not received"
cat >"$tmp/inventory.json" <<'EOF'
[{"bytes":10,"key":"points/a/postgres.dump.age","versions":2},{"bytes":20,"key":"control/capture-head.json","versions":1}]
EOF
[ "$("$root/scripts/run-beta-backup-storage.sh" inventory --file "$tmp/inventory.json" --budget 41)" = 40 ] ||
  fail "version accounting is incorrect"
if "$root/scripts/run-beta-backup-storage.sh" inventory --file "$tmp/inventory.json" --budget 39 >/dev/null 2>&1; then
  fail "budget overflow was accepted"
fi
printf 'test-beta-backup-storage.sh: passed\n'
