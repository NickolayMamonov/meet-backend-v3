#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-recurring-backups.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM

good_master=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
good_tooling=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
good_ci=cccccccccccccccccccccccccccccccccccccccc
policy="$tmp/policy.json"
ci="$tmp/ci.json"
cp "$root/scripts/fixtures/beta-recurring/policy-valid.json" "$policy"
sed -e "s/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/$good_tooling/g" \
  -e "s/CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/$good_ci/g" \
  "$root/scripts/fixtures/beta-recurring/ci-success.json" >"$ci"
"$root/scripts/authorize-beta-recurring.sh" \
  --event schedule --run-ref refs/heads/master --default-ref refs/heads/master \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-capture --policy-file "$policy" \
  --ci-result-file "$ci" --actor scheduler >/dev/null ||
  fail "authorized master capture was rejected"
if "$root/scripts/authorize-beta-recurring.sh" \
  --event workflow_dispatch --run-ref refs/heads/master --default-ref refs/heads/master \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-restore --policy-file "$policy" \
  --ci-result-file "$ci" --actor scheduler --reviewer scheduler >/dev/null 2>&1; then
  fail "self-review was accepted"
fi
if "$root/scripts/authorize-beta-recurring.sh" \
  --event schedule --run-ref refs/heads/dev --default-ref refs/heads/master \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-capture >/dev/null 2>&1; then
  fail "detached dev scheduler was accepted"
fi
if "$root/scripts/authorize-beta-recurring.sh" \
  --event schedule --run-ref refs/heads/master --default-ref refs/heads/dev \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-restore >/dev/null 2>&1; then
  fail "changed default branch was accepted"
fi

cat >"$tmp/capture-source.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output='' slot='' captured=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir) output=$2; shift 2 ;;
    --slot) slot=$2; shift 2 ;;
    --captured-at) captured=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
mkdir -p "$output"
printf 'real database capture\n' >"$output/postgres.dump"
printf 'real media capture\n' >"$output/uploads.tar.gz"
db_sha=$(sha256sum "$output/postgres.dump" | awk '{print $1}')
media_sha=$(sha256sum "$output/uploads.tar.gz" | awk '{print $1}')
jq -cnS --arg slot "$slot" --arg source "$CAPTURE_SOURCE_REVISION" \
  --arg command "$EXPECTED_CAPTURE_COMMAND_DIGEST" --argjson captured "$captured" \
  --arg db_sha "$db_sha" --arg media_sha "$media_sha" \
  --argjson db_len "$(wc -c <"$output/postgres.dump")" \
  --argjson media_len "$(wc -c <"$output/uploads.tar.gz")" \
  '{schema:"meet-backend/beta-recurring-capture-source/v1",slotId:$slot,
    capturedAt:$captured,sourceRevision:$source,captureCommandDigest:$command,
    database:{length:$db_len,sha256:$db_sha},media:{length:$media_len,sha256:$media_sha}}' \
  >"$output/capture-result.json"
EOF
chmod 755 "$tmp/capture-source.sh"
capture_digest=$(sha256sum "$tmp/capture-source.sh" | awk '{print $1}')
cat >"$tmp/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'v1.3.1\n'; exit 0; fi
output='' input=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -r) shift 2 ;;
    -o) output=$2; shift 2 ;;
    *) input=$1; shift ;;
  esac
done
[ -n "$output" ] && [ -f "$input" ]
printf 'age-encryption.org/v1\n' >"$output"
cat "$input" >>"$output"
EOF
chmod 755 "$tmp/age"
printf '%s\n' age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m >"$tmp/recipient"
export CAPTURE_SOURCE_REVISION="$good_master"
export EXPECTED_CAPTURE_COMMAND_DIGEST="$capture_digest"
export BETA_BACKUP_STORAGE_ROOT="$tmp/storage"
contract_digest=$(printf contract | sha256sum | awk '{print $1}')
proof_digest=$(printf proof | sha256sum | awk '{print $1}')
capture_args=(
  --output "$tmp/point" --slot 1790000000 --captured-at 1790000000
  --source-revision "$good_master" --runtime-revision "$good_tooling"
  --contract-digest "$contract_digest" --proof-digest "$proof_digest"
  --capture-command "$tmp/capture-source.sh" --capture-output "$tmp/source"
  --age-binary "$tmp/age" --age-recipient-file "$tmp/recipient"
)
"$root/scripts/run-beta-recurring-capture.sh" "${capture_args[@]}" >/dev/null ||
  fail "real capture and encryption were rejected"
[ -f "$tmp/storage/points/slot-1790000000/point.json" ] ||
  fail "capture descriptor is incomplete"
[ ! -e "$tmp/source/postgres.dump" ] && [ ! -e "$tmp/source/uploads.tar.gz" ] ||
  fail "plaintext capture survived cleanup"
jq -e '.versions.database and .versions.uploads and .versions.manifest and
  (.captureCommandDigest==$cmd)' --arg cmd "$capture_digest" \
  "$tmp/storage/points/slot-1790000000/point.json" >/dev/null ||
  fail "descriptor provenance is incomplete"

"$root/scripts/run-beta-recurring-capture.sh" \
  "${capture_args[@]}" --output "$tmp/point-replay" --capture-output "$tmp/source-replay" \
  >/dev/null || fail "successful slot replay was rejected"

cat >"$tmp/restore-command.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
point='' output='' proof='' capture='' restore='' protection=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --point-dir) point=$2; shift 2 ;;
    --identity-file) identity=$2; shift 2 ;;
    --output-dir) output=$2; shift 2 ;;
    --proof-output) proof=$2; shift 2 ;;
    --capture-revision) capture=$2; shift 2 ;;
    --restore-revision) restore=$2; shift 2 ;;
    --protection-digest) protection=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
[ -s "$identity" ] && [ -d "$output" ] && [ -z "$(find "$output" -mindepth 1 -print -quit)" ]
descriptor=$(sha256sum "$point/point.json" | awk '{print $1}')
captured=$(jq -er '.capture.capturedAt' "$point/recovery-point.json")
fingerprint=$(printf 'isolated-runtime\n' | sha256sum | awk '{print $1}')
jq -cnS --arg capture "$capture" --arg restore "$restore" \
  --arg descriptor "$descriptor" --argjson captured "$captured" \
  --arg fingerprint "$fingerprint" --arg protection "$protection" \
  '{schema:"meet-backend/beta-recurring-restore-proof/v2",
    captureRevision:$capture,restoreRevision:$restore,capturedAt:$captured,
    pointDescriptorDigest:$descriptor,protectionDigest:$protection,
    identityCustody:"restore-only",
    isolated:true,databaseProbe:true,mediaProbe:true,cleanup:true,
    preFingerprint:$fingerprint,postFingerprint:$fingerprint}' >"$proof"
EOF
chmod 755 "$tmp/restore-command.sh"
printf 'private restore identity\n' >"$tmp/identity"
protection_body="$tmp/protection-body.json"
protection="$tmp/protection.json"
jq -cnS --arg reviewer reviewer-1 \
  '{schema:"meet-backend/beta-recurring-restore-protection/v1",environment:"closed-beta-recurring-restore",
    branchPolicy:"refs/heads/master",reviewerId:$reviewer,
    reviewerRequired:true,preventSelfReview:true,adminBypassAllowed:false}' >"$protection_body"
protection_digest=$(sha256sum "$protection_body" | awk '{print $1}')
jq --arg digest "$protection_digest" '. + {protectionDigest:$digest}' \
  "$protection_body" >"$protection"
drill_receipt="$tmp/protected-receipt.json"
"$root/scripts/run-beta-recurring-drill.sh" \
  --storage-root "$tmp/storage" --point-id slot-1790000000 --receipt "$drill_receipt" \
  --restore-command "$tmp/restore-command.sh" --restore-output "$tmp/restore-output" \
  --identity-file "$tmp/identity" --capture-revision "$good_master" \
  --restore-revision "$good_tooling" --reviewer-id reviewer-1 \
  --protection-file "$protection" --protection-digest "$protection_digest" ||
  fail "generated protected restore proof was rejected"
jq -e '.schema=="meet-backend/beta-backup-receipt/v2" and
  .pointDescriptorDigest and .captureAt==1790000000' "$drill_receipt" >/dev/null ||
  fail "provenance-bound receipt was not emitted"
if "$root/scripts/run-beta-recurring-drill.sh" \
  --storage-root "$tmp/storage" --point-id slot-1790000000 --receipt "$tmp/invalid-receipt" \
  --proof-file "$tmp/supplied-proof" >/dev/null 2>&1; then
  fail "supplied proof-only drill was accepted"
fi
if "$root/scripts/authorize-beta-recurring.sh" \
  --event workflow_dispatch --run-ref refs/heads/master --default-ref refs/heads/master \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-restore --policy-file "$policy" \
  --ci-result-file "$ci" --actor scheduler --reviewer scheduler >/dev/null 2>&1; then
  fail "restore self-review remained admissible"
fi
policy_digest=$(sha256sum "$policy" | awk '{print $1}')
approval_body="$tmp/approval-body.json"
approval="$tmp/approval.json"
post_approval="$tmp/post-approval.json"
jq -cnS --arg policy "$policy_digest" \
  '{schema:"meet-backend/beta-backup-custody-approval/v1",
    environment:"closed-beta-recurring-restore",branchPolicy:"refs/heads/master",
    reviewerLogin:"reviewer",reviewerId:"reviewer-1",reviewerRequired:true,
    preventSelfReview:true,adminBypassAllowed:false,policyDigest:$policy,
    approvalRunId:"run-1",approvedAt:1790000000}' >"$approval_body"
approval_protection_digest=$(sha256sum "$approval_body" | awk '{print $1}')
jq --arg digest "$approval_protection_digest" '. + {protectionDigest:$digest}' \
  "$approval_body" >"$approval"
jq '.approvalRunId="run-2" | del(.protectionDigest)' "$approval" >"$tmp/post-body.json"
post_protection_digest=$(sha256sum "$tmp/post-body.json" | awk '{print $1}')
jq --arg digest "$post_protection_digest" '. + {protectionDigest:$digest}' \
  "$tmp/post-body.json" >"$post_approval"
if BETA_RECURRING_REQUIRE_APPROVAL=true \
  "$root/scripts/authorize-beta-recurring.sh" \
    --event workflow_dispatch --run-ref refs/heads/master --default-ref refs/heads/master \
    --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
    --environment closed-beta-recurring-restore --policy-file "$policy" \
    --ci-result-file "$ci" --actor scheduler --reviewer reviewer \
    --reviewer-id reviewer-1 --approval-file "$approval" \
    --post-approval-file "$post_approval" >/dev/null 2>&1; then
  fail "post-approval custody drift remained admissible"
fi
printf 'test-beta-recurring-backups.sh: passed\n'
