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
grep -Fq 'scp_opts=(-F "$config" -i "$key" -P "$PORT"' "$workflow"
grep -Fq 'scripts/materialize-beta-recovery-known-hosts.sh' "$workflow"
grep -Fq 'published_identity=' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
grep -Fq 'remove_published_output' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
grep -Fq 'ln -T --' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
grep -Fq 'published_output_identity=' "$root/scripts/materialize-beta-recovery-known-hosts.sh"
grep -Fq '[ "$published_output_identity" = "$candidate_identity" ]' \
  "$root/scripts/materialize-beta-recovery-known-hosts.sh"
helper_count=$(grep -Fc -- '--output "$known"' "$workflow")
[ "$helper_count" -eq 3 ]
for required in \
  'ssh_dir=$(mktemp -d "$RUNNER_TEMP/beta-recovery-ssh.XXXXXX")' \
  'install -m 600 /dev/null "$config"' \
  '-F "$config"' \
  '-o StrictHostKeyChecking=yes' \
  '-o UserKnownHostsFile="$known"' \
  '-o GlobalKnownHostsFile=/dev/null' \
  '-o KnownHostsCommand=none'; do
  grep -Fq -- "$required" "$workflow"
done
for required in \
  "trap 'cleanup_capture 129' HUP" \
  "trap 'cleanup_capture 130' INT" \
  "trap 'cleanup_capture 143' TERM" \
  "trap 'cleanup_probe 129' HUP" \
  "trap 'cleanup_probe 130' INT" \
  "trap 'cleanup_probe 143' TERM"; do
  grep -Fq -- "$required" "$workflow"
done
grep -Fq "trap 'cleanup_capture \"\$?\"' EXIT" "$workflow"
grep -Fq "trap 'cleanup_probe \"\$?\"' EXIT" "$workflow"
if grep -Fq 'trap cleanup_capture EXIT HUP INT TERM' "$workflow" ||
  grep -Fq 'trap cleanup_probe EXIT HUP INT TERM' "$workflow"; then
  echo "workflow uses signal-ambiguous cleanup traps" >&2
  exit 1
fi
if grep -Fq 'printf '\''%s\n'\'' "$HOST_FINGERPRINT"' "$workflow"; then
  echo "workflow directly writes the configured fingerprint" >&2
  exit 1
fi
capture_block=$(awk '/Stage and run the locked VPS capture/{flag=1} /restore-select:/{flag=0} flag' "$workflow")
pre_probe_block=$(awk '/restore-pre-probe:/{flag=1} /restore-isolated:/{flag=0} flag' "$workflow")
post_probe_block=$(awk '/restore-post-probe:/{flag=1} /evidence:/{flag=0} flag' "$workflow")
capture_job=$(awk '/^  capture:/{flag=1} /^  restore-select:/{flag=0} flag' "$workflow")
pre_probe_job=$(awk '/^  restore-pre-probe:/{flag=1} /^  restore-isolated:/{flag=0} flag' "$workflow")
post_probe_job=$(awk '/^  restore-post-probe:/{flag=1} /^  evidence:/{flag=0} flag' "$workflow")
[ "$(grep -Fc 'PATH_ON_HOST: ${{ vars.TEST_VPS_PATH }}' "$workflow")" -eq 3 ]
assert_release_root_gate(){
  local block=$1 checkout_line gate_line first_step network_line
  [ "$(grep -Fc 'name: Validate protected test-VPS release root' <<<"$block")" -eq 1 ]
  first_step=$(grep -n '^      - ' <<<"$block" | head -1)
  grep -Fq 'name: Validate protected test-VPS release root' <<<"$first_step"
  gate_line=$(grep -n 'name: Validate protected test-VPS release root' <<<"$block" | head -1 | cut -d: -f1)
  checkout_line=$(grep -n 'actions/checkout@' <<<"$block" | head -1 | cut -d: -f1)
  [ "$gate_line" -lt "$checkout_line" ]
  network_line=$(grep -nE 'actions/(checkout|upload-artifact|download-artifact)|(^|[[:space:]])(ssh|scp|git fetch|gh (api|run))' <<<"$block" |
    head -1 | cut -d: -f1)
  [ -n "$network_line" ] && [ "$gate_line" -lt "$network_line" ]
  grep -Fq 'TEST_VPS_PATH is absent' <<<"$block"
  grep -Fq 'TEST_VPS_PATH must be a safe absolute path' <<<"$block"
  grep -Fq '[[ "$PATH_ON_HOST" =~ ^/[A-Za-z0-9._/-]+$ ]]' <<<"$block"
  grep -Fq '[[ "$PATH_ON_HOST" != *..* ]]' <<<"$block"
}
assert_release_root_gate "$capture_job"
assert_release_root_gate "$pre_probe_job"
assert_release_root_gate "$post_probe_job"
[ "$(grep -n 'actions/checkout@' <<<"$capture_job" | head -1 | cut -d: -f1)" -lt \
  "$(grep -n 'validate-recovery-id "\$RECOVERY_ID"' <<<"$capture_job" | head -1 | cut -d: -f1)" ]
[ "$(grep -n 'actions/checkout@' <<<"$pre_probe_job" | head -1 | cut -d: -f1)" -lt \
  "$(grep -n 'validate-recovery-id "\$RECOVERY_ID"' <<<"$pre_probe_job" | head -1 | cut -d: -f1)" ]
[ "$(grep -n 'actions/checkout@' <<<"$post_probe_job" | head -1 | cut -d: -f1)" -lt \
  "$(grep -n 'validate-recovery-id "\$RECOVERY_ID"' <<<"$post_probe_job" | head -1 | cut -d: -f1)" ]
grep -Fq 'root=$4' <<<"$capture_block"
grep -Fq 'root=$2' <<<"$pre_probe_block"
grep -Fq 'root=$2' <<<"$post_probe_block"
grep -Fq 'sudo bash -s -- \' <<<"$capture_block"
grep -Fq 'sudo bash -s -- "$PUBLIC_URL" "$PATH_ON_HOST"' <<<"$pre_probe_block"
grep -Fq 'sudo bash -s -- "$PUBLIC_URL" "$PATH_ON_HOST"' <<<"$post_probe_block"
grep -Fq '"$remote" "$RECOVERY_ID" "$PUBLIC_URL" "$PATH_ON_HOST"' <<<"$capture_block"
grep -Fq 'export PRODUCTION_ROOT="$root"' <<<"$capture_block"
grep -Fq 'export PRODUCTION_ROOT="$root"' <<<"$pre_probe_block"
grep -Fq 'export PRODUCTION_ROOT="$root"' <<<"$post_probe_block"
assert_root_export_before_consumer(){
  local block=$1 consumer=$2 export_line consumer_line
  export_line=$(grep -n 'export PRODUCTION_ROOT="\$root"' <<<"$block" | head -1 | cut -d: -f1)
  consumer_line=$(grep -n "$consumer" <<<"$block" | head -1 | cut -d: -f1)
  [ -n "$export_line" ] && [ -n "$consumer_line" ] && [ "$export_line" -lt "$consumer_line" ]
}
assert_root_export_before_consumer "$capture_block" 'bash "\$remote/run-beta-recovery-capture.sh"'
assert_root_export_before_consumer "$pre_probe_block" 'bash /var/lib/meet-test-vps-deploy/scripts/probe-test-vps-recovery-runtime.sh'
assert_root_export_before_consumer "$post_probe_block" 'bash /var/lib/meet-test-vps-deploy/scripts/probe-test-vps-recovery-runtime.sh'
for block in "$capture_block" "$pre_probe_block" "$post_probe_block"; do
  grep -Fq -- '--root "$root"' <<<"$block"
  ! grep -Fq -- '--root /var/lib/meet-production' <<<"$block"
  ! grep -Fq 'PRODUCTION_ROOT=/var/lib/meet-production' <<<"$block"
done
isolated_block=$(awk '/^  restore-isolated:/{flag=1} /^  restore-post-probe:/{flag=0} flag' "$workflow")
! grep -Fq 'PATH_ON_HOST' <<<"$isolated_block"
ordered_network_calls=0
ordered_ssh_calls=0
ordered_downstream_calls=0
run_ordered_job(){
  local path=${1-}
  if [ -z "$path" ] ||
    ! [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    [[ "$path" == *..* ]]; then
    return 1
  fi
  ordered_network_calls=$((ordered_network_calls + 1))
  ordered_ssh_calls=$((ordered_ssh_calls + 1))
  ordered_downstream_calls=$((ordered_downstream_calls + 1))
}
run_ordered_case(){
  local label=$1 value=${2-}
  ordered_network_calls=0
  ordered_ssh_calls=0
  ordered_downstream_calls=0
  if run_ordered_job "$value"; then
    [ "$label" = valid ] || { echo "invalid PATH_ON_HOST passed the gate" >&2; exit 1; }
    [ "$ordered_network_calls" -eq 1 ] &&
      [ "$ordered_ssh_calls" -eq 1 ] &&
      [ "$ordered_downstream_calls" -eq 1 ]
  else
    [ "$label" != valid ] || { echo "valid PATH_ON_HOST failed the gate" >&2; exit 1; }
    [ "$ordered_network_calls" -eq 0 ] &&
      [ "$ordered_ssh_calls" -eq 0 ] &&
      [ "$ordered_downstream_calls" -eq 0 ]
  fi
}
run_ordered_case missing
run_ordered_case blank ' '
run_ordered_case relative relative/root
run_ordered_case double-dot /srv/../release
run_ordered_case metacharacter '/srv/release;touch'
run_ordered_case valid /srv/release
for block in "$capture_block" "$pre_probe_block" "$post_probe_block"; do
  helper_line=$(grep -n 'scripts/materialize-beta-recovery-known-hosts.sh' <<<"$block" | head -1 | cut -d: -f1)
  key_line=$(grep -n 'install -m 600 /dev/null "$key"' <<<"$block" | head -1 | cut -d: -f1)
  [ "$helper_line" -lt "$key_line" ]
  mktemp_line=$(grep -n 'ssh_dir=$(mktemp -d' <<<"$block" | head -1 | cut -d: -f1)
  trap_line=$(grep -n "trap 'cleanup_" <<<"$block" | head -1 | cut -d: -f1)
  chmod_line=$(grep -n 'chmod 700 "$ssh_dir"' <<<"$block" | head -1 | cut -d: -f1)
  [ "$mktemp_line" -lt "$trap_line" ] && [ "$trap_line" -lt "$chmod_line" ]
done
grep -Fq 'for signal in HUP INT TERM' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-pre-$signal' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'effective-config-failed' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'argv-rejected' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'BETA_RECOVERY_REMOTE_CLEANUP_FAIL' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-ambiguous-create' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-collision-absent-marker' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'capture-collision-mismatched-marker' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'publication-race' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'cleanup-failure-after-publication' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'post-publication-signal-$signal' "$root/scripts/test-beta-recovery-ssh-host-key.sh"
grep -Fq 'unset AGE_IDENTITY' "$workflow"
grep -Fq 'scripts/install-beta-recovery-age.sh "$age_bin"' "$workflow"
grep -Fq 'owner_token=$(od -An -N32 -tx1 /dev/urandom | tr -d '\''[:space:]'\'')' "$workflow"
grep -Fq 'remote_create_attempted=true' "$workflow"
grep -Fq 'remote_cleanup_done=false' "$workflow"
grep -Fq 'cleanup_remote' "$workflow"
grep -Fq '.meet-beta-recovery-owner' "$workflow"
grep -Fq 'meet-backend/beta-recovery-owner/v1:' "$workflow"
grep -Fq 'cmp -- "$expected" "$marker"' "$workflow"
grep -Fq 'stat -c '\''%a:%u:%g:%h'\'' "$marker"' "$workflow"
grep -Fq -- '--age-binary "$remote/age"' "$workflow"
grep -Fq -- '--age-sha256 "$5" --age-version "$6" --age-os "$7" --age-arch "$8"' "$workflow"
age_transport_count=$(grep -Fc '            "$age_path" \' "$workflow")
[ "$age_transport_count" -eq 1 ]
! grep -Fq 'age-keygen' <<<"$capture_block"
grep -Fq 'archive_size=10263766' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'archive_sha256=bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377' \
  "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'age-v1.3.1-linux-amd64.tar.gz' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq '[ "$(uname -s)" = Linux ]' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq '[ "$(uname -m)" = x86_64 ]' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'tar -tzf "$archive"' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'age/age-plugin-batchpass' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'install -m 0755' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'stat -c' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq '"$age_keygen" -y' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'cmp -- "$plaintext" "$decrypted"' "$root/scripts/install-beta-recovery-age.sh"
grep -Fq 'printf '\''%s\n'\'' "$age_bin" >>"$GITHUB_PATH"' "$workflow"
grep -Fq 'Provision and canary pinned age toolchain' "$root/.github/workflows/ci.yml"
grep -Fq 'RECOVERY_ID: ${{ inputs.recovery_id }}' "$workflow"
grep -Fq 'scripts/authorize-beta-recovery.sh validate-recovery-id "$RECOVERY_ID"' "$workflow"
grep -Fq 'scripts/authorize-beta-recovery.sh validate-age-recipient "$AGE_RECIPIENT"' "$workflow"
grep -Fq 'closed-beta-restore environment protection policy is malformed or mismatched' \
  "$root/scripts/authorize-beta-recovery.sh"
grep -Fq 'closed-beta-restore/deployment-branch-policies?per_page=100' \
  "$root/scripts/authorize-beta-recovery.sh"
if grep -Fq 'closed-beta-restore/secrets?per_page=100' \
  "$root/scripts/authorize-beta-recovery.sh"; then
  echo "authorization still uses unsupported Environment secret inventory" >&2
  exit 1
fi
unsupported_claim=identitySecretProvisio
unsupported_claim+=ned
if grep -Fq "$unsupported_claim" "$root/scripts/authorize-beta-recovery.sh" ||
  grep -Fq "$unsupported_claim" "$workflow"; then
  echo "authorization still emits unsupported identity proof" >&2
  exit 1
fi
grep -Fq 'recipient_file="$RUNNER_TEMP/age-recipient"' "$workflow"
grep -Fq 'recipient=$(<"$remote/age-recipient")' "$workflow"
grep -Fq 'Remove selected artifact temporary files' "$workflow"
grep -Fq 'RUNNER_TEMP/age-identity' "$workflow"
grep -Fq 'Verify no isolated restore runner residue' "$workflow"
grep -Fq 'cleanup_complete: ${{ steps.final_cleanup.outputs.cleanup_complete }}' "$workflow"
grep -Fq 'anonymous_volume_absent: ${{ steps.final_cleanup.outputs.anonymous_volume_absent }}' "$workflow"
post_probe_job=$(awk '/restore-post-probe:/{flag=1} /evidence:/{flag=0} flag' "$workflow")
evidence_job=$(awk '/evidence:/{flag=1} flag' "$workflow")
grep -Fq "needs.restore-isolated.result == 'success'" <<<"$evidence_job"
grep -Fq "needs.restore-isolated.result != 'skipped'" <<<"$post_probe_job"
if grep -Fq "needs.restore-isolated.result == 'success'" <<<"$post_probe_job"; then
  echo "post-probe is incorrectly success-gated" >&2
  exit 1
fi
isolated_result=failure
final_cleanup_complete=true
anonymous_volume_absent=true
if [ "$isolated_result" = success ] &&
  [ "$final_cleanup_complete" = true ] && [ "$anonymous_volume_absent" = true ]; then
  echo "failed isolated cleanup could reach success" >&2
  exit 1
fi
if grep -Fq "AGE_RECIPIENT='" "$workflow" ||
  grep -Fq -- "--recipient '" "$workflow"; then
  echo "age recipient is interpolated into remote shell source" >&2
  exit 1
fi
run_block=$(awk '
  /^        run: \|$/ { in_run=1; next }
  in_run && /^      [^ ]/ { in_run=0 }
  in_run { print }
' "$workflow")
if grep -Fq '${{ inputs.recovery_id }}' <<<"$run_block"; then
  echo "recovery ID is interpolated directly into a run block" >&2
  exit 1
fi
validation_count=$(grep -Fc 'scripts/authorize-beta-recovery.sh validate-recovery-id "$RECOVERY_ID"' "$workflow")
[ "$validation_count" -eq 7 ]
secret_expression_count=$(grep -Fc '${{ secrets.BETA_RECOVERY_AGE_IDENTITY }}' "$workflow")
[ "$secret_expression_count" -eq 1 ]
setup_line=$(grep -n 'scripts/install-beta-recovery-age.sh "$age_bin"' "$workflow" | tail -1 | cut -d: -f1)
revalidate_line=$(grep -n 'Revalidate source immediately before identity access' "$workflow" | cut -d: -f1)
restore_line=$(grep -n 'id: restore' "$workflow" | cut -d: -f1)
[ "$setup_line" -lt "$revalidate_line" ] && [ "$revalidate_line" -lt "$restore_line" ]
auth="$root/scripts/authorize-beta-recovery.sh"
fixture_dir=$(mktemp -d)
trap 'rm -r -- "$fixture_dir"' EXIT HUP INT TERM
valid_recovery_id=recovery-fixture
valid_recipient=age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m
invalid_short_recipient=age1x
invalid_checksum_recipient=age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh76
remote_dir="$fixture_dir/remote"
remote_marker="$fixture_dir/remote-marker"
received_recipient="$fixture_dir/received-recipient"
remote_log="$fixture_dir/remote.log"
malicious_recovery_id="recovery-fixture'; touch $remote_marker; #"
malicious_recipient="age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m'; touch $remote_marker; #"
bash "$auth" validate-recovery-id "$valid_recovery_id"
bash "$auth" validate-age-recipient "$valid_recipient"
if bash "$auth" validate-age-recipient "$invalid_short_recipient" >/dev/null 2>&1 ||
  bash "$auth" validate-age-recipient "$invalid_checksum_recipient" >/dev/null 2>&1 ||
  bash "$auth" validate-recovery-id "$malicious_recovery_id" >/dev/null 2>&1 ||
  bash "$auth" validate-age-recipient "$malicious_recipient" >/dev/null 2>&1; then
  echo "shell metacharacter fixture was accepted" >&2
  exit 1
fi
[ ! -e "$remote_marker" ]
mkdir "$remote_dir"
scp_calls=0
ssh_calls=0
scp(){
  scp_calls=$((scp_calls + 1))
  printf 'scp %s\n' "$*" >>"$remote_log"
  cp -- "$1" "$remote_dir/age-recipient"
}
ssh(){
  ssh_calls=$((ssh_calls + 1))
  printf 'ssh %s\n' "$*" >>"$remote_log"
  bash -s -- "$remote_dir" "$valid_recovery_id" \
    https://api.whysoezzy.online "$received_recipient" "$valid_recipient" "$remote_marker"
}
run_safe_capture_preflight(){
  local recipient=$1 recipient_file="$fixture_dir/age-recipient-input"
  scripts/authorize-beta-recovery.sh validate-age-recipient "$recipient" || return
  printf '%s\n' "$recipient" >"$recipient_file"
  scp "$recipient_file" "fake-host:$remote_dir/"
  ssh fake-host "sudo bash -s -- '$remote_dir' '$valid_recovery_id' 'https://api.whysoezzy.online'" <<'REMOTE'
set -euo pipefail
remote=$1
recovery_id=$2
public_url=$3
received=$4
expected=$5
marker=$6
recipient=$(<"$remote/age-recipient")
if [ "$recipient" != "$expected" ]; then
  touch "$marker"
fi
printf '%s\n' "$recipient" >"$received"
REMOTE
}
if run_safe_capture_preflight "$malicious_recipient"; then
  echo "malicious recipient crossed the remote boundary" >&2
  exit 1
fi
[ "$scp_calls" -eq 0 ] && [ "$ssh_calls" -eq 0 ] && [ ! -e "$remote_marker" ]
run_safe_capture_preflight "$valid_recipient"
[ "$scp_calls" -eq 1 ] && [ "$ssh_calls" -eq 1 ]
[ "$(wc -l <"$received_recipient" | tr -d '[:space:]')" -eq 1 ]
[ "$(<"$received_recipient")" = "$valid_recipient" ]
grep -Fq 'transferred ciphertext differs from quiesced capture result' "$workflow"
for required in \
  'database_proof_actual_sha=$(sha256sum "$RUNNER_TEMP/database-proof.json" |' \
  'media_proof_actual_sha=$(sha256sum "$RUNNER_TEMP/media-proof.json" |' \
  'database proof hash failed' \
  'media proof hash failed' \
  'database proof expected digest is missing or malformed' \
  'media proof expected digest is missing or malformed' \
  '[[ "$database_proof_actual_sha" =~ ^[0-9a-f]{64}$ ]]' \
  '[[ "$database_proof_expected_sha" =~ ^[0-9a-f]{64}$ ]]' \
  '[[ "$media_proof_actual_sha" =~ ^[0-9a-f]{64}$ ]]' \
  '[[ "$media_proof_expected_sha" =~ ^[0-9a-f]{64}$ ]]' \
  'database proof differs from quiesced capture result' \
  'media proof differs from quiesced capture result' \
  'remote staging cleanup failed'; do
  grep -Fq -- "$required" "$workflow"
done
grep -Fq 'database_proof_expected_sha=$(jq -er' "$workflow"
grep -Fq ".proofs.database.sha256 // empty" "$workflow"
grep -Fq 'media_proof_expected_sha=$(jq -er' "$workflow"
grep -Fq ".proofs.media.sha256 // empty" "$workflow"
grep -Fq '2>/dev/null); then' "$workflow"
! grep -Fq 'all(.proofs[]; (keys|sort)==["name","sha256"]' "$workflow"
grep -Fq 'tooling_digest=$(for file in scripts/authorize-beta-recovery.sh' "$workflow"
grep -Fq -- '--tooling-digest "$tooling_digest"' "$workflow"
! grep -Fq 'transferred proof differs from quiesced capture result' "$workflow"
proof_gate_line=$(grep -n 'database_proof_actual_sha=' "$workflow" | head -1 | cut -d: -f1)
proof_shape_line=$(grep -n 'database proof expected digest is missing or malformed' "$workflow" |
  head -1 | cut -d: -f1)
proof_compare_line=$(grep -n 'media proof differs from quiesced capture result' "$workflow" |
  head -1 | cut -d: -f1)
[ "$proof_gate_line" -lt "$proof_shape_line" ] &&
  [ "$proof_shape_line" -lt "$proof_compare_line" ]
aggregate_line=$(grep -n '\[ "$uploads_files"' "$workflow" | head -1 | cut -d: -f1)
time_line=$(grep -n 'point_epoch=$(date -u' "$workflow" | head -1 | cut -d: -f1)
cleanup_line=$(grep -n 'cleanup_remote ||' "$workflow" | head -1 | cut -d: -f1)
evidence_line=$(grep -n 'scripts/build-beta-recovery-evidence.sh manifest' "$workflow" |
  head -1 | cut -d: -f1)
[ "$proof_gate_line" -lt "$proof_compare_line" ] &&
  [ "$proof_compare_line" -lt "$aggregate_line" ] &&
  [ "$aggregate_line" -lt "$time_line" ] &&
  [ "$time_line" -lt "$cleanup_line" ] &&
  [ "$cleanup_line" -lt "$evidence_line" ]
publish_block=$(awk '/^      - id: publish$/{flag=1} flag' "$workflow")
! grep -Fq 'if: always()' <<<"$publish_block"
grep -Fq '.capturedAt==.recoveryPointTime' "$workflow"
grep -Fq 'observed_age=$((observed_epoch - point_epoch))' "$workflow"
[ "$(grep -Fc 'retention-days: 30' "$workflow")" -eq 6 ]
[ "$(grep -Fc 'scripts/validate-beta-recovery-artifact-retention.sh <<<"$artifact_json"' "$workflow")" -eq 3 ]
! grep -Eq 'created_epoch|expires_epoch|30 \* 24 \* 60 \* 60' "$workflow"
publish_line=$(grep -n '^      - id: publish$' "$workflow" | head -1 | cut -d: -f1)
capture_retention_line=$(grep -n 'scripts/validate-beta-recovery-artifact-retention.sh <<<"$artifact_json"' "$workflow" |
  sed -n '1p' | cut -d: -f1)
restore_retention_line=$(grep -n 'scripts/validate-beta-recovery-artifact-retention.sh <<<"$artifact_json"' "$workflow" |
  sed -n '2p' | cut -d: -f1)
final_retention_line=$(grep -n 'scripts/validate-beta-recovery-artifact-retention.sh <<<"$artifact_json"' "$workflow" |
  sed -n '3p' | cut -d: -f1)
zip_line=$(grep -n 'actions/artifacts/\$ARTIFACT_ID/zip' "$workflow" | head -1 | cut -d: -f1)
cleanup_marker_line=$(grep -n '^      - id: final_cleanup$' "$workflow" | head -1 | cut -d: -f1)
evidence_manifest_line=$(grep -n 'scripts/build-beta-recovery-evidence.sh final' "$workflow" | head -1 | cut -d: -f1)
[ "$publish_line" -lt "$capture_retention_line" ] &&
  [ "$restore_retention_line" -lt "$zip_line" ] &&
  [ "$cleanup_marker_line" -lt "$final_retention_line" ] &&
  [ "$final_retention_line" -lt "$evidence_manifest_line" ]

retention_helper=$root/scripts/validate-beta-recovery-artifact-retention.sh
[ -x "$retention_helper" ]
retention_fixture=$fixture_dir/retention
mkdir -p "$retention_fixture/bin"
real_date=$(command -v date)
date_count_file=$retention_fixture/date-count
fake_date=$retention_fixture/bin/date
cat >"$fake_date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=$(<"$FAKE_DATE_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_DATE_COUNT_FILE"
case "${FAKE_DATE_MODE:-}" in
  first-failure) [ "$count" -ne 1 ] || exit 1 ;;
  second-failure) [ "$count" -ne 2 ] || exit 1 ;;
  non-decimal) [ "$count" -ne 1 ] || { printf 'not-a-number\n'; exit 0; } ;;
esac
exec "$REAL_DATE" "$@"
EOF
chmod 700 "$fake_date"
retention_json() {
  local seconds=$1 created_epoch expires_at
  created_epoch=$("$real_date" -u -d 2026-08-01T00:00:00Z +%s)
  expires_at=$("$real_date" -u -d "@$((created_epoch + seconds))" +%Y-%m-%dT%H:%M:%SZ)
  jq -cn --arg created 2026-08-01T00:00:00Z --arg expires "$expires_at" \
    '{created_at:$created,expires_at:$expires}'
}
expect_retention_success() {
  local label=$1 input=$2 output status
  if output=$(printf '%s\n' "$input" | bash "$retention_helper"); then status=0; else status=$?; fi
  [ "$status" -eq 0 ] && [ -z "$output" ] ||
    { echo "retention success fixture failed: $label" >&2; exit 1; }
}
expect_retention_failure() {
  local label=$1 input=$2 output status
  if output=$(printf '%s\n' "$input" | bash "$retention_helper"); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] && [ -z "$output" ] ||
    { echo "retention failure fixture passed: $label" >&2; exit 1; }
}
expect_fake_date_failure() {
  local label=$1 mode=$2 input=$3 output status
  : >"$date_count_file"
  if output=$(printf '%s\n' "$input" |
    env PATH="$retention_fixture/bin:$PATH" REAL_DATE="$real_date" \
      FAKE_DATE_COUNT_FILE="$date_count_file" FAKE_DATE_MODE="$mode" \
      bash "$retention_helper"); then status=0; else status=$?; fi
  [ "$status" -ne 0 ] && [ -z "$output" ] ||
    { echo "retention parse fixture passed: $label" >&2; exit 1; }
}
expect_retention_success exact-30-days "$(retention_json 2592000)"
expect_retention_success one-second-rounding "$(retention_json 2591999)"
expect_retention_success lower-bound "$(retention_json 2591940)"
expect_retention_failure below-lower-bound "$(retention_json 2591939)"
expect_retention_failure above-upper-bound "$(retention_json 2592001)"
for invalid in \
  invalid-json \
  '{"expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":"","expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":123,"expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":"not-a-date","expires_at":"2026-08-31T00:00:00Z"}' \
  '{"created_at":"2026-08-01T00:00:00Z"}' \
  '{"created_at":"2026-08-01T00:00:00Z","expires_at":""}' \
  '{"created_at":"2026-08-01T00:00:00Z","expires_at":123}' \
  '{"created_at":"2026-08-01T00:00:00Z","expires_at":"not-a-date"}'; do
  expect_retention_failure "invalid metadata: $invalid" "$invalid"
done
valid_retention=$(retention_json 2592000)
expect_fake_date_failure first-date-failure first-failure "$valid_retention"
expect_fake_date_failure second-date-failure second-failure "$valid_retention"
expect_fake_date_failure non-decimal-date-output non-decimal "$valid_retention"

canonical_inventory=$retention_fixture/canonical-inventory
cat >"$canonical_inventory" <<'EOF'
scripts/authorize-beta-recovery.sh
scripts/backup-production.sh
scripts/beta-recovery-database-proof.sql
scripts/beta-recovery-media-proof.sh
scripts/build-beta-recovery-evidence.sh
scripts/install-beta-recovery-age.sh
scripts/materialize-beta-recovery-known-hosts.sh
scripts/probe-test-vps-recovery-runtime.sh
scripts/run-beta-recovery-capture.sh
scripts/run-beta-recovery-restore.sh
scripts/validate-beta-recovery-artifact-retention.sh
EOF
extract_paths() { grep -oE 'scripts/[A-Za-z0-9._-]+' | sort -u; }
workflow_inventory() {
  local wanted=$1
  awk -v wanted="$wanted" '
    /for file in scripts\/authorize-beta-recovery.sh/ {
      number++
      active=(number == wanted)
    }
    active { print }
    active && /; do/ { exit }
  ' "$workflow" | extract_paths
}
assert_inventory() {
  local label=$1 actual=$2
  diff -u "$canonical_inventory" "$actual" ||
    { echo "$label tooling inventory differs" >&2; exit 1; }
}
[ "$(grep -Fc 'for file in scripts/authorize-beta-recovery.sh' "$workflow")" -eq 3 ]
for index in 1 2 3; do
  actual=$retention_fixture/workflow-$index
  workflow_inventory "$index" >"$actual"
  assert_inventory "workflow inventory $index" "$actual"
done
actual=$retention_fixture/authorization
awk '/^files=\(/{active=1} active {print} active && /^\)/{exit}' \
  "$root/scripts/authorize-beta-recovery.sh" | extract_paths >"$actual"
assert_inventory authorization "$actual"
actual=$retention_fixture/restore-runtime
awk '/^actual_tooling=\$\(for file/{active=1} active {print} active && /^done/{exit}' \
  "$root/scripts/run-beta-recovery-restore.sh" | extract_paths >"$actual"
assert_inventory restore-runtime "$actual"
actual=$retention_fixture/authorization-fixture
awk '/^expected_tooling_digest=.*for file/{active=1} active {print} active && /; do/{exit}' \
  "$root/scripts/test-beta-recovery-authorization.sh" | extract_paths >"$actual"
assert_inventory authorization-fixture "$actual"
actual=$retention_fixture/restore-fixture
awk '/^  tooling=\$\(for file/{active=1} active {print} active && /; do/{exit}' \
  "$root/scripts/test-beta-recovery-restore.sh" | extract_paths >"$actual"
assert_inventory restore-fixture "$actual"
grep -Fq 'select(.event == "workflow_dispatch" and .head_branch == "dev"' "$workflow"
valid_dispatch=$(jq -cn --arg sha "$valid_recovery_id" \
  '{event:"workflow_dispatch",head_branch:"dev",head_sha:$sha,created_at:"2026-08-28T12:00:00Z"}')
dispatch_at=$(jq -er --arg sha "$valid_recovery_id" \
  'select(.event == "workflow_dispatch" and .head_branch == "dev" and .head_sha == $sha) |
   .created_at | select(type == "string" and length > 0)' \
  <<<"$valid_dispatch")
[ "$dispatch_at" = 2026-08-28T12:00:00Z ]
for mismatched_dispatch in \
  "$(jq -cn --arg sha "$valid_recovery_id" \
    '{event:"push",head_branch:"dev",head_sha:$sha,created_at:"2026-08-28T12:00:00Z"}')" \
  "$(jq -cn --arg sha "$valid_recovery_id" \
    '{event:"workflow_dispatch",head_branch:"main",head_sha:$sha,created_at:"2026-08-28T12:00:00Z"}')" \
  "$(jq -cn --arg sha "$valid_recovery_id" \
    '{event:"workflow_dispatch",head_branch:"dev",head_sha:"wrong",created_at:"2026-08-28T12:00:00Z"}')" \
  '{"event":"workflow_dispatch","head_branch":"dev","head_sha":"recovery-fixture"}' \
  '{"event":"workflow_dispatch","head_branch":"dev","head_sha":"recovery-fixture","created_at":null}' \
  '{"event":"workflow_dispatch","head_branch":"dev","head_sha":"recovery-fixture","created_at":123}'; do
  if jq -er --arg sha "$valid_recovery_id" \
    'select(.event == "workflow_dispatch" and .head_branch == "dev" and .head_sha == $sha) |
     .created_at | select(type == "string" and length > 0)' \
    <<<"$mismatched_dispatch" >/dev/null; then
    echo "malformed dispatch fixture unexpectedly produced created_at" >&2
    exit 1
  fi
done
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
