#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CAPTURE=$ROOT_DIR/scripts/capture-test-promotion-protected-state.sh
FIXTURE=$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/valid.json
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

fail() { echo "test-promotion protected-state fixture failed: $*" >&2; exit 1; }
run_capture() {
  bash "$CAPTURE" --input "$1" --output "$2" \
    --candidate-alias test-sha-9b6d2b06c0336ab8d153564dcf6328e81c4d7b36
}
expect_failure() {
  local name=$1
  shift
  if "$@" >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"; then
    fail "expected rejection was accepted: $name"
  fi
  [ ! -s "$TMP/$name.stdout" ] || fail "rejection emitted stdout: $name"
  [ -s "$TMP/$name.stderr" ] || fail "rejection omitted stderr: $name"
  ! grep -Fq 'fixture-secret-must-not-appear' "$TMP/$name.stderr" ||
    fail "rejection printed a secret: $name"
}
expect_byte_change() {
  local name=$1
  local filter=$2
  jq "$filter" "$FIXTURE" >"$TMP/$name.json"
  run_capture "$TMP/$name.json" "$TMP/$name-output.json"
  if cmp --silent "$TMP/canonical.json" "$TMP/$name-output.json"; then
    fail "protected drift did not change canonical bytes: $name"
  fi
}

[ -r "$CAPTURE" ] || fail "capture script is unavailable"
[ -f "$FIXTURE" ] || fail "fixture is missing"
bash -n "$CAPTURE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

run_capture "$FIXTURE" "$TMP/canonical.json"
run_capture "$FIXTURE" "$TMP/repeat.json"
cmp --silent "$TMP/canonical.json" "$TMP/repeat.json" ||
  fail "canonical output is not byte deterministic"
[ "$(wc -l <"$TMP/canonical.json" | tr -d ' ')" -eq 1 ] ||
  fail "canonical output is not compact JSON"
jq -e '
  .schema == "meet-backend/test-promotion-protected-state/v2" and
  .publicRelease.id == 371012814 and .publicRelease.tag == "v1.2.0" and
  .protected.releaseIds == [367640510,371012814] and
  (any(.protected.aliases[]; .alias == "test-sha-9b6d2b06c0336ab8d153564dcf6328e81c4d7b36")) and
  (any(.protected.aliases[]; .alias == "v1.2.0" and (.digests | length) == 2)) and
  (any(.protected.versions[]; .digest == "sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda")) and
  (all(.protected.versions[]; .digest != "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")) and
  (any(.protected.referrerClosure[]; .digest == "sha256:7777777777777777777777777777777777777777777777777777777777777777")) and
  (all(.protected.attestationEvidence[]; .rootDigest != "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")) and
  (any(.protected.authorities[]; .releaseId == 367640510 and .evidenceStorage.kind == "oci-registry-bundle")) and
  (any(.protected.authorities[]; .releaseId == 371012814 and .evidenceStorage.kind == "github-api-workflow-artifact" and .releaseSourceDigest == "9b6d2b06c0336ab8d153564dcf6328e81c4d7b36" and .certificateSourceDigest == "9af0723444f918594101999a4338b418607cbd01")) and
  (any(.protected.attestationEvidence[]; .rootDigest == "sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda" and .evidenceStorage.bundleDigest == "sha256:cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958")) and
  .proof.sha256 == "db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529"
' "$TMP/canonical.json" >/dev/null || fail "protected closure projection is wrong"

jq '
  .releases |= reverse | .releases[].assets |= reverse |
  .tagRefs |= reverse | .registry.versions |= reverse |
  .registry.versions[].tags |= reverse | .registry.subjects |= reverse |
  .registry.subjects[].aliases |= reverse | .registry.manifests |= reverse |
  .registry.manifests[].children |= reverse | .registry.evidence |= reverse
' "$FIXTURE" >"$TMP/reordered.json"
run_capture "$TMP/reordered.json" "$TMP/reordered-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/reordered-output.json" ||
  fail "source ordering changed canonical bytes"

jq '
  .registry.versions |= map(if .id == 2005 then
    .digest = "sha256:abababababababababababababababababababababababababababababababab" |
    .tags = ["test-sha-candidate-changed"] else . end) |
  .registry.manifests |= map(if .digest == "sha256:8888888888888888888888888888888888888888888888888888888888888888"
    then .size = 999 else . end)
' "$FIXTURE" >"$TMP/candidate-only.json"
run_capture "$TMP/candidate-only.json" "$TMP/candidate-only-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/candidate-only-output.json" ||
  fail "candidate-only state changed projection"

jq '.registry.versions |= map(if .id == 2005 then .tags = ["v1.2.0"] else . end)' \
  "$FIXTURE" >"$TMP/collision.json"
run_capture "$TMP/collision.json" "$TMP/collision-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/collision-output.json" &&
  fail "protected collision was discarded"
jq -e 'any(.protected.subjectDigests[]; . == "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")' \
  "$TMP/collision-output.json" >/dev/null || fail "collision digest was not represented"

jq '.registry.versions[0].digest = "not-a-digest"' "$FIXTURE" >"$TMP/malformed.json"
expect_failure malformed run_capture "$TMP/malformed.json" "$TMP/rejected.json"
jq '.releases += [.releases[1]]' "$FIXTURE" >"$TMP/ambiguous.json"
expect_failure ambiguous run_capture "$TMP/ambiguous.json" "$TMP/rejected.json"
jq '.registry.evidence[0].signerWorkflow = "https://evil.invalid/workflow"' \
  "$FIXTURE" >"$TMP/malformed-attestation.json"
expect_failure malformed-attestation \
  run_capture "$TMP/malformed-attestation.json" "$TMP/rejected.json"
jq '.schema = "meet-backend/test-promotion-protected-state-input/v1"' "$FIXTURE" >"$TMP/v1-input.json"
expect_failure v1-input run_capture "$TMP/v1-input.json" "$TMP/rejected.json"
jq '.proof.sha256 = "fixture-secret-must-not-appear"' "$FIXTURE" >"$TMP/secret.json"
expect_failure secret-proof run_capture "$TMP/secret.json" "$TMP/rejected.json"
printf '{not-json\n' >"$TMP/not-json"
expect_failure malformed-json run_capture "$TMP/not-json" "$TMP/rejected.json"

jq '.releases[1].draft = true' "$FIXTURE" >"$TMP/release-draft.json"
expect_failure release-draft \
  run_capture "$TMP/release-draft.json" "$TMP/rejected.json"
expect_byte_change release-asset '.releases[1].assets[0].sha256 = "abababababababababababababababababababababababababababababababab"'
expect_byte_change protected-alias \
  '.registry.versions[0].tags += ["protected-drift"]'
expect_byte_change protected-manifest \
  '.registry.manifests[4].size = 301'
expect_byte_change protected-attestation \
  '.registry.evidence[0].releaseSourceDigest = "4444444444444444444444444444444444444444"'

jq '.tagRefs[1].peeledCommitSha = "3333333333333333333333333333333333333333"' \
  "$FIXTURE" >"$TMP/tag-ref-drift.json"
expect_failure tag-ref-drift \
  run_capture "$TMP/tag-ref-drift.json" "$TMP/rejected.json"
jq '.registry.subjects[0].platformDigest = "sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda"' \
  "$FIXTURE" >"$TMP/platform-drift.json"
expect_failure platform-drift \
  run_capture "$TMP/platform-drift.json" "$TMP/rejected.json"

cp "$TMP/canonical.json" "$TMP/stable-output.json"
jq '.proof.sha256 = "fixture-secret-must-not-appear"' "$FIXTURE" >"$TMP/rejected-input.json"
if run_capture "$TMP/rejected-input.json" "$TMP/canonical.json" \
    >"$TMP/rejected-retry.stdout" 2>"$TMP/rejected-retry.stderr"; then
  fail "rejected input overwrote an existing output"
fi
cmp --silent "$TMP/stable-output.json" "$TMP/canonical.json" ||
  fail "rejected input changed an existing output"
if find "$TMP" -maxdepth 1 -name 'canonical.json.tmp.*' -print -quit | grep -q .; then
  fail "rejected input left a temporary output"
fi

# The projector has an explicit input shim and no live-state or writer command.
! grep -Eq '(^|[[:space:]])(gh|docker|curl|git|wget|ssh)([[:space:]]|$)' "$CAPTURE" ||
  fail "capture contains a network or registry command"
! grep -Eq '(docker (push|tag|rm)|gh (api|release|attestation)|curl .*https?)' "$CAPTURE" ||
  fail "capture contains a writer/network operation"
mkdir "$TMP/forbidden-bin"
for forbidden in gh docker curl git wget ssh; do
  cp "$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/forbidden-command.sh" \
    "$TMP/forbidden-bin/$forbidden"
done
PATH="$TMP/forbidden-bin:$PATH" \
  run_capture "$FIXTURE" "$TMP/shim-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/shim-output.json" ||
  fail "explicit command shims changed the projection"

echo "test-promotion protected-state fixtures passed: canonical order, drift matrix, candidate exclusion, collision inclusion, malformed input, and no writers/network"
