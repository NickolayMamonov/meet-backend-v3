#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW_DIR=$ROOT_DIR/.github/workflows
PROMOTION_WORKFLOW=$WORKFLOW_DIR/promote-dev-digest-to-test-vps.yml
BUILDER=$ROOT_DIR/scripts/build-test-promotion-evidence.sh
AUTHORIZATION_FIXTURE=$ROOT_DIR/scripts/fixtures/promote-dev-digest-workflow/authorization-failure.json

fail() {
  echo "script execution contract: $*" >&2
  exit 1
}

mode_for() {
  git -C "$ROOT_DIR" ls-files --stage -- "$1" |
    awk 'NR == 1 { print $1; found = 1 } END { if (!found) exit 1 }'
}

require_executable() {
  local path=$1 mode
  [ -f "$ROOT_DIR/$path" ] || fail "missing executable contract path: $path"
  mode=$(mode_for "$path") || fail "untracked execution contract path: $path"
  [ "$mode" = 100755 ] || fail "$path is tracked as $mode; expected 100755"
}

require_workflow_reference() {
  local path=$1
  grep -R -Fq -- "$path" "$WORKFLOW_DIR" ||
    fail "workflow does not cover staged/direct script: $path"
  require_executable "$path"
}

command -v git >/dev/null 2>&1 || fail "git is required"
command -v grep >/dev/null 2>&1 || fail "grep is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# Derive every script token written in a workflow, including scripts invoked
# through the remote staging loop. This catches newly added direct calls.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if grep -R -Eq -- "bash[[:space:]]+$path([[:space:]]|$)" "$WORKFLOW_DIR" ||
    grep -R -Eq -- "--input-command[[:space:]]+$path([[:space:]]|$)" "$WORKFLOW_DIR"; then
    continue
  fi
  require_executable "$path"
done < <(
  grep -RhoE 'scripts/[A-Za-z0-9_./-]+\.sh' "$WORKFLOW_DIR" |
    sort -u
)

# An input-command callback is executed by admit-test-image.sh. Keep the
# callback contract explicit so a 100644 callback remains intentional and
# cannot accidentally become a direct exec.
grep -Fq 'bash "$INPUT_COMMAND"' "$ROOT_DIR/scripts/admit-test-image.sh" ||
  fail "input-command callbacks are not invoked through bash"
grep -Fq -- '--input-command scripts/read-test-image-state.sh' "$PROMOTION_WORKFLOW" ||
  fail "promotion workflow lost its reviewed input-command callback"

# These are copied to the VPS and invoked while the remote deployment lock is
# held. Keep the list explicit so a staged executable cannot silently become
# non-executable in a fresh checkout.
remote_executables=(
  scripts/production-compose.sh
  scripts/production-config-digest.sh
  scripts/test-vps-runtime-invariants.sh
  scripts/update-production-release.sh
  scripts/deploy-test-vps-release.sh
  scripts/verify-test-vps-closed-beta-state.sh
  scripts/probe-test-vps-zero-state.sh
  scripts/verify-test-vps-assets.sh
  scripts/validate-test-vps-phase-file.sh
  scripts/build-bootstrap-default-proof.sh
)
for path in "${remote_executables[@]}"; do
  require_workflow_reference "$path"
done

for path in scripts/authorize-beta-recovery.sh scripts/run-beta-recovery-capture.sh \
  scripts/run-beta-recovery-restore.sh scripts/probe-test-vps-recovery-runtime.sh \
  scripts/build-beta-recovery-evidence.sh scripts/beta-recovery-media-proof.sh \
  scripts/install-beta-recovery-age.sh scripts/materialize-beta-recovery-known-hosts.sh; do
  require_workflow_reference "$path"
done

# The always-run incident path is an authorization-failure fixture: it must
# produce a closed-schema, sanitized artifact before upload selection, while
# proving that no writer marker was created.
jq -e '
  .schema == "meet-backend/test-promotion-authorization-failure/v1" and
  .authorizationJob == "failed" and
  .mutationStarted == false and
  .incidentStage == "authorization" and
  .incidentFailureClass == "internalFailure" and
  .incidentUpload.condition == "always" and
  .incidentUpload.ifNoFilesFound == "error" and
  .incidentUpload.artifact == "promotion-incident.json"
' "$AUTHORIZATION_FIXTURE" >/dev/null || fail "authorization-failure fixture is invalid"
grep -Fq 'if: always()' "$PROMOTION_WORKFLOW" ||
  fail "incident job is not always-run"
grep -Fq 'build-test-promotion-evidence.sh incident' "$PROMOTION_WORKFLOW" ||
  fail "incident builder is not wired"
grep -Fq 'if-no-files-found: error' "$PROMOTION_WORKFLOW" ||
  fail "incident upload is not fail-closed"
grep -Fq 'promotion-incident.json' "$PROMOTION_WORKFLOW" ||
  fail "incident artifact path is not wired"

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM
mutation_marker=$tmp/mutation.marker
incident=$tmp/promotion-incident.json
uploaded=$tmp/uploaded/promotion-incident.json
mkdir -p "$tmp/uploaded"
bash "$BUILDER" incident \
  --stage authorization \
  --failure-class internalFailure \
  --mutation-started false \
  --rollback-attempted false \
  --rollback-verified false \
  --output "$incident" >/dev/null
[ ! -e "$mutation_marker" ] ||
  fail "authorization fixture unexpectedly mutated the writer marker"
jq -e '
  keys == [
    "artifactUploaded","evidenceSanitized","failureClass","kind",
    "mutationStarted","retentionAuthorized","rollbackAttempted",
    "rollbackVerified","schema","stage"
  ] and
  .schema == "meet-backend/test-promotion-incident/v1" and
  .kind == "incident" and
  .stage == "authorization" and
  .failureClass == "internalFailure" and
  .mutationStarted == false and
  .rollbackAttempted == false and
  .rollbackVerified == false and
  .evidenceSanitized == true and
  .artifactUploaded == false and
  .retentionAuthorized == false
' "$incident" >/dev/null || fail "authorization incident artifact is not closed and sanitized"
[ -s "$incident" ] || fail "authorization incident artifact was not generated"
cp -- "$incident" "$uploaded"
[ -s "$uploaded" ] || fail "authorization incident upload selection omitted the artifact"
cmp -- "$incident" "$uploaded" || fail "uploaded incident differs from selected artifact"
! grep -Eiq 'secret|token|password|authorization:[[:space:]]*bearer' \
  "$incident" || fail "incident artifact contains sensitive-looking content"

echo "script execution contract and authorization-failure fixture passed"
