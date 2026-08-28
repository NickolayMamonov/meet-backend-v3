#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
builder=$root/scripts/build-beta-recovery-evidence.sh
tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM

hash=$(printf x | sha256sum | awk '{print $1}')
db_proof=$tmp/database-proof.json
media_proof=$tmp/media-proof.json
runtime=$tmp/capture-runtime.json
for file in postgres.dump.age uploads.tar.gz.age; do
  dd if=/dev/zero of="$tmp/$file" bs=1 count=1 status=none
done
jq -cn '{schema:"meet-backend/closed-beta-database-proof/v1",rows:{users:1}}' >"$db_proof"
jq -cn --arg hash "$hash" '
  {schema:"meet-backend/beta-recovery-media-proof/v1",files:1,bytes:1,
   canonicalDigest:$hash,referencesTotal:1,referencesResolved:true}
' >"$media_proof"
jq -cn --arg hash "$hash" '
  {schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
   runtime:{imageId:"sha256:test",configHash:$hash,health:"healthy",uploadsMount:"volume"},
   https:{meetingsStatus:"200",actuatorStatus:"404",httpRedirectHttps:true,meetingsJson:true}}
' >"$runtime"

bash "$builder" manifest \
  --recovery-id recovery-0001 --source-sha 0123456789abcdef0123456789abcdef01234567 \
  --repository NickolayMamonov/meet-backend-v3 --run-id 1 \
  --artifact-name beta-recovery-recovery-0001-1 \
  --tooling-digest "$hash" --workflow-digest "$hash" --database-digest "$hash" --media-digest "$hash" \
  --captured-at 2026-08-27T19:00:00Z --point-time 2026-08-27T19:00:00Z \
  --observed-age-seconds 120 \
  --database-bytes 1 --uploads-files 1 --uploads-bytes 1 --uploads-digest "$hash" \
  --database-proof "$db_proof" --media-proof "$media_proof" --runtime-proof "$runtime" \
  --database-ciphertext "$tmp/postgres.dump.age" --uploads-ciphertext "$tmp/uploads.tar.gz.age" \
  --output "$tmp/recovery-point.json"
mkdir "$tmp/artifact"
cp -- "$tmp/postgres.dump.age" "$tmp/uploads.tar.gz.age" \
  "$tmp/recovery-point.json" "$tmp/artifact/"
bash "$builder" validate-artifact --artifact-dir "$tmp/artifact" \
  --recovery-id recovery-0001 --source-sha 0123456789abcdef0123456789abcdef01234567 \
  --repository NickolayMamonov/meet-backend-v3 --run-id 1
jq -e '.schema == "meet-backend/beta-recovery-manifest/v1" and
  .retentionDays == 30 and .observedAgeSeconds == 120 and (.artifactFiles | length == 2)' \
  "$tmp/recovery-point.json" >/dev/null

cp -- "$runtime" "$tmp/pre.json"
cp -- "$runtime" "$tmp/post.json"
jq -cn '{schema:"meet-backend/beta-recovery-mount/v1",type:"volume",
  destination:"/var/lib/postgresql/data",readWrite:true,anonymous:true}' \
  >"$tmp/mount.json"
bash "$builder" final \
  --recovery-id recovery-0001 --source-sha 0123456789abcdef0123456789abcdef01234567 \
  --repository NickolayMamonov/meet-backend-v3 --run-id 1 \
  --artifact-id 7 --artifact-name beta-recovery-recovery-0001-1 \
  --manifest "$tmp/recovery-point.json" --database-proof "$db_proof" --media-proof "$media_proof" \
  --restored-database-proof "$db_proof" --restored-media-proof "$media_proof" \
  --pre-probe "$tmp/pre.json" --post-probe "$tmp/post.json" --mount-contract "$tmp/mount.json" \
  --dispatch-at 2026-08-27T19:00:00Z --post-probe-at 2026-08-27T19:10:00Z \
  --healthy true --equal true --artifact-verified true --cleanup-complete true \
  --anonymous-volume-absent true --status success --output "$tmp/drill.json"
jq -e '.schema == "meet-backend/beta-recovery-drill/v1" and
  .artifact.id == 7 and .observedAgeSeconds == 120 and .restore.mountContract.anonymous == true and
  (.restore.mountContract | has("volumeName") | not) and
  .timing.dispatchToPostProbeSeconds == 600' "$tmp/drill.json" >/dev/null

bash "$builder" incident --recovery-id recovery-0001 \
  --failure-class cleanupFailure --output "$tmp/incident.json"
jq -e '.sanitized == true and .failureClass == "cleanupFailure"' "$tmp/incident.json" >/dev/null
if grep -Eiq -- '-----BEGIN .*PRIVATE KEY-----|postgres(ql)?://|password[=:]|secret[=:]|token[=:]' \
  "$tmp"/*.json "$tmp/artifact"/*.json; then
  exit 1
fi
echo "beta recovery evidence fixture passed"
