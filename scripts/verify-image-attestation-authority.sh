#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --authority PATH --subject-file PATH [--bundle PATH] [--closure PATH] [--immutable-proof PATH] --output PATH" >&2
  exit 2
}

fail() {
  echo "image attestation authority verification failed: $*" >&2
  exit 1
}

AUTHORITY=
SUBJECT_FILE=
BUNDLE=
CLOSURE=
IMMUTABLE_PROOF=
OUTPUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --authority) [ "$#" -ge 2 ] || usage; [ -z "$AUTHORITY" ] || usage; AUTHORITY=$2; shift 2 ;;
    --subject-file) [ "$#" -ge 2 ] || usage; [ -z "$SUBJECT_FILE" ] || usage; SUBJECT_FILE=$2; shift 2 ;;
    --bundle) [ "$#" -ge 2 ] || usage; [ -z "$BUNDLE" ] || usage; BUNDLE=$2; shift 2 ;;
    --closure) [ "$#" -ge 2 ] || usage; [ -z "$CLOSURE" ] || usage; CLOSURE=$2; shift 2 ;;
    --immutable-proof) [ "$#" -ge 2 ] || usage; [ -z "$IMMUTABLE_PROOF" ] || usage; IMMUTABLE_PROOF=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; [ -z "$OUTPUT" ] || usage; OUTPUT=$2; shift 2 ;;
    --help|-h) usage ;;
    *) usage ;;
  esac
done

[ -n "$AUTHORITY" ] && [ -n "$SUBJECT_FILE" ] && [ -n "$OUTPUT" ] || usage
[ -f "$AUTHORITY" ] && [ ! -L "$AUTHORITY" ] || fail "authority is unavailable"
[ -f "$SUBJECT_FILE" ] && [ ! -L "$SUBJECT_FILE" ] || fail "subject is unavailable"
[ -z "$BUNDLE" ] || { [ -f "$BUNDLE" ] && [ ! -L "$BUNDLE" ]; } ||
  fail "bundle is unavailable"
[ -z "$CLOSURE" ] || { [ -f "$CLOSURE" ] && [ ! -L "$CLOSURE" ]; } ||
  fail "closure evidence is unavailable"
[ -z "$IMMUTABLE_PROOF" ] ||
  { [ -f "$IMMUTABLE_PROOF" ] && [ ! -L "$IMMUTABLE_PROOF" ]; } ||
  fail "immutable proof is unavailable"
[ ! -L "$OUTPUT" ] || fail "output is unsafe"
output_dir=$(dirname -- "$OUTPUT")
[ -d "$output_dir" ] || fail "output directory is unavailable"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

TMP=$(mktemp -d)
TEMPORARY_OUTPUT=
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$TEMPORARY_OUTPUT" ] || rm -f -- "$TEMPORARY_OUTPUT"
  rm -r -- "$TMP"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

authority=$TMP/authority.json
jq -cS '
  def exact_keys($expected): (keys | sort) == ($expected | sort);
  def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  def expected_assets:
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
    ];
  def common:
    exact_keys([
      "schema","scope","repository","image","releaseId","tag","version",
      "sourceRepository","releaseSourceDigest","certificateSourceDigest",
      "signerDigest","sourceRef","signerWorkflow","certificateIdentity",
      "oidcIssuer","predicateType","rootDigest","platformDigest","subject",
      "evidenceStorage"
    ]) and
    .schema == "meet-backend/image-attestation-authority/v1" and
    .repository == "NickolayMamonov/meet-backend-v3" and
    .image == "ghcr.io/nickolaymamonov/meet-backend-v3" and
    .sourceRepository == "https://github.com/NickolayMamonov/meet-backend-v3" and
    .sourceRef == "refs/heads/dev" and
    .oidcIssuer == "https://token.actions.githubusercontent.com" and
    .predicateType == "https://slsa.dev/provenance/v1" and
    (.releaseSourceDigest | sha) and
    (.certificateSourceDigest | sha) and
    (.signerDigest | sha) and
    (.rootDigest | digest) and
    (.platformDigest | digest) and
    (.subject | type == "object" and exact_keys(["name","digest"])) and
    .subject.digest == .rootDigest and
    .certificateIdentity ==
      ("https://github.com/NickolayMamonov/meet-backend-v3/" +
       .signerWorkflow + "@refs/heads/dev");
  def v101:
    .scope == "protected-release" and
    .releaseId == 367640510 and .tag == "v1.0.1" and .version == "1.0.1" and
    .releaseSourceDigest == "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc" and
    .rootDigest == "sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6" and
    .certificateSourceDigest == "4bff2902511e8e739d7604bf120b121429e60aeb" and
    .signerDigest == "4bff2902511e8e739d7604bf120b121429e60aeb" and
    .signerWorkflow == ".github/workflows/release-please.yml" and
    .subject.name == "ghcr.io/nickolaymamonov/meet-backend-v3" and
    .evidenceStorage == {kind:"oci-registry-bundle"};
  def v120:
    .scope == "protected-release" and
    .releaseId == 371012814 and .tag == "v1.2.0" and .version == "1.2.0" and
    .releaseSourceDigest == "9b6d2b06c0336ab8d153564dcf6328e81c4d7b36" and
    .rootDigest == "sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda" and
    .certificateSourceDigest == "9af0723444f918594101999a4338b418607cbd01" and
    .signerDigest == "9af0723444f918594101999a4338b418607cbd01" and
    .signerWorkflow == ".github/workflows/release-please.yml" and
    .subject.name == "image-index.json" and
    .evidenceStorage == {
      kind:"github-api-workflow-artifact",
      bundleDigest:"sha256:cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958",
      asset:expected_assets[1],assets:expected_assets
    };
  def candidate:
    .scope == "test-candidate" and
    .releaseId == null and .tag == null and .version == null and
    .releaseSourceDigest == .certificateSourceDigest and
    .certificateSourceDigest == .signerDigest and
    .signerWorkflow == ".github/workflows/promote-dev-digest-to-test-vps.yml" and
    .subject.name == "ghcr.io/nickolaymamonov/meet-backend-v3" and
    .evidenceStorage == {kind:"oci-registry-bundle"};
  if type == "object" and common and (v101 or v120 or candidate)
  then . else error("invalid authority") end
' "$AUTHORITY" >"$authority" 2>/dev/null ||
  fail "authority is malformed or outside the closed policy"

kind=$(jq -r '.evidenceStorage.kind' "$authority")
root=$(jq -r '.rootDigest' "$authority")
subject_name=$(jq -r '.subject.name' "$authority")
subject_digest=$(jq -r '.subject.digest' "$authority")
source_repository=$(jq -r '.sourceRepository' "$authority")
certificate_source=$(jq -r '.certificateSourceDigest' "$authority")
signer_digest=$(jq -r '.signerDigest' "$authority")
source_ref=$(jq -r '.sourceRef' "$authority")
signer_workflow=$(jq -r '.signerWorkflow' "$authority")
signer_selector="github.com/${source_repository#https://github.com/}/$signer_workflow"
certificate_identity=$(jq -r '.certificateIdentity' "$authority")
oidc_issuer=$(jq -r '.oidcIssuer' "$authority")
predicate_type=$(jq -r '.predicateType' "$authority")
image=$(jq -r '.image' "$authority")

actual_subject="sha256:$(sha256sum "$SUBJECT_FILE" | awk '{print $1}')"
[ "$actual_subject" = "$subject_digest" ] || fail "subject bytes do not match authority"
if [ "$kind" = github-api-workflow-artifact ]; then
  [ "$(basename -- "$SUBJECT_FILE")" = "$subject_name" ] ||
    fail "subject name does not match authority"
fi

case "$kind" in
  oci-registry-bundle)
    [ -n "$BUNDLE" ] || fail "OCI authority requires a closure-derived bundle"
    [ -n "$CLOSURE" ] || fail "OCI authority requires closure evidence"
    [ -z "$IMMUTABLE_PROOF" ] || fail "OCI authority forbids an immutable proof"
    ;;
  github-api-workflow-artifact)
    [ -z "$BUNDLE" ] || fail "API authority cannot use a registry bundle"
    [ -z "$CLOSURE" ] || fail "API authority cannot use registry closure evidence"
    [ -n "$IMMUTABLE_PROOF" ] || fail "API authority requires an immutable proof"
    ;;
  *) fail "unsupported evidence storage" ;;
esac

if [ "$kind" = github-api-workflow-artifact ]; then
  proof=$TMP/immutable-proof.json
  jq -cS . "$IMMUTABLE_PROOF" >"$proof" 2>/dev/null || fail "immutable proof is malformed"
  jq -e --slurpfile authority "$authority" '
    ($authority[0]) as $a |
    type == "object" and
    .repository == "NickolayMamonov/meet-backend-v3" and
    .tag == "v1.2.0" and .releaseId == 371012814 and
    .sourceSha == "9b6d2b06c0336ab8d153564dcf6328e81c4d7b36" and
    .immutable == true and .draft == false and .attestation.verified == true and
    (.assets | type == "array" and length == 4) and
    (.assets | map({id,name,size,apiDigest,downloadSha256}) | sort_by(.id)) ==
      ($a.evidenceStorage.assets | sort_by(.id))
  ' "$proof" >/dev/null 2>&1 ||
    fail "immutable proof does not match the closed release authority"
fi

command -v gh >/dev/null 2>&1 || fail "gh is required"
verified=$TMP/verified.json
set -- attestation verify
if [ "$kind" = oci-registry-bundle ]; then
  set -- "$@" "oci://$image@$root"
else
  set -- "$@" "$SUBJECT_FILE"
fi
set -- "$@" \
  --repo "${source_repository#https://github.com/}" \
  --source-digest "$certificate_source" \
  --source-ref "$source_ref" \
  --signer-workflow "$signer_selector" \
  --signer-digest "$signer_digest" \
  --cert-oidc-issuer "$oidc_issuer" \
  --predicate-type "$predicate_type" \
  --format json
if [ "$kind" = oci-registry-bundle ]; then
  set -- "$@" --bundle "$BUNDLE"
fi
gh "$@" >"$verified" 2>/dev/null || fail "GitHub attestation verification failed"

jq -e \
  --arg expectedName "$subject_name" \
  --arg expectedDigest "${subject_digest#sha256:}" \
  --arg sourceRepository "$source_repository" \
  --arg certificateSource "$certificate_source" \
  --arg signerDigest "$signer_digest" \
  --arg sourceRef "$source_ref" \
  --arg signerWorkflow "$signer_workflow" \
  --arg certificateIdentity "$certificate_identity" \
  --arg issuer "$oidc_issuer" \
  --arg predicate "$predicate_type" '
  type == "array" and length == 1 and
  (.[0].verificationResult | type == "object") and
  .[0].verificationResult.statement.predicateType == $predicate and
  .[0].verificationResult.statement.subject ==
    [{name:$expectedName,digest:{sha256:$expectedDigest}}] and
  (.[0].verificationResult.signature.certificate as $c |
    ($c | type == "object") and
    $c.sourceRepositoryURI == $sourceRepository and
    $c.sourceRepositoryDigest == $certificateSource and
    $c.sourceRepositoryRef == $sourceRef and
    $c.buildSignerURI ==
      ($sourceRepository + "/" + $signerWorkflow + "@" + $sourceRef) and
    $c.buildSignerDigest == $signerDigest and
    $c.subjectAlternativeName == $certificateIdentity and
    $c.issuer == $issuer and
    $c.workflowIdentity == $certificateIdentity)
' "$verified" >/dev/null 2>&1 ||
  fail "verified certificate, predicate, or subject does not match authority"

bundle_digest=
if [ "$kind" = oci-registry-bundle ]; then
  bundle_digest="sha256:$(sha256sum "$BUNDLE" | awk '{print $1}')"
  jq -e \
    --arg bundleDigest "$bundle_digest" \
    --arg layerDigest "$(jq -r '.bundle.bundleLayerDigest // empty' "$CLOSURE")" \
    --arg layerMediaType "$(jq -r '.bundle.bundleLayerMediaType // empty' "$CLOSURE")" \
    --argjson layerSize "$(jq -r '.bundle.bundleLayerSize // 0' "$CLOSURE")" '
    (.bundle | type == "object") and
    (.bundle.signatureManifestDigest |
      type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .bundle.bundleLayerDigest == $layerDigest and
    .bundle.bundleLayerMediaType ==
      "application/vnd.dev.sigstore.bundle.v0.3+json" and
    .bundle.bundleLayerSize == $layerSize and .bundle.bundleLayerSize > 0 and
    .bundle.bundleDigest == $bundleDigest and
    ($layerDigest | test("^sha256:[0-9a-f]{64}$")) and
    $layerMediaType == "application/vnd.dev.sigstore.bundle.v0.3+json"
  ' "$CLOSURE" >/dev/null || fail "closure evidence does not match the derived bundle"
else
  bundle_digest="sha256:$(jq -cS '.[0].attestation.bundle' "$verified" |
    sha256sum | awk '{print $1}')"
fi
expected_bundle_digest=$(jq -r '.evidenceStorage.bundleDigest // empty' "$authority")
[ -z "$expected_bundle_digest" ] || [ "$expected_bundle_digest" = "$bundle_digest" ] ||
  fail "canonical evidence bundle digest does not match authority"

asset_name=$(jq -r '.evidenceStorage.asset.name // .subject.name' "$authority")
asset_id=$(jq -r '.evidenceStorage.asset.id // 0' "$authority")
asset_size=$(jq -r '.evidenceStorage.asset.size // 0' "$authority")
asset_api_digest=$(jq -r '.evidenceStorage.asset.apiDigest // empty' "$authority")
download_sha=$(jq -r '.evidenceStorage.asset.downloadSha256 // empty' "$authority")

TEMPORARY_OUTPUT=$(mktemp "$output_dir/.image-attestation-evidence.XXXXXX") ||
  fail "temporary output creation failed"
jq -cnS \
  --arg schema "meet-backend/image-attestation-evidence/v2" \
  --slurpfile authority "$authority" \
  --arg kind "$kind" \
  --arg bundleDigest "$bundle_digest" \
  --arg subjectFile "$subject_name" \
  --argjson assetId "$asset_id" \
  --argjson assetSize "$asset_size" \
  --arg assetApiDigest "$asset_api_digest" \
  --arg downloadSha "$download_sha" \
  --arg closureSignatureManifest "$(if [ "$kind" = oci-registry-bundle ]; then jq -r '.bundle.signatureManifestDigest' "$CLOSURE"; else printf ''; fi)" \
  --arg closureLayerDigest "$(if [ "$kind" = oci-registry-bundle ]; then jq -r '.bundle.bundleLayerDigest' "$CLOSURE"; else printf ''; fi)" \
  --argjson closureLayerSize "$(if [ "$kind" = oci-registry-bundle ]; then jq -r '.bundle.bundleLayerSize' "$CLOSURE"; else printf '0'; fi)" \
  --arg closureLayerMediaType "$(if [ "$kind" = oci-registry-bundle ]; then jq -r '.bundle.bundleLayerMediaType' "$CLOSURE"; else printf ''; fi)" \
  --argjson closureMetadata "$(if [ "$kind" = oci-registry-bundle ]; then jq -c '.bundle' "$CLOSURE"; else printf '{}'; fi)" '
  ($authority[0]) as $a |
  {
    schema:$schema,
    sourceRepository:$a.sourceRepository,
    releaseSourceDigest:$a.releaseSourceDigest,
    certificateSourceDigest:$a.certificateSourceDigest,
    signerDigest:$a.signerDigest,
    sourceRef:$a.sourceRef,
    signerWorkflow:$a.signerWorkflow,
    certificateIdentity:$a.certificateIdentity,
    oidcIssuer:$a.oidcIssuer,
    predicateType:$a.predicateType,
    rootDigest:$a.rootDigest,
    platformDigest:$a.platformDigest,
    subject:$a.subject,
    evidenceStorage:(
      if $kind == "oci-registry-bundle" then
        {kind:$kind,bundleDigest:$bundleDigest,
         signatureManifestDigest:$closureSignatureManifest,
         bundleLayerDigest:$closureLayerDigest,
         bundleLayerSize:$closureLayerSize,
         bundleLayerMediaType:$closureLayerMediaType,
         closure:$closureMetadata}
      else
        {kind:$kind,bundleDigest:$bundleDigest,
         asset:{id:$assetId,name:$subjectFile,size:$assetSize,
                apiDigest:$assetApiDigest,downloadSha256:$downloadSha},
         assets:$a.evidenceStorage.assets}
      end)
  }
' >"$TEMPORARY_OUTPUT" 2>/dev/null || fail "evidence construction failed"
chmod 600 "$TEMPORARY_OUTPUT" 2>/dev/null || true
mv -f -- "$TEMPORARY_OUTPUT" "$OUTPUT" || fail "evidence publication failed"
TEMPORARY_OUTPUT=
