#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 IMAGE ALIAS SOURCE VERSION" >&2; exit 2; }
fail() { echo "test image registry read failed: $*" >&2; exit 1; }

[ "$#" -eq 4 ] || usage
image=$1
alias=$2
source=$3
version=$4
[[ "$image" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$alias" == "test-sha-$source" ]] || usage
[[ "$source" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
for command_name in docker gh jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "GITHUB_REPOSITORY is malformed"

ref=$image:$alias
tmp=$(mktemp -d)
main_bash_pid=$BASHPID
cleanup_tmp() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$BASHPID" = "$main_bash_pid" ]; then
    rm -r -- "$tmp"
  fi
  exit "$status"
}
trap cleanup_tmp EXIT HUP INT TERM

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "OCI digest is malformed"
}

validate_descriptor() {
  local descriptor=$1
  jq -e '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . > 0)
  ' <<<"$descriptor" >/dev/null ||
    fail "OCI descriptor is malformed"
}

validate_raw_manifest() {
  local destination=$1 expected_digest=${2:-}
  local expected_media=${3:-} expected_size=${4:-}
  local actual_digest actual_media actual_size
  jq -e 'type == "object" and .schemaVersion == 2' "$destination" >/dev/null ||
    fail "registry returned malformed OCI JSON"
  actual_digest="sha256:$(sha256sum "$destination" | awk '{print $1}')"
  actual_media=$(jq -r '.mediaType // empty' "$destination")
  actual_size=$(wc -c <"$destination" | tr -d ' ')
  validate_digest "$actual_digest"
  [ -n "$actual_media" ] || fail "OCI manifest media type is missing"
  [ "$actual_size" -gt 0 ] || fail "OCI manifest is empty"
  [ -z "$expected_digest" ] || [ "$actual_digest" = "$expected_digest" ] ||
    fail "OCI manifest bytes do not match its digest"
  [ -z "$expected_media" ] || [ "$actual_media" = "$expected_media" ] ||
    fail "OCI manifest media type disagrees with its descriptor"
  [ -z "$expected_size" ] || [ "$actual_size" -eq "$expected_size" ] ||
    fail "OCI manifest size disagrees with its descriptor"
  printf '%s\t%s\t%s\n' "$actual_digest" "$actual_media" "$actual_size"
}

read_raw_manifest() {
  local reference=$1 destination=$2 expected_digest=${3:-}
  local expected_media=${4:-} expected_size=${5:-}
  docker buildx imagetools inspect --raw "$reference" >"$destination" 2>/dev/null ||
    fail "registry manifest read failed"
  validate_raw_manifest "$destination" "$expected_digest" \
    "$expected_media" "$expected_size"
}

read_package_inventory() {
  local package=${image#ghcr.io/}
  local owner=${package%%/*}
  local name=${package#*/}
  gh api --paginate --slurp \
    "users/$owner/packages/container/$name/versions?per_page=100" \
    >"$tmp/packages.json" 2>/dev/null ||
    fail "package inventory read failed"
  jq -e '
    type == "array" and all(.[]; type == "array") and
    all(add // [] |
      .[];
      (.name | type == "string" and
        test("^sha256:[0-9a-f]{64}$")) and
      ((.metadata.container.tags // []) | type == "array") and
      all((.metadata.container.tags // [])[]?;
        type == "string" and length > 0))
  ' "$tmp/packages.json" >/dev/null ||
    fail "package inventory is malformed"
  jq -c 'add // []' "$tmp/packages.json"
}

raw=$tmp/root.json
if ! docker buildx imagetools inspect --raw "$ref" >"$raw" 2>/dev/null; then
  inventory=$(read_package_inventory)
  alias_digests=$(jq -c --arg alias "$alias" '
    [.[] |
      select(any((.metadata.container.tags // [])[]?; . == $alias)) |
      .name] | unique
  ' <<<"$inventory") || fail "package inventory lookup failed"
  case "$(jq length <<<"$alias_digests")" in
    0) jq -cn '{bindings:[]}'; exit 0 ;;
    1) fail "registry manifest inspection failed for an existing alias" ;;
    *) fail "package inventory binds the alias to multiple digests" ;;
  esac
fi
root_read=$(validate_raw_manifest "$raw")

IFS=$'\t' read -r root root_media root_size <<<"$root_read"
[ "$root_media" = "application/vnd.oci.image.index.v1+json" ] ||
  fail "alias root is not an OCI image index"
jq -e '
  .schemaVersion == 2 and
  .mediaType == "application/vnd.oci.image.index.v1+json" and
  (.manifests | type == "array" and length > 0) and
  all(.manifests[]; type == "object")
' "$raw" >/dev/null || fail "alias root index is malformed"
while IFS= read -r descriptor; do validate_descriptor "$descriptor"; done < <(
  jq -c '.manifests[]' "$raw"
)

platform_descriptor=$(jq -c '
  [.manifests[] |
    select(
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      .platform.os == "linux" and
      .platform.architecture == "amd64" and
      ((.platform.variant? // "") == "")
    )] |
  if length == 1 then .[0] else empty end
' "$raw")
[ -n "$platform_descriptor" ] ||
  fail "root index has no unique exact linux/amd64 platform"
platform=$(jq -r '.digest' <<<"$platform_descriptor")
platform_media=$(jq -r '.mediaType' <<<"$platform_descriptor")
platform_size=$(jq -r '.size' <<<"$platform_descriptor")
validate_digest "$root"
validate_digest "$platform"
[ "$root" != "$platform" ] || fail "root and platform digests are identical"
jq -e --arg root "$root" --arg platform "$platform" '
  all(.manifests[];
    (
      .digest == $platform and
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      .platform.os == "linux" and
      .platform.architecture == "amd64" and
      ((.platform.variant? // "") == "")
    ) or (
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      .platform.os == "unknown" and
      .platform.architecture == "unknown" and
      .annotations["vnd.docker.reference.type"] ==
        "attestation-manifest" and
      (
        .annotations["vnd.docker.reference.digest"] == $root or
        .annotations["vnd.docker.reference.digest"] == $platform
      )
    )
  )
' "$raw" >/dev/null ||
  fail "root index contains a foreign or inexact platform descriptor"

platform_raw=$tmp/platform.json
read_raw_manifest "$image@$platform" "$platform_raw" \
  "$platform" "$platform_media" "$platform_size" >/dev/null ||
  fail "platform manifest read failed"
jq -e '
  .schemaVersion == 2 and
  .mediaType == "application/vnd.oci.image.manifest.v1+json" and
  (.config | type == "object") and
  (.layers | type == "array")
' "$platform_raw" >/dev/null || fail "linux/amd64 platform manifest is malformed"

docker pull "$image@$platform" >/dev/null 2>&1 ||
  fail "platform image pull failed"
labels=$(
  docker image inspect "$image@$platform" --format '{{json .Config.Labels}}'
) || fail "platform label read failed"
jq -e 'type == "object"' <<<"$labels" >/dev/null ||
  fail "platform labels are malformed"
actual_source=$(jq -r '."org.opencontainers.image.revision" // empty' <<<"$labels")
actual_version=$(jq -r '."org.opencontainers.image.version" // empty' <<<"$labels")
actual_repository=$(jq -r '."org.opencontainers.image.source" // empty' <<<"$labels")
[ "$actual_repository" = "https://github.com/$GITHUB_REPOSITORY" ] ||
  fail "platform source repository label does not match"
[ "$actual_source" = "$source" ] || fail "platform source label does not match"
[ "$actual_version" = "$version" ] || fail "platform version label does not match"

: >"$tmp/referrers.jsonl"
while IFS= read -r descriptor; do
  referrer_digest=$(jq -r '.digest' <<<"$descriptor")
  referrer_media=$(jq -r '.mediaType' <<<"$descriptor")
  referrer_size=$(jq -r '.size' <<<"$descriptor")
  descriptor_subject=$(jq -r \
    '.annotations["vnd.docker.reference.digest"] // empty' <<<"$descriptor")
  validate_digest "$descriptor_subject"
  [ "$descriptor_subject" = "$root" ] ||
    [ "$descriptor_subject" = "$platform" ] ||
    fail "attestation descriptor is bound to a foreign subject"
  referrer_raw="$tmp/referrer-${referrer_digest#sha256:}.json"
  read_raw_manifest "$image@$referrer_digest" "$referrer_raw" \
    "$referrer_digest" "$referrer_media" "$referrer_size" >/dev/null ||
    fail "attestation manifest read failed"
  declared_subject=$(jq -r '.subject.digest // empty' "$referrer_raw")
  wrapper_artifact_type=$(jq -r '.artifactType // empty' "$referrer_raw")
  [ -z "$declared_subject" ] ||
    [ "$declared_subject" = "$descriptor_subject" ] ||
    fail "attestation manifest subject disagrees with its descriptor"
  [ -n "$wrapper_artifact_type" ] ||
    fail "attestation manifest artifact type is missing"
  jq -e '
    (.layers | type == "array" and length > 0) and
    all(.layers[];
      (.digest | type == "string" and
        test("^sha256:[0-9a-f]{64}$")) and
      (.mediaType | type == "string" and length > 0) and
      (.size | type == "number" and floor == . and . > 0) and
      (.annotations["in-toto.io/predicate-type"] |
        type == "string" and length > 0))
  ' "$referrer_raw" >/dev/null ||
    fail "attestation predicate binding is missing"
  while IFS= read -r layer; do
    layer=${layer%$'\r'}
    layer_digest=$(jq -r '.digest' <<<"$layer")
    layer_artifact_type=$(jq -r '.mediaType' <<<"$layer")
    predicate=$(jq -r '.annotations["in-toto.io/predicate-type"]' <<<"$layer")
    case "$predicate" in
      https://slsa.dev/provenance/*)
        kind=provenance
        ;;
      https://spdx.dev/Document|http://cyclonedx.org/schema)
        kind=sbom
        ;;
      *)
        fail "attestation predicate type is unsupported"
        ;;
    esac
    jq -cnS --arg digest "$layer_digest" \
      --arg subject "$descriptor_subject" --arg kind "$kind" \
      --arg artifactType "$layer_artifact_type" --arg predicateType "$predicate" \
      '{digest:$digest,subject:$subject,kind:$kind,
        artifactType:$artifactType,predicateType:$predicateType}' \
      >>"$tmp/referrers.jsonl"
  done < <(
    jq -cS '.layers[]' "$referrer_raw"
  )
done < <(
  jq -c '
    .manifests[] |
    select(
      .annotations["vnd.docker.reference.type"] == "attestation-manifest"
    )
  ' "$raw"
)
jq -cS -s 'sort_by(.kind,.digest,.predicateType)' \
  "$tmp/referrers.jsonl" >"$tmp/referrers.json"
referrers=$(jq -c . "$tmp/referrers.json")
[ "$(jq length <<<"$referrers")" -gt 0 ] ||
  fail "subject-bound provenance/SBOM descriptors are missing"
[ "$(jq '[.[] | select(.kind == "provenance")] | length' <<<"$referrers")" -eq 1 ] ||
  fail "provenance descriptor binding is not unique"
[ "$(jq '[.[] | select(.kind == "sbom")] | length' <<<"$referrers")" -eq 1 ] ||
  fail "SBOM descriptor binding is not unique"

verified=$tmp/verified-attestations.json
gh attestation verify "oci://$image@$root" \
  --repo "$GITHUB_REPOSITORY" --source-digest "$source" --format json \
  >"$verified" 2>/dev/null ||
  fail "GitHub OCI attestation verification failed"
jq -e --arg root "${root#sha256:}" --arg platform "${platform#sha256:}" \
  --arg repository "https://github.com/$GITHUB_REPOSITORY" \
  --arg source "$source" '
  (type == "array" and length == 1) and
  (.[0] as $verified |
    ($verified.verificationResult.statement as $statement |
      ($statement.predicateType |
        type == "string" and length > 0) and
      ([$statement.subject[]? |
        select(.digest.sha256? == $root or .digest.sha256? == $platform)] |
        length) == 1) and
    ($verified.verificationResult.signature.certificate as $certificate |
      $certificate.sourceRepositoryURI == $repository and
      $certificate.sourceRepositoryDigest == $source and
      ($certificate.sourceRepositoryRef |
        type == "string" and startswith("refs/")) and
      ($certificate.buildSignerURI |
        type == "string" and
        startswith($repository + "/.github/workflows/") and
        endswith("@" + $certificate.sourceRepositoryRef)) and
      $certificate.subjectAlternativeName == $certificate.buildSignerURI))
' "$verified" >/dev/null ||
  fail "verified GitHub attestation identity or subject is malformed"
github_attestations=$(jq -cS --arg root "$root" --arg platform "$platform" \
  --arg version "$actual_version" '
  [
    .[] |
    .verificationResult as $result |
    $result.signature.certificate as $certificate |
    ([ $result.statement.subject[] |
      select(
        .digest.sha256? == ($root | sub("^sha256:";"")) or
        .digest.sha256? == ($platform | sub("^sha256:";""))
      ) |
      "sha256:" + .digest.sha256 ][0]) as $subject |
    {
      subject:$subject,
      repository:$certificate.sourceRepositoryURI,
      source:$certificate.sourceRepositoryDigest,
      revision:$certificate.sourceRepositoryDigest,
      version:$version,
      workflow:$certificate.buildSignerURI
    }
  ]
' "$verified") || fail "verified GitHub attestation normalization failed"

root_manifest=$(jq -c '
  [.manifests[] |
    select(
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      .platform.os == "linux" and
      .platform.architecture == "amd64" and
      ((.platform.variant? // "") == ""
    ))] | .[0]
' "$raw") || fail "linux/amd64 descriptor normalization failed"
jq -cnS --arg alias "$alias" --arg root "$root" \
  --arg rootMedia "$root_media" --arg platform "$platform" \
  --arg platformMedia "$platform_media" --argjson labels "$labels" \
  --argjson rootManifest "$root_manifest" --argjson referrers "$referrers" \
  --argjson githubAttestations "$github_attestations" '
  {
    bindings:[{
      alias:$alias,
      digest:$root,
      root:{
        digest:$root,
        mediaType:$rootMedia,
        manifests:[$rootManifest],
        labels:$labels
      },
      platform:{
        digest:$platform,
        mediaType:$platformMedia,
        labels:$labels
      },
      referrers:$referrers,
      githubAttestations:$githubAttestations
    }]
  }
'
