#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow=$root/.github/workflows/prove-beta-backup-restore.yml
[ -f "$workflow" ] || exit 1
command -v jq >/dev/null 2>&1
grep -Fq 'workflow_dispatch:' "$workflow"
if grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$workflow"; then exit 1; fi
grep -Fq 'cancel-in-progress: false' "$workflow"
grep -Fq 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' "$workflow"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$workflow"
grep -Fq 'retention-days: 30' "$workflow"
grep -Fq 'closed-beta-restore' "$workflow"
grep -Fq 'restore-pre-probe' "$workflow"
grep -Fq 'restore-post-probe' "$workflow"
grep -Fq 'run-beta-recovery-restore.sh' "$workflow"
grep -Fq 'BETA_RECOVERY_AGE_IDENTITY' "$workflow"
grep -Fq 'PUBLIC_URL: https://api.whysoezzy.online' "$workflow"
grep -Fq -- '--public-url' "$workflow"
grep -Fq 'scripts/build-beta-recovery-evidence.sh validate-artifact' "$workflow"
grep -Fq 'scripts/build-beta-recovery-evidence.sh validate-runtime' "$workflow"
grep -Fq -- '--temp-root "$restore_temp"' "$workflow"
grep -Fq 'anonymous_volume_absent' "$workflow"
grep -Fq 'beta-recovery-restore-evidence-' "$workflow"
grep -Fq 'beta-recovery-drill-' "$workflow"
grep -Fq 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093' "$workflow"
grep -Fq 'Revalidate source immediately before VPS access' "$workflow"
grep -Fq 'Revalidate source immediately before identity access' "$workflow"
grep -Fq 'scp_opts=(-i "$key" -P "$PORT"' "$workflow"
grep -Fq 'unset AGE_IDENTITY' "$workflow"
grep -Fq 'transferred ciphertext differs from quiesced capture result' "$workflow"
grep -Fq 'transferred proof differs from quiesced capture result' "$workflow"
grep -Fq '.capturedAt==.recoveryPointTime' "$workflow"
grep -Fq 'observed_age=$((observed_epoch - point_epoch))' "$workflow"
grep -Fq '.created_at | (type=="string"' "$workflow"
grep -Fq '.expires_at | (type=="string"' "$workflow"
grep -Fq '30 * 24 * 60 * 60' "$workflow"
if grep -Eq '\.workflow_run\.(event|head_branch|head_sha)' "$workflow"; then
  echo "artifact validation depends on unavailable nested workflow-run fields" >&2
  exit 1
fi
artifact_fixture='{"id":7,"name":"beta-recovery-recovery-fixture-1","expired":false,"size_in_bytes":1,"workflow_run":{"id":123}}'
jq -e '.workflow_run.id == 123 and (.workflow_run.event // null) == null and
  (.workflow_run.head_branch // null) == null and (.workflow_run.head_sha // null) == null' \
  <<<"$artifact_fixture" >/dev/null
if jq -e '.event == "workflow_dispatch" or .head_branch == "dev"' <<<"$artifact_fixture" >/dev/null; then
  echo "artifact fixture unexpectedly exposed top-level run fields" >&2
  exit 1
fi
capture_db_sha=$(printf '%s\n' database-proof | sha256sum | awk '{print $1}')
capture_media_sha=$(printf '%s\n' media-proof | sha256sum | awk '{print $1}')
capture_fixture=$(jq -cn --arg db "$capture_db_sha" --arg media "$capture_media_sha" '
  {capturedAt:"2026-08-27T19:00:00Z",recoveryPointTime:"2026-08-27T19:00:00Z",
   ciphertexts:{database:{size:10,sha256:$db},uploads:{size:11,sha256:$media}},
   proofs:{database:{name:"database-proof.json",sha256:$db},
           media:{name:"media-proof.json",sha256:$media}}}')
jq -e '
  .capturedAt == .recoveryPointTime and
  all(.ciphertexts[]; (.size|type=="number") and (.sha256|test("^[0-9a-f]{64}$"))) and
  all(.proofs[]; (.sha256|test("^[0-9a-f]{64}$")))
' <<<"$capture_fixture" >/dev/null
jq -e --arg db "$capture_db_sha" --arg media "$capture_media_sha" '
  .ciphertexts.database.sha256 == $db and
  .ciphertexts.uploads.sha256 == $media and
  .proofs.database.sha256 == $db and
  .proofs.media.sha256 == $media
' <<<"$capture_fixture" >/dev/null
point_epoch=$(date -u -d 2026-08-27T19:00:00Z +%s)
observed_epoch=$((point_epoch + 120))
[ "$((observed_epoch - point_epoch))" -eq 120 ]
expiry_fixture='{"created_at":"2026-08-01T00:00:00Z","expires_at":"2026-08-31T00:00:00Z"}'
jq -e '(.created_at|type=="string") and (.expires_at|type=="string")' \
  <<<"$expiry_fixture" >/dev/null
created_epoch=$(date -u -d "$(jq -er '.created_at' <<<"$expiry_fixture")" +%s)
expires_epoch=$(date -u -d "$(jq -er '.expires_at' <<<"$expiry_fixture")" +%s)
[ "$expires_epoch" -eq "$((created_epoch + 30 * 24 * 60 * 60))" ]
short_expires_epoch=$(date -u -d 2026-08-30T00:00:00Z +%s)
if [ "$short_expires_epoch" -eq "$((created_epoch + 30 * 24 * 60 * 60))" ]; then
  echo "short artifact expiry fixture was accepted" >&2
  exit 1
fi
grep -Fq 'capture-database-proof.json' "$workflow"
if grep -Fq '${{ runner.temp }}/database-proof.json' "$workflow" ||
  grep -Fq '${{ runner.temp }}/media-proof.json' "$workflow"; then
  echo "capture proof files are incorrectly published as workflow artifacts" >&2
  exit 1
fi
if grep -Fq 'volumeName' "$workflow"; then
  echo "generated volume identity is present in workflow evidence" >&2
  exit 1
fi
if grep -Fq 'successful:true' "$workflow" || grep -Fq 'canonicalDigest:"0000000000000000000000000000000000000000000000000000000000000000' "$workflow"; then
  echo "capture workflow contains synthetic proofs" >&2
  exit 1
fi
if awk '/restore-isolated:/{flag=1} /restore-post-probe:/{flag=0} flag' "$workflow" |
  grep -Eq 'TEST_VPS|SSH_PRIVATE_KEY|TEST_VPS_HOST'; then
  echo "isolated restore job has VPS custody" >&2
  exit 1
fi
if awk '/restore-pre-probe:/{flag=1} /restore-isolated:/{flag=0} flag' "$workflow" |
  grep -F 'BETA_RECOVERY_AGE_IDENTITY'; then
  echo "pre-probe job has age identity" >&2
  exit 1
fi
if awk '/restore-post-probe:/{flag=1} /evidence:/{flag=0} flag' "$workflow" |
  grep -F 'BETA_RECOVERY_AGE_IDENTITY'; then
  echo "post-probe job has age identity" >&2
  exit 1
fi
echo "beta recovery workflow fixture passed"
