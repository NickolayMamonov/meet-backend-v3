#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-image-attestation-authority.sh
RESOLVE=$ROOT_DIR/scripts/resolve-image-attestation-authority.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

fail() {
  echo "image attestation verifier fixture failed: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
bash -n "$VERIFY" || fail "verifier has invalid Bash syntax"

REAL_SHA256SUM=$(command -v sha256sum)
FAKE_BIN=$TMP/bin
mkdir "$FAKE_BIN"
cat >"$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -gt 0 ] || exit 2
printf '%s\n' "$@" >"$FAKE_GH_ARGV"
[ "$1" = attestation ] && [ "$2" = verify ] || exit 3
cat "$FAKE_GH_RESPONSE"
EOF
cat >"$FAKE_BIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$#" -eq 0 ]; then
  cat >/dev/null
  printf '%s  -\n' cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958
  exit 0
fi
case "$(basename -- "$1")" in
  v101-index.json)
    digest=41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6 ;;
  image-index.json)
    digest=e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda ;;
  candidate-index.json)
    digest=5555555555555555555555555555555555555555555555555555555555555555 ;;
  *) exec "$REAL_SHA256SUM" "$@" ;;
esac
printf '%s  %s\n' "$digest" "$1"
EOF
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/sha256sum"
export REAL_SHA256SUM

REPO_SLUG=NickolayMamonov/meet-backend-v3
REF=refs/heads/dev
ISSUER=https://token.actions.githubusercontent.com
PREDICATE=https://slsa.dev/provenance/v1
IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3
V101_SOURCE=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
V101_ROOT=sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6
V101_SIGNER=4bff2902511e8e739d7604bf120b121429e60aeb
V120_SOURCE=9b6d2b06c0336ab8d153564dcf6328e81c4d7b36
V120_ROOT=sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda
V120_SIGNER=9af0723444f918594101999a4338b418607cbd01
CANDIDATE_SOURCE=fedcba9876543210fedcba9876543210fedcba98
PLATFORM=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CANDIDATE_ROOT=sha256:5555555555555555555555555555555555555555555555555555555555555555

printf 'fixture v1.0.1 index\n' >"$TMP/v101-index.json"
printf 'fixture v1.2.0 index\n' >"$TMP/image-index.json"
printf 'fixture candidate index\n' >"$TMP/candidate-index.json"
jq -cnS '{mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",fixture:"closure"}' \
  >"$TMP/bundle.json"
BUNDLE_DIGEST="sha256:$("$REAL_SHA256SUM" "$TMP/bundle.json" | awk '{print $1}')"
BUNDLE_SIZE=$(wc -c <"$TMP/bundle.json" | tr -d ' ')
SIGNATURE_MANIFEST=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd

assets_json() {
  jq -cnS '
    [
      {id:515612606,name:"release-manifest.json",size:695,
       apiDigest:"sha256:428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb",
       downloadSha256:"428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb"},
      {id:515612616,name:"image-index.json",size:857,
       apiDigest:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda",
       downloadSha256:"e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda"},
      {id:515612629,name:"image-inspect.txt",size:849,
       apiDigest:"sha256:614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3",
       downloadSha256:"614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3"},
      {id:515612640,name:"SHA256SUMS",size:249,
       apiDigest:"sha256:6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271",
       downloadSha256:"6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271"}
    ]'
}
make_authority() {
  local scope=$1 release_id=$2 tag=$3 version=$4 release_source=$5
  local root=$9 authority=${12}
  local -a args=("$RESOLVE" "$scope")
  if [ "$scope" = protected-release ]; then
    args+=(--release-id "$release_id" --tag "$tag" --version "$version")
  fi
  args+=(--source "$release_source" --root "$root" --platform "$PLATFORM")
  "${args[@]}" >"$authority" || fail "authority resolution failed for $scope"
}


make_verified() {
  local authority=$1 response=$2
  jq -cnS \
    --arg subject "$(jq -r '.subject.digest' "$authority" | sed 's/^sha256://')" \
    --arg name "$(jq -r '.subject.name' "$authority")" \
    --arg cert "$(jq -r '.certificateSourceDigest' "$authority")" \
    --arg signer "$(jq -r '.signerDigest' "$authority")" \
    --arg workflow "$(jq -r '.signerWorkflow' "$authority")" '
      [{verificationResult:{
          statement:{predicateType:"https://slsa.dev/provenance/v1",
            subject:[{name:$name,digest:{sha256:$subject}}]},
          signature:{certificate:{
            sourceRepositoryURI:"https://github.com/NickolayMamonov/meet-backend-v3",
            sourceRepositoryDigest:$cert,
            sourceRepositoryRef:"refs/heads/dev",
            buildSignerURI:("https://github.com/NickolayMamonov/meet-backend-v3/" +
              $workflow + "@refs/heads/dev"),
            buildSignerDigest:$signer,
            subjectAlternativeName:("https://github.com/NickolayMamonov/meet-backend-v3/" +
              $workflow + "@refs/heads/dev"),
            issuer:"https://token.actions.githubusercontent.com",
            workflowIdentity:("https://github.com/NickolayMamonov/meet-backend-v3/" +
              $workflow + "@refs/heads/dev")}}},
        attestation:{bundle:{fixture:"fake-gh-verified-bundle"}}}]' >"$response"
}

make_closure() {
  jq -cnS --arg manifest "$SIGNATURE_MANIFEST" --arg layer "$BUNDLE_DIGEST" \
    --argjson size "$BUNDLE_SIZE" '
      {bundle:{signatureManifestDigest:$manifest,bundleLayerDigest:$layer,
        bundleLayerSize:$size,
        bundleLayerMediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",
        bundleDigest:$layer}}' >"$1"
}

make_proof() {
  local assets
  assets=$(assets_json)
  jq -cnS --argjson assets "$assets" '
    {repository:"NickolayMamonov/meet-backend-v3",tag:"v1.2.0",
     releaseId:371012814,
     sourceSha:"9b6d2b06c0336ab8d153564dcf6328e81c4d7b36",
     immutable:true,draft:false,
     attestation:{verified:true,
       predicateType:"https://in-toto.io/attestation/release/v0.2",
       bundleSha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
       claimSha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
     assets:[$assets[] + {repository:"NickolayMamonov/meet-backend-v3",
       tag:"v1.2.0",releaseId:371012814,
       attestationBundleSha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
       verified:true}]}' >"$1"
}

V101_AUTH=$TMP/v101-authority.json
V120_AUTH=$TMP/v120-authority.json
CANDIDATE_AUTH=$TMP/candidate-authority.json
make_authority protected-release 367640510 v1.0.1 1.0.1 "$V101_SOURCE" \
  "$V101_SIGNER" "$V101_SIGNER" .github/workflows/release-please.yml \
  "$V101_ROOT" "$IMAGE" oci-registry-bundle "$V101_AUTH"
make_authority protected-release 371012814 v1.2.0 1.2.0 "$V120_SOURCE" \
  "$V120_SIGNER" "$V120_SIGNER" .github/workflows/release-please.yml \
  "$V120_ROOT" image-index.json github-api-workflow-artifact "$V120_AUTH"
make_authority test-candidate null '' '' "$CANDIDATE_SOURCE" "$CANDIDATE_SOURCE" \
  "$CANDIDATE_SOURCE" .github/workflows/promote-dev-digest-to-test-vps.yml \
  "$CANDIDATE_ROOT" "$IMAGE" oci-registry-bundle "$CANDIDATE_AUTH"

V101_RESPONSE=$TMP/v101-response.json
V120_RESPONSE=$TMP/v120-response.json
CANDIDATE_RESPONSE=$TMP/candidate-response.json
make_verified "$V101_AUTH" "$V101_RESPONSE"
make_verified "$V120_AUTH" "$V120_RESPONSE"
make_verified "$CANDIDATE_AUTH" "$CANDIDATE_RESPONSE"
V101_CLOSURE=$TMP/v101-closure.json
CANDIDATE_CLOSURE=$TMP/candidate-closure.json
make_closure "$V101_CLOSURE"
cp "$V101_CLOSURE" "$CANDIDATE_CLOSURE"
V120_PROOF=$TMP/v120-proof.json
make_proof "$V120_PROOF"

run_case() {
  local name=$1 authority=$2 subject=$3 response=$4 expected_source=$5
  local expected_signer=$6 expected_workflow=$7 kind=$8 closure=$9 proof=${10}
  export FAKE_GH_ARGV=$TMP/$name.argv
  export FAKE_GH_RESPONSE=$response
  local -a command=("$VERIFY" --authority "$authority" --subject-file "$subject")
  if [ "$kind" = oci ]; then
    command+=(--bundle "$TMP/bundle.json" --closure "$closure")
  else
    command+=(--immutable-proof "$proof")
  fi
  command+=(--output "$TMP/$name-evidence.json")
  PATH="$FAKE_BIN:$PATH" "${command[@]}"

  local expected=$TMP/$name.expected
  if [ "$kind" = oci ]; then
    printf '%s\n' attestation verify "oci://$IMAGE@$(jq -r '.rootDigest' "$authority")" \
      >"$expected"
  else
    printf '%s\n' attestation verify "$subject" >"$expected"
  fi
  printf '%s\n' --repo "$REPO_SLUG" --source-digest "$expected_source" \
    --source-ref "$REF" \
    --signer-workflow "github.com/$REPO_SLUG/$expected_workflow" \
    --signer-digest "$expected_signer" --cert-oidc-issuer "$ISSUER" \
    --predicate-type "$PREDICATE" --format json >>"$expected"
  [ "$kind" = oci ] && printf '%s\n' --bundle "$TMP/bundle.json" >>"$expected"
  cmp -s "$expected" "$FAKE_GH_ARGV" || {
    diff -u "$expected" "$FAKE_GH_ARGV" >&2 || true
    fail "complete fake-gh argv mismatch for $name"
  }
  jq -e --arg kind "$kind" '
    .schema == "meet-backend/image-attestation-evidence/v2" and
    .evidenceStorage.kind ==
      (if $kind == "oci" then "oci-registry-bundle"
       else "github-api-workflow-artifact" end)' \
    "$TMP/$name-evidence.json" >/dev/null || fail "$name evidence is malformed"
}

run_case v101 "$V101_AUTH" "$TMP/v101-index.json" "$V101_RESPONSE" \
  "$V101_SIGNER" "$V101_SIGNER" .github/workflows/release-please.yml oci \
  "$V101_CLOSURE" ''
run_case v120 "$V120_AUTH" "$TMP/image-index.json" "$V120_RESPONSE" \
  "$V120_SIGNER" "$V120_SIGNER" .github/workflows/release-please.yml api '' \
  "$V120_PROOF"
run_case candidate "$CANDIDATE_AUTH" "$TMP/candidate-index.json" \
  "$CANDIDATE_RESPONSE" "$CANDIDATE_SOURCE" "$CANDIDATE_SOURCE" \
  .github/workflows/promote-dev-digest-to-test-vps.yml oci "$CANDIDATE_CLOSURE" ''

assert_atomic_rejection() {
  local name=$1 authority=$2 proof=$3
  cp "$TMP/v120-evidence.json" "$TMP/$name-sentinel.json"
  cp "$TMP/$name-sentinel.json" "$TMP/$name-evidence.json"
  if PATH="$FAKE_BIN:$PATH" FAKE_GH_ARGV=$TMP/$name.argv \
    FAKE_GH_RESPONSE="$V120_RESPONSE" "$VERIFY" \
    --authority "$authority" --subject-file "$TMP/image-index.json" \
    --immutable-proof "$proof" --output "$TMP/$name-evidence.json" \
    >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"; then
    fail "$name mutation was accepted"
  fi
  cmp -s "$TMP/$name-sentinel.json" "$TMP/$name-evidence.json" ||
    fail "$name rejection replaced prior evidence"
  ! grep -Eiq 'fake-gh|fixture|token|secret|password' "$TMP/$name.stderr" ||
    fail "$name rejection leaked fixture or sensitive text"
}

jq '.evidenceStorage.assets[0].id = 515612607' \
  "$V120_AUTH" >"$TMP/mutated-authority.json"
assert_atomic_rejection mutated-authority "$TMP/mutated-authority.json" "$V120_PROOF"

jq '.assets[2].downloadSha256 =
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$V120_PROOF" >"$TMP/mutated-proof.json"
assert_atomic_rejection mutated-proof "$V120_AUTH" "$TMP/mutated-proof.json"

echo "image attestation verifier fixtures passed: closed v1.0.1, v1.2.0 proof, candidate authority, exact gh argv, and atomic mutation rejection"