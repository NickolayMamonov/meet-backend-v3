#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-backup-storage.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
digest=$(printf x | sha256sum | awk '{print $1}')
capture_command_digest=$(printf capture-command | sha256sum | awk '{print $1}')
capture_evidence_digest=$(printf capture-evidence | sha256sum | awk '{print $1}')
cat >"$tmp/point.json" <<EOF
{"capture":{"capturedAt":1790000000,"sourceRevision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"captureCommandDigest":"$capture_command_digest","captureEvidenceDigest":"$capture_evidence_digest","contractDigest":"$digest","pointId":"slot-1790000000","proofDigest":"$digest","runtimeRevision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","schema":"meet-backend/beta-recovery-point/v2","slotId":"1790000000"}
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
descriptor_digest=$(jq -cS 'del(.descriptorDigest)' \
  "$tmp/storage/points/slot-1790000000/point.json" |
  sha256sum | awk '{print $1}')
jq -e --arg descriptor "$descriptor_digest" \
  '.descriptorDigest==$descriptor and
   (.manifestDigest|type=="string" and test("^[0-9a-f]{64}$"))' \
  "$tmp/storage/points/slot-1790000000/point.json" >/dev/null ||
  fail "descriptor digest binding is not canonical"
cp -r "$tmp/point" "$tmp/partial-point"
printf '{"schema":"meet-backend/closed-beta-database-proof/v1"}\n' \
  >"$tmp/partial-point/capture-database-proof.json"
if "$root/scripts/run-beta-backup-storage.sh" publish --source "$tmp/partial-point" \
  --storage-root "$tmp/storage" --point-id slot-1790000001 --slot 1790000001 \
  --captured-at 1790000000 --owner test >/dev/null 2>&1; then
  fail "incomplete capture proof pair was accepted"
fi
rm -rf "$tmp/partial-point"
if "$root/scripts/run-beta-backup-storage.sh" publish --source "$tmp/point" \
  --storage-root "$tmp/storage" --point-id slot-1790000000 --slot 1790000000 \
  --captured-at 1790000000 --owner test >/dev/null 2>&1; then
  :
else
  fail "idempotent publish was rejected"
fi
descriptor_digest=$(jq -cS 'del(.descriptorDigest)' \
  "$tmp/storage/points/slot-1790000000/point.json" |
  sha256sum | awk '{print $1}')
jq -cnS --arg descriptor "$descriptor_digest" \
  '{schema:"meet-backend/beta-recurring-restore-proof/v2",
    captureRevision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    restoreRevision:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    capturedAt:1790000000,pointDescriptorDigest:$descriptor,
    protectionDigest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    identityCustody:"restore-only",isolated:true,databaseProbe:true,
    mediaProbe:true,cleanup:true,
    preFingerprint:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    postFingerprint:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}' \
  >"$tmp/receipt-1.proof.json"
proof_digest=$(sha256sum "$tmp/receipt-1.proof.json" | awk '{print $1}')
jq -cnS --arg descriptor "$descriptor_digest" --arg command "$capture_command_digest" \
  --arg proof "$proof_digest" \
  '{schema:"meet-backend/beta-backup-receipt/v2",receiptId:"receipt-1",
    pointId:"slot-1790000000",captureRevision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    restoreRevision:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    captureAt:1790000000,captureCommandDigest:$command,pointDescriptorDigest:$descriptor,
    protectionDigest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
    reviewerId:"reviewer-1",proofDigest:$proof,
    verifiedCapturedAt:1790000000}' >"$tmp/receipt.json"
"$root/scripts/run-beta-backup-storage.sh" promote --storage-root "$tmp/storage" \
  --receipt "$tmp/receipt.json" --owner test >/dev/null || fail "promotion failed"
"$root/scripts/run-beta-backup-storage.sh" promote --storage-root "$tmp/storage" \
  --receipt "$tmp/receipt.json" --owner test | grep -Fq 'storage_promote=idempotent' ||
  fail "promotion replay was not idempotent"
cp -- "$tmp/receipt.json" "$tmp/forged-receipt.json"
jq '.pointDescriptorDigest = ("f" * 64)' "$tmp/forged-receipt.json" >"$tmp/forged.tmp"
mv -- "$tmp/forged.tmp" "$tmp/forged-receipt.json"
if "$root/scripts/run-beta-backup-storage.sh" promote --storage-root "$tmp/storage" \
  --receipt "$tmp/forged-receipt.json" --owner attacker >/dev/null 2>&1; then
  fail "forged receipt was promoted"
fi
printf 'provider fixture\n' >"$tmp/provider-source"
provider_result=$("$root/scripts/run-beta-backup-storage.sh" provider-put \
  --storage-root "$tmp/storage" --key points/slot-1790000000/provider-fixture \
  --file "$tmp/provider-source")
provider_version=${provider_result#storage_provider_put=}
provider_version=$(jq -er '.versionId' <<<"$provider_version")
for invalid_key in points/../escape points//duplicate unknown-prefix/object; do
  if "$root/scripts/run-beta-backup-storage.sh" provider-put \
    --storage-root "$tmp/storage" --key "$invalid_key" \
    --file "$tmp/provider-source" >/dev/null 2>&1; then
    fail "invalid provider mutation key was accepted: $invalid_key"
  fi
done
"$root/scripts/run-beta-backup-storage.sh" provider-get --storage-root "$tmp/storage" \
  --key points/slot-1790000000/provider-fixture --version "$provider_version" \
  --output "$tmp/provider-copy" >/dev/null || fail "provider get failed"
cmp -- "$tmp/provider-source" "$tmp/provider-copy" || fail "provider copy differs"
[ "$("$root/scripts/run-beta-backup-storage.sh" provider-list \
  --storage-root "$tmp/storage" | jq '[.[] | select(.key=="points/slot-1790000000/provider-fixture")] | length')" -eq 1 ] ||
  fail "provider version was not listed"
"$root/scripts/run-beta-backup-storage.sh" provider-delete --storage-root "$tmp/storage" \
  --key points/slot-1790000000/provider-fixture --version "$provider_version" >/dev/null ||
  fail "provider delete failed"
"$root/scripts/run-beta-backup-storage.sh" prune --storage-root "$tmp/storage" \
  --now 1820000000 --owner test >/dev/null || fail "pin-safe prune failed"
[ -d "$tmp/storage/points/slot-1790000000" ] || fail "prune removed the verified pin"
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
grep -Fq 'control/writer.json' "$root/scripts/beta-backup-storage.sh" ||
  fail "remote reconciliation does not inspect durable writer state"
grep -Fq 'writer_reconciliation_pending' "$root/scripts/beta-backup-storage.sh" ||
  fail "remote reconciliation does not retain pending writer state"
cat >"$tmp/incident.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jq -e '.privateDestinationRequired==true' "$2" >/dev/null
EOF
cat >"$tmp/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 755 "$tmp/incident.sh" "$tmp/curl"
cp -- "$tmp/storage/control/capture-head.json" "$tmp/capture-head.saved"
cp -- "$tmp/storage/control/verified-head.json" "$tmp/verified-head.saved"
rm -f -- "$tmp/storage/control/capture-head.json" "$tmp/storage/control/verified-head.json"
BETA_BACKUP_TEST_FIXTURE=true PATH="$tmp:$PATH" "$root/scripts/run-beta-backup-monitor.sh" --storage-root "$tmp/storage" \
  --environment closed-beta --now 1790000001 --receiver-root "$tmp/receiver" \
  --incident-state "$tmp/incident.json" --incident-command "$tmp/incident.sh" \
  --deadman-url https://deadman.invalid --deadman-provider curl \
  --deadman-method POST --deadman-timeout 30 >/dev/null ||
  fail "monitor delivery failed"
if PATH="$tmp:$PATH" "$root/scripts/run-beta-backup-monitor.sh" --storage-root "$tmp/storage" \
  --environment closed-beta --now 1790000001 --receiver-root "$tmp/receiver" \
  --incident-state "$tmp/incident-arbitrary.json" --incident-command "$tmp/incident.sh" \
  --deadman-url https://deadman.invalid --deadman-provider curl \
  --deadman-method POST --deadman-timeout 30 >/dev/null 2>&1; then
  fail "arbitrary incident command was admitted outside fixture mode"
fi
[ "$(jq -er '.schema' "$tmp/receiver/status.json")" = meet-backend/beta-backup-status/v1 ] ||
  fail "monitor status was not received"
incident_deliveries=$(jq -er '.deliveryCount' "$tmp/incident.json")
BETA_BACKUP_TEST_FIXTURE=true PATH="$tmp:$PATH" "$root/scripts/run-beta-backup-monitor.sh" --storage-root "$tmp/storage" \
  --environment closed-beta --now 1790000002 --receiver-root "$tmp/receiver" \
  --incident-state "$tmp/incident.json" --incident-command "$tmp/incident.sh" \
  --deadman-url https://deadman.invalid --deadman-provider curl \
  --deadman-method POST --deadman-timeout 30 >/dev/null ||
  fail "monitor replay delivery failed"
[ "$(jq -er '.deliveryCount' "$tmp/incident.json")" = "$incident_deliveries" ] ||
  fail "active incident was delivered more than once"
cp -- "$tmp/capture-head.saved" "$tmp/storage/control/capture-head.json"
cp -- "$tmp/verified-head.saved" "$tmp/storage/control/verified-head.json"
BETA_BACKUP_TEST_FIXTURE=true PATH="$tmp:$PATH" "$root/scripts/run-beta-backup-monitor.sh" --storage-root "$tmp/storage" \
  --environment closed-beta --now 1790000003 --receiver-root "$tmp/receiver" \
  --incident-state "$tmp/incident.json" --incident-command "$tmp/incident.sh" \
  --deadman-url https://deadman.invalid --deadman-provider curl \
  --deadman-method POST --deadman-timeout 30 >/dev/null ||
  fail "monitor recovery delivery failed"
[ "$(jq -er '.state' "$tmp/incident.json")" = recovered ] &&
  [ "$(jq -er '.recoveryCount' "$tmp/incident.json")" -eq 1 ] ||
  fail "monitor recovery transition was not persisted"
if BETA_BACKUP_TEST_FIXTURE=true PATH="$tmp:$PATH" "$root/scripts/run-beta-backup-monitor.sh" --storage-root "$tmp/storage" \
  --environment closed-beta --now 1790000004 --receiver-root "$tmp/receiver" \
  --incident-state "$tmp/incident.json" --incident-command "$tmp/incident.sh" \
  --deadman-url '' --deadman-provider curl --deadman-method POST \
  --deadman-timeout 30 >/dev/null 2>&1; then
  fail "missing mandatory dead-man heartbeat was admitted"
fi
cat >"$tmp/inventory.json" <<'EOF'
[{"bytes":10,"key":"points/a/postgres.dump.age","versions":2},{"bytes":20,"key":"control/capture-head.json","versions":1}]
EOF
[ "$("$root/scripts/run-beta-backup-storage.sh" inventory --file "$tmp/inventory.json" --budget 41)" = 40 ] ||
  fail "version accounting is incorrect"
if "$root/scripts/run-beta-backup-storage.sh" inventory --file "$tmp/inventory.json" --budget 39 >/dev/null 2>&1; then
  fail "budget overflow was accepted"
fi
if "$root/scripts/run-beta-backup-storage.sh" prune --now 1820000000 \
  --owner test >/dev/null 2>&1; then
  fail "remote prune without A3 snapshot was accepted"
fi
grep -Fq 'expectedKeys' "$root/scripts/beta-backup-storage.sh" ||
  fail "writer state does not retain expected mutation closure"
grep -Fq '.operation=="idle" and .phase=="idle"' \
  "$root/scripts/beta-backup-storage.sh" ||
  fail "writer acquisition does not require terminal idle state"
grep -Fq '.leaseUntil==0 and .reservationBytes==0' \
  "$root/scripts/beta-backup-storage.sh" ||
  fail "writer acquisition does not require a zero terminal lease"
grep -Fq 'writer_state_not_terminal' "$root/scripts/beta-backup-storage.sh" ||
  fail "writer acquisition does not reject malformed unlocked state"
grep -Fq 'beta_storage_remote_writer_transition ambiguous true' \
  "$root/scripts/beta-backup-storage.sh" ||
  fail "ambiguous mutations are not durably fenced"
grep -Fq 'receipts/$point_id/' "$root/scripts/beta-backup-storage.sh" ||
  fail "orphan receipt graph cleanup is missing"
grep -Fq 'pinned_closure_invalid' "$root/scripts/beta-backup-storage.sh" ||
  fail "prune does not fail closed on invalid pinned closure"
grep -Fq 'BETA_BACKUP_BYTE_BUDGET" 0 false' "$root/scripts/beta-backup-storage.sh" ||
  fail "prune cannot inventory an over-budget bucket for reclamation"
grep -Fq 'lifecycle_pins=protected' "$root/scripts/run-beta-backup-storage.sh" ||
  fail "capability admission does not prove lifecycle pin protection"
grep -Fq 'beta_storage_aws_read head-bucket' "$root/scripts/run-beta-backup-storage.sh" ||
  fail "capability admission bypasses the bounded head-bucket read"
grep -Fq 'beta_storage_aws_read get-bucket-versioning' "$root/scripts/run-beta-backup-storage.sh" ||
  fail "capability admission bypasses the bounded versioning read"
printf 'test-beta-backup-storage.sh: passed\n'
