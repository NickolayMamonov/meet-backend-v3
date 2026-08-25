#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER=$ROOT_DIR/scripts/resolve-image-attestation-authority.sh
FIXTURE=$ROOT_DIR/scripts/fixtures/image-attestation-authority/scenarios.json
TMP=$(mktemp -d)
MAIN_BASHPID=$BASHPID
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$BASHPID" = "$MAIN_BASHPID" ] && [ -d "$TMP" ]; then
    rm -r -- "$TMP"
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "image attestation authority fixture failed: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
bash -n "$RESOLVER" || fail "resolver has invalid Bash syntax"
bash -n "$0" || fail "test has invalid Bash syntax"
grep -Eq '^#!/usr/bin/env bash$' "$RESOLVER" || fail "resolver is not executable Bash"
test -x "$RESOLVER" || fail "resolver is not executable"
! grep -Eq '(^|[[:space:]])(gh|curl|wget|git|docker)([[:space:]]|$)' "$RESOLVER" ||
  fail "resolver contains a network or registry client"

expect_failure() {
  local stdout=$TMP/reject.stdout
  local stderr=$TMP/reject.stderr
  set +e
  "$@" >"$stdout" 2>"$stderr"
  local status=$?
  set -e
  [ "$status" -ne 0 ] || fail "mutation was accepted"
  [ ! -s "$stdout" ] || fail "rejection emitted partial JSON"
  [ -s "$stderr" ] || fail "rejection omitted a stable diagnostic"
  ! grep -Eiq 'token|authorization|secret|password|fixture' "$stderr" ||
    fail "rejection leaked sensitive-looking text"
}

run_case() {
  local name=$1
  local mode release_id tag version source root platform
  mode=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .mode' "$FIXTURE")
  release_id=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .releaseId // empty' "$FIXTURE")
  tag=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .tag // empty' "$FIXTURE")
  version=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .version // empty' "$FIXTURE")
  source=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .source' "$FIXTURE")
  root=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .root' "$FIXTURE")
  platform=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .platform' "$FIXTURE")
  local -a args=("$RESOLVER" "$mode")
  if [ "$mode" = protected-release ]; then
    args+=(--release-id "$release_id" --tag "$tag" --version "$version")
  fi
  args+=(--source "$source" --root "$root" --platform "$platform")
  "${args[@]}" >"$TMP/$name.json" || fail "$name was rejected"
  jq -e --arg mode "$mode" '
    type == "object" and
    .schema == "meet-backend/image-attestation-authority/v1" and
    .scope == $mode and
    (.sourceRepository == "https://github.com/NickolayMamonov/meet-backend-v3") and
    (.releaseSourceDigest | test("^[0-9a-f]{40}$")) and
    (.certificateSourceDigest | test("^[0-9a-f]{40}$")) and
    (.signerDigest | test("^[0-9a-f]{40}$")) and
    (.rootDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.platformDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.subject.digest == .rootDigest) and
    (.oidcIssuer == "https://token.actions.githubusercontent.com") and
    (.predicateType == "https://slsa.dev/provenance/v1") and
    (.evidenceStorage.kind | . == "oci-registry-bundle" or . == "github-api-workflow-artifact")
  ' "$TMP/$name.json" >/dev/null || fail "$name output is malformed"
  jq -cS . "$TMP/$name.json" >"$TMP/$name.canonical.json" ||
    fail "$name output could not be canonicalized"
  cmp -s "$TMP/$name.json" "$TMP/$name.canonical.json" ||
    fail "$name output is not compact sorted JSON"
}

for name in protected-v1.0.1 protected-v1.2.0 test-candidate; do
  run_case "$name"
done

jq -e '
  . as $all |
  ($all[] | select(.name == "protected-v1.0.1")) as $v101 |
  ($all[] | select(.name == "protected-v1.2.0")) as $v120 |
  ($all[] | select(.name == "test-candidate")) as $candidate |
  ($v101 | .releaseId == 367640510 and .tag == "v1.0.1" and
    .version == "1.0.1" and
    .source == "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc" and
    .root == "sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6") and
  ($v120 | .releaseId == 371012814 and .tag == "v1.2.0" and
    .version == "1.2.0" and
    .source == "9b6d2b06c0336ab8d153564dcf6328e81c4d7b36" and
    .root == "sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda") and
  ($candidate | .source == "fedcba9876543210fedcba9876543210fedcba98")
' "$FIXTURE" >/dev/null || fail "fixed tuple fixture was mutated"

expect_failure "$RESOLVER" protected-release \
  --release-id 123456789 --tag v2.3.4 --version 2.3.4 \
  --source 0123456789abcdef0123456789abcdef01234567 \
  --root sha256:1111111111111111111111111111111111111111111111111111111111111111 \
  --platform sha256:2222222222222222222222222222222222222222222222222222222222222222

v101_source=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
v101_root=sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6
v120_source=9b6d2b06c0336ab8d153564dcf6328e81c4d7b36
v120_root=sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda
platform=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

expect_failure "$RESOLVER" protected-release \
  --release-id 367640510 --tag v1.0.1 --version 1.0.1 \
  --source "$v101_source" --root sha256:0000000000000000000000000000000000000000000000000000000000000000 \
  --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 367640511 --tag v1.0.1 --version 1.0.1 \
  --source "$v101_source" --root "$v101_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 367640510 --tag v1.0.2 --version 1.0.2 \
  --source "$v101_source" --root "$v101_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 367640510 --tag v1.0.1 --version 1.0.2 \
  --source "$v101_source" --root "$v101_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 367640510 --tag v1.0.1 --version 1.0.1 \
  --source 0123456789abcdef0123456789abcdef01234567 \
  --root "$v101_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 367640510 --tag v1.0.1 --version 1.0.1 \
  --source "$v101_source" --root "$v101_root" --platform bad
expect_failure "$RESOLVER" protected-release \
  --release-id 367640510 --tag v1.0.1 --version v1.0.1 \
  --source "$v101_source" --root "$v101_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
  --source "$v120_source" --root "$v101_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 371012815 --tag v1.2.0 --version 1.2.0 \
  --source "$v120_source" --root "$v120_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 371012814 --tag v1.2.1 --version 1.2.1 \
  --source "$v120_source" --root "$v120_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 371012814 --tag v1.2.0 --version 1.2.1 \
  --source "$v120_source" --root "$v120_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
  --source 0123456789abcdef0123456789abcdef01234567 \
  --root "$v120_root" --platform "$platform"
expect_failure "$RESOLVER" protected-release \
  --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
  --source "$v120_source" --root "$v120_root" --platform "$platform" \
  --release-source "$v120_source"
expect_failure "$RESOLVER" test-candidate \
  --source "$v120_source" --root "$v120_root" --platform "$platform" \
  --tag v1.2.0
expect_failure "$RESOLVER" test-candidate \
  --source "$v120_source" --root "$v120_root" --platform "$platform" \
  --source bad
expect_failure "$RESOLVER" test-candidate \
  --source "$v120_source" --root "$v120_root" --platform "$platform" \
  --release-id 1
expect_failure "$RESOLVER" test-candidate \
  --source "$v120_source" --root "$v120_root" --platform "$platform" \
  --unknown value
v101=$("$RESOLVER" protected-release \
  --release-id 367640510 --tag v1.0.1 --version 1.0.1 \
  --source "$v101_source" --root "$v101_root" --platform "$platform")
[ "$(jq -r '.certificateSourceDigest' <<<"$v101")" = 4bff2902511e8e739d7604bf120b121429e60aeb ] ||
  fail "v1.0.1 signer authority is not pinned"

v120=$("$RESOLVER" protected-release \
  --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
  --source "$v120_source" --root "$v120_root" --platform "$platform")
jq -e '
  .certificateSourceDigest == "9af0723444f918594101999a4338b418607cbd01" and
  .signerDigest == "9af0723444f918594101999a4338b418607cbd01" and
  .certificateIdentity == "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" and
  .signerWorkflow == ".github/workflows/release-please.yml" and
  .sourceRef == "refs/heads/dev" and
  .evidenceStorage.kind == "github-api-workflow-artifact" and
  .evidenceStorage.bundleDigest == "sha256:cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958" and
  (.evidenceStorage.assets | length == 4) and
  ([.evidenceStorage.assets[].id] | sort) == [515612606,515612616,515612629,515612640] and
  ([.evidenceStorage.assets[].name] | sort) ==
    ["SHA256SUMS","image-index.json","image-inspect.txt","release-manifest.json"] and
  ([.evidenceStorage.assets[].size] | sort) == [249,695,849,857] and
  ([.evidenceStorage.assets[] |
    {name,apiDigest,downloadSha256}] | sort_by(.name)) == [
      {name:"SHA256SUMS",
       apiDigest:"sha256:6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271",
       downloadSha256:"6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271"},
      {name:"image-index.json",
       apiDigest:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda",
       downloadSha256:"e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda"},
      {name:"image-inspect.txt",
       apiDigest:"sha256:614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3",
       downloadSha256:"614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3"},
      {name:"release-manifest.json",
       apiDigest:"sha256:428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb",
       downloadSha256:"428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb"}
    ] and
  .evidenceStorage.asset.name == "image-index.json" and
  .evidenceStorage.asset.apiDigest == .rootDigest and
  .evidenceStorage.asset.downloadSha256 == (.rootDigest | sub("^sha256:";""))
' <<<"$v120" >/dev/null || fail "v1.2.0 exact asset authority is incomplete"

candidate=$("$RESOLVER" test-candidate \
  --source fedcba9876543210fedcba9876543210fedcba98 \
  --root sha256:5555555555555555555555555555555555555555555555555555555555555555 \
  --platform sha256:6666666666666666666666666666666666666666666666666666666666666666)
jq -e '
  .releaseId == null and .tag == null and .version == null and
  .releaseSourceDigest == "fedcba9876543210fedcba9876543210fedcba98" and
  .certificateSourceDigest == .releaseSourceDigest and
  .signerDigest == .releaseSourceDigest and
  .signerWorkflow == ".github/workflows/promote-dev-digest-to-test-vps.yml" and
  .evidenceStorage.kind == "oci-registry-bundle"
' <<<"$candidate" >/dev/null || fail "candidate authority is not exact or is tip-derived"

echo "image attestation authority fixtures passed: exact v1.0.1/v1.2.0 tuples, candidate closure, assets, sorted output, and mutation rejection"
