#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  resolve-image-attestation-authority.sh protected-release
    --release-id ID --tag TAG --version VERSION --source SHA
    --root DIGEST --platform DIGEST
  resolve-image-attestation-authority.sh test-candidate
    --source SHA --root DIGEST --platform DIGEST
EOF
  exit 2
}

fail() {
  echo "image attestation authority resolution failed: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "jq is required"

mode=${1:-}
case "$mode" in
  protected-release|test-candidate) ;;
  *) usage ;;
esac
shift

release_id=
tag=
version=
source=
root=
platform=
seen_release_id=false
seen_tag=false
seen_version=false
seen_source=false
seen_root=false
seen_platform=false

take_arg() {
  [ "$#" -ge 2 ] || usage
  [ -n "$2" ] || usage
  case "$2" in
    --*) usage ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-id)
      take_arg "$@"
      [ "$seen_release_id" = false ] || usage
      release_id=$2
      seen_release_id=true
      shift 2
      ;;
    --tag)
      take_arg "$@"
      [ "$seen_tag" = false ] || usage
      tag=$2
      seen_tag=true
      shift 2
      ;;
    --version)
      take_arg "$@"
      [ "$seen_version" = false ] || usage
      version=$2
      seen_version=true
      shift 2
      ;;
    --source|--release-source)
      take_arg "$@"
      [ "$seen_source" = false ] || usage
      source=$2
      seen_source=true
      shift 2
      ;;
    --root|--root-digest)
      take_arg "$@"
      [ "$seen_root" = false ] || usage
      root=$2
      seen_root=true
      shift 2
      ;;
    --platform|--platform-digest)
      take_arg "$@"
      [ "$seen_platform" = false ] || usage
      platform=$2
      seen_platform=true
      shift 2
      ;;
    --help|-h) usage ;;
    *) usage ;;
  esac
done

if [ "$mode" = protected-release ]; then
  [ "$seen_release_id" = true ] &&
    [ "$seen_tag" = true ] &&
    [ "$seen_version" = true ] ||
    usage
else
  [ "$seen_release_id" = false ] &&
    [ "$seen_tag" = false ] &&
    [ "$seen_version" = false ] ||
    usage
fi
[ "$seen_source" = true ] &&
  [ "$seen_root" = true ] &&
  [ "$seen_platform" = true ] ||
  usage

[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || {
  [ "$mode" = test-candidate ] || fail "release ID is invalid"
}
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  [ "$mode" = test-candidate ] || fail "version is invalid"
}
if [ "$mode" = protected-release ]; then
  [ "$tag" = "v$version" ] || fail "tag and version do not match"
fi
[[ "$source" =~ ^[0-9a-f]{40}$ ]] || fail "source digest is invalid"
[[ "$root" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "root digest is invalid"
[[ "$platform" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "platform digest is invalid"

repository=NickolayMamonov/meet-backend-v3
source_repository=https://github.com/$repository
source_ref=refs/heads/dev
issuer=https://token.actions.githubusercontent.com
predicate=https://slsa.dev/provenance/v1
image=ghcr.io/nickolaymamonov/meet-backend-v3

v101_id=367640510
v101_tag=v1.0.1
v101_version=1.0.1
v101_source=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
v101_root=sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6
v101_signer=4bff2902511e8e739d7604bf120b121429e60aeb

v120_id=371012814
v120_tag=v1.2.0
v120_version=1.2.0
v120_source=9b6d2b06c0336ab8d153564dcf6328e81c4d7b36
v120_root=sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda
v120_signer=9af0723444f918594101999a4338b418607cbd01

workflow=
certificate_source=$source
signer=$source
storage_kind=oci-registry-bundle
subject_name=$image
bundle_digest=
asset_json='[]'

is_v101=false
is_v120=false
if [ "$mode" = protected-release ]; then
  if [ "$release_id" = "$v101_id" ] &&
    [ "$tag" = "$v101_tag" ] &&
    [ "$version" = "$v101_version" ] &&
    [ "$source" = "$v101_source" ] &&
    [ "$root" = "$v101_root" ]; then
    is_v101=true
  elif [ "$release_id" = "$v120_id" ] &&
    [ "$tag" = "$v120_tag" ] &&
    [ "$version" = "$v120_version" ] &&
    [ "$source" = "$v120_source" ] &&
    [ "$root" = "$v120_root" ]; then
    is_v120=true
  else
    fail "protected-release tuple is not an approved exact tuple"
  fi

  workflow=.github/workflows/release-please.yml
  if [ "$is_v101" = true ]; then
    certificate_source=$v101_signer
    signer=$v101_signer
  elif [ "$is_v120" = true ]; then
    certificate_source=$v120_signer
    signer=$v120_signer
    storage_kind=github-api-workflow-artifact
    subject_name="image-index.json"
    bundle_digest=sha256:cf1f5d905c0bb97ca2013b3dd8aa415fb331a63dfec860e0382e5690339e5958
    asset_json=$(
      jq -cnS \
        --arg root "$v120_root" '
        [
          {id:515612606,name:"release-manifest.json",size:695,
            apiDigest:"sha256:428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb",
            downloadSha256:"428e33c13d31040682f6b5d660e902860dd9a69ba26339be76762a4efbcf42eb"},
          {id:515612616,name:"image-index.json",size:857,apiDigest:$root,
            downloadSha256:($root|sub("^sha256:";""))},
          {id:515612629,name:"image-inspect.txt",size:849,
            apiDigest:"sha256:614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3",
            downloadSha256:"614e14fd979195c798e67eec8a7e1e6edbf1da73caaaaa182225753440b11ea3"},
          {id:515612640,name:"SHA256SUMS",size:249,
            apiDigest:"sha256:6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271",
            downloadSha256:"6c6295333cb0406b44946438e4d949b410dda3d82ead63239e33739a8f4c9271"}
        ]
      '
    ) || fail "asset policy construction failed"
  fi
else
  workflow=.github/workflows/promote-dev-digest-to-test-vps.yml
fi

if [ "$storage_kind" = github-api-workflow-artifact ]; then
  subject_name="image-index.json"
fi
certificate_identity=$source_repository/$workflow@$source_ref

jq -cnS \
  --arg schema "meet-backend/image-attestation-authority/v1" \
  --arg scope "$mode" \
  --arg repository "$repository" \
  --arg sourceRepository "$source_repository" \
  --arg image "$image" \
  --arg releaseSourceDigest "$source" \
  --arg certificateSourceDigest "$certificate_source" \
  --arg signerDigest "$signer" \
  --arg sourceRef "$source_ref" \
  --arg signerWorkflow "$workflow" \
  --arg certificateIdentity "$certificate_identity" \
  --arg oidcIssuer "$issuer" \
  --arg predicateType "$predicate" \
  --arg rootDigest "$root" \
  --arg platformDigest "$platform" \
  --arg subjectName "$subject_name" \
  --arg subjectDigest "$root" \
  --arg storageKind "$storage_kind" \
  --arg bundleDigest "$bundle_digest" \
  --argjson releaseId "${release_id:-null}" \
  --arg tag "${tag:-}" \
  --arg version "${version:-}" \
  --argjson assets "$asset_json" '
  {
    schema:$schema,
    scope:$scope,
    repository:$repository,
    image:$image,
    releaseId:$releaseId,
    tag:(if $tag == "" then null else $tag end),
    version:(if $version == "" then null else $version end),
    sourceRepository:$sourceRepository,
    releaseSourceDigest:$releaseSourceDigest,
    certificateSourceDigest:$certificateSourceDigest,
    signerDigest:$signerDigest,
    sourceRef:$sourceRef,
    signerWorkflow:$signerWorkflow,
    certificateIdentity:$certificateIdentity,
    oidcIssuer:$oidcIssuer,
    predicateType:$predicateType,
    rootDigest:$rootDigest,
    platformDigest:$platformDigest,
    subject:{name:$subjectName,digest:$subjectDigest},
    evidenceStorage:(
      if $storageKind == "github-api-workflow-artifact" then
        {
          kind:$storageKind,
          bundleDigest:$bundleDigest,
          asset:([$assets[] | select(.name == "image-index.json")][0]),
          assets:$assets
        }
      else
        {kind:$storageKind}
      end
    )
  }
  ' || fail "authority output construction failed"
