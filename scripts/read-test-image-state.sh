#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
  echo "usage: $0 IMAGE ALIAS SOURCE VERSION" >&2
  exit 2
}

fail() {
  echo "test image registry read failed: $*" >&2
  exit 1
}

[ "$#" -eq 4 ] || usage
image=$1
alias=$2
source=$3
version=$4
[[ "$image" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$alias" == "test-sha-$source" ]] || usage
[[ "$source" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage

for command_name in base64 curl docker gh jq sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "GITHUB_REPOSITORY is malformed"

package=${image#ghcr.io/}
owner=${package%%/*}
name=${package#*/}
tmp=$(mktemp -d)
netrc=
registry_config=
main_bash_pid=$BASHPID
# shellcheck disable=SC2329
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$BASHPID" = "$main_bash_pid" ]; then
    [ -z "$netrc" ] || rm -f -- "$netrc"
    [ -z "$registry_config" ] || rm -f -- "$registry_config"
    rm -r -- "$tmp"
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "OCI digest is malformed"
}

validate_descriptor() {
  jq -e '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . > 0)
  ' <<<"$1" >/dev/null || fail "OCI descriptor is malformed"
}

validate_raw_manifest() {
  local file=$1 expected_digest=${2:-} expected_media=${3:-} expected_size=${4:-}
  local actual_digest actual_media actual_size
  jq -e 'type == "object" and .schemaVersion == 2' "$file" >/dev/null ||
    fail "registry returned malformed OCI JSON"
  actual_digest="sha256:$(sha256sum "$file" | awk '{print $1}')"
  actual_media=$(jq -r '.mediaType // empty' "$file")
  actual_size=$(wc -c <"$file" | tr -d ' ')
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

setup_registry_auth() {
  local github_token username response status
  github_token=$(gh auth token 2>/dev/null) || fail "GHCR credential read failed"
  [ -n "$github_token" ] || fail "GHCR credential is empty"
  username=$("$SCRIPT_DIR/resolve-ghcr-username.sh") ||
    fail "GHCR username resolution failed"
  [ -n "$username" ] || fail "GHCR username is empty"
  umask 077
  netrc=$tmp/ghcr.netrc
  printf 'machine ghcr.io login %s password %s\n' "$username" "$github_token" >"$netrc"
  chmod 600 "$netrc"
  response=$tmp/token.json
  status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --netrc-file "$netrc" --output "$response" --write-out '%{http_code}' \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:$package:pull") ||
    fail "GHCR registry token exchange failed"
  [ "$status" = 200 ] || fail "GHCR registry token exchange returned HTTP $status"
  registry_token=$(jq -er '
    if (.token | type == "string" and length > 0) then .token
    else error("token is missing")
    end
  ' "$response") ||
    fail "GHCR registry token response is malformed"
  registry_config=$tmp/ghcr.config
  {
    printf 'header = "Authorization: Bearer %s"\n' "$registry_token"
    printf '%s\n' 'header = "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json"'
  } >"$registry_config"
  chmod 600 "$registry_config"
}

registry_get() {
  local reference=$1 file=$2 response
  response=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --config "$registry_config" \
    --output "$file" --write-out '%{http_code}' \
    "https://ghcr.io/v2/$package/manifests/$reference") ||
    fail "OCI manifest transport failed"
  REGISTRY_STATUS=$response
}

read_package_inventory() {
  local file=$tmp/packages.json
  gh api --paginate --slurp \
    "users/$owner/packages/container/$name/versions?per_page=100" \
    >"$file" 2>/dev/null || fail "package inventory read failed"
  jq -e '
    type == "array" and length > 0 and all(.[]; type == "array") and
    ((add) as $rows |
      all($rows[]; type == "object" and
        (.id | type == "number" and floor == . and . > 0) and
        (.name | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
        (.metadata | type == "object") and
        (.metadata.container | type == "object") and
        (.metadata.container.tags | type == "array" and
          all(.[]; type == "string" and length > 0) and
          (unique | length == length))) and
      ([$rows[].id] | unique | length == ($rows | length)) and
      ([$rows[].name] | unique | length == ($rows | length)) and
      ([$rows[].metadata.container.tags[]] | unique | length ==
        ([$rows[].metadata.container.tags[]] | length)))
  ' "$file" >/dev/null || fail "package inventory is malformed"
  jq -c 'add' "$file"
}

alias_rows() {
  local inventory=$1
  jq -c --arg alias "$alias" \
    '[.[] | select(any(.metadata.container.tags[]; . == $alias))]' \
    <<<"$inventory"
}

validate_missing_manifest() {
  jq -e '
    type == "object" and (.errors | type == "array" and length > 0) and
    all(.errors[];
      type == "object" and .code == "MANIFEST_UNKNOWN" and
      (.message | type == "string" and length > 0))
  ' "$1" >/dev/null || fail "registry 404 response is not a missing-manifest error"
}

normalize_attestation_bundle() {
  local bundle=$1 label=$2 statement
  local subject_hex predicate_type source_repository source_digest workflow
  local bundle_sha
  statement=$tmp/attestation-statement-$label.json
  jq -e '
    type == "object" and
    (.mediaType | type == "string" and length > 0) and
    (.dsseEnvelope | type == "object") and
    (.dsseEnvelope.payload | type == "string" and length > 0) and
    (.dsseEnvelope.signatures | type == "array" and length > 0)
  ' "$bundle" >/dev/null || fail "attestation bundle $label is malformed"
  jq -rj '.dsseEnvelope.payload' "$bundle" |
    base64 --decode >"$statement" 2>/dev/null ||
    fail "attestation bundle $label payload is not valid base64"
  jq -e \
    --arg repository "https://github.com/$GITHUB_REPOSITORY" \
    --arg source "$source" \
    --arg ref "refs/heads/dev" \
    --arg root "${root#sha256:}" \
    --arg platform "${platform#sha256:}" '
    type == "object" and
    ._type == "https://in-toto.io/Statement/v1" and
    (.predicateType | type == "string" and length > 0) and
    (.subject | type == "array" and length == 1) and
    (.subject[0].name | type == "string" and length > 0) and
    (.subject[0].digest | type == "object" and
      (keys | sort) == ["sha256"] and
      (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.sha256 == $root or .sha256 == $platform)) and
    (.predicate.buildDefinition.externalParameters.workflow.repository == $repository) and
    (.predicate.buildDefinition.externalParameters.workflow.ref == $ref) and
    ([
      .predicate.buildDefinition.resolvedDependencies[]? |
      select(.uri? == ("git+" + $repository + "@" + $ref)) |
      select(.digest.gitCommit? == $source)
    ] | length == 1) and
    (.predicate.runDetails.builder.id |
      type == "string" and
      startswith($repository + "/.github/workflows/") and
      endswith("@" + $ref))
  ' "$statement" >/dev/null ||
    fail "attestation bundle $label has an invalid subject or source claim"

  subject_hex=$(jq -r '.subject[0].digest.sha256' "$statement")
  predicate_type=$(jq -r '.predicateType' "$statement")
  source_repository=$(jq -r '.predicate.buildDefinition.externalParameters.workflow.repository' "$statement")
  source_digest="$source"
  workflow=$(jq -r '.predicate.runDetails.builder.id' "$statement")
  bundle_sha=$(jq -cS . "$bundle" | tr -d '\r\n' |
    sha256sum | awk '{print $1}') ||
    fail "attestation bundle $label hashing failed"
  jq -cnS \
    --arg subject "sha256:$subject_hex" \
    --arg predicateType "$predicate_type" \
    --arg sourceRepository "$source_repository" \
    --arg sourceDigest "$source_digest" \
    --arg workflow "$workflow" \
    --arg bundleDigest "sha256:$bundle_sha" \
    '{
      subject:$subject,
      predicateType:$predicateType,
      sourceRepository:$sourceRepository,
      sourceDigest:$sourceDigest,
      workflow:$workflow,
      bundleDigest:$bundleDigest,
      claimKey:($subject + "|" + $predicateType + "|" + $sourceRepository +
        "|" + $sourceDigest + "|" + $workflow)
    }'
}

normalize_raw_attestations() {
  local input=$1 output=$2 count index records bundle
  jq -e '
    type == "object" and
    (.attestations | type == "array") and
    all(.attestations[];
      type == "object" and (.bundle | type == "object"))
  ' "$input" >/dev/null || fail "GitHub attestation collection is malformed"
  count=$(jq -r '.attestations | length' "$input")
  records=$tmp/raw-attestation-records.jsonl
  : >"$records"
  for ((index = 0; index < count; index++)); do
    bundle=$tmp/raw-attestation-$index.json
    jq -cS ".attestations[$index].bundle" "$input" >"$bundle" ||
      fail "GitHub attestation bundle $index cannot be read"
    normalize_attestation_bundle "$bundle" "raw-$index" >>"$records"
  done
  jq -cS -s '
    if (map(.bundleDigest) | unique | length) != length then
      error("duplicate attestation bundle digest")
    elif (map(.claimKey) | unique | length) != length then
      error("duplicate attestation claim identity")
    else sort_by(.subject,.predicateType,.workflow,.bundleDigest)
    end
  ' "$records" >"$output" ||
    fail "GitHub attestation collection has duplicate identity"
}

normalize_verified_attestations() {
  local input=$1 output=$2 count index records bundle normalized
  jq -e '
    type == "array" and length > 0 and
    all(.[];
      type == "object" and
      (.attestation | type == "object") and
      (.attestation.bundle | type == "object") and
      (.verificationResult | type == "object"))
  ' "$input" >/dev/null || fail "verified GitHub attestation output is malformed"
  count=$(jq -r 'length' "$input")
  records=$tmp/verified-attestation-records.jsonl
  : >"$records"
  for ((index = 0; index < count; index++)); do
    bundle=$tmp/verified-attestation-$index.json
    jq -cS ".[$index].attestation.bundle" "$input" >"$bundle" ||
      fail "verified attestation bundle $index cannot be read"
    normalized=$(normalize_attestation_bundle "$bundle" "verified-$index")
    jq -e \
      --arg repository "https://github.com/$GITHUB_REPOSITORY" \
      --arg source "$source" \
      --arg ref "refs/heads/dev" \
      --argjson claim "$normalized" \
      --argjson index "$index" '
      .[$index] |
      .verificationResult.statement as $statement |
      .verificationResult.signature.certificate as $certificate |
      ($statement.subject | type == "array" and length == 1) and
      ($statement.predicateType == $claim.predicateType) and
      ($statement.subject[0].digest.sha256 ==
        ($claim.subject | sub("^sha256:";""))) and
      $certificate.sourceRepositoryURI == $repository and
      $certificate.sourceRepositoryDigest == $source and
      $certificate.sourceRepositoryRef == $ref and
      ($certificate.buildSignerURI |
        type == "string" and
        startswith($repository + "/.github/workflows/") and
        endswith("@" + $ref)) and
      $certificate.buildSignerURI == $claim.workflow and
      $certificate.subjectAlternativeName == $certificate.buildSignerURI
    ' "$input" >/dev/null ||
      fail "verified attestation $index has an invalid subject or source workflow"
    printf '%s\n' "$normalized" >>"$records"
  done
  jq -cS -s '
    if (map(.bundleDigest) | unique | length) != length then
      error("duplicate verified attestation bundle digest")
    elif (map(.claimKey) | unique | length) != length then
      error("duplicate verified attestation claim identity")
    else sort_by(.subject,.predicateType,.workflow,.bundleDigest)
    end
  ' "$records" >"$output" ||
    fail "verified attestations have duplicate identity"
}

read_raw_manifest() {
  local reference=$1 file=$2 expected_digest=${3:-}
  local expected_media=${4:-} expected_size=${5:-}
  registry_get "$reference" "$file"
  [ "$REGISTRY_STATUS" = 200 ] ||
    fail "registry manifest read returned HTTP $REGISTRY_STATUS"
  validate_raw_manifest "$file" "$expected_digest" "$expected_media" "$expected_size"
}

setup_registry_auth
raw=$tmp/root.json
registry_get "$alias" "$raw"
if [ "$REGISTRY_STATUS" = 404 ]; then
  validate_missing_manifest "$raw"
  inventory=$(read_package_inventory)
  [ "$(jq 'length' <<<"$(alias_rows "$inventory")")" -eq 0 ] ||
    fail "registry manifest is absent but package inventory binds the alias"
  jq -cn '{bindings:[]}'
  exit 0
fi
[ "$REGISTRY_STATUS" = 200 ] ||
  fail "registry manifest read returned HTTP $REGISTRY_STATUS"
root_read=$(validate_raw_manifest "$raw")
IFS=$'\t' read -r root root_media _ <<<"$root_read"
[ "$root_media" = "application/vnd.oci.image.index.v1+json" ] ||
  fail "alias root is not an OCI image index"

inventory=$(read_package_inventory)
rows=$(alias_rows "$inventory")
[ "$(jq 'length' <<<"$rows")" -eq 1 ] ||
  fail "candidate alias binding is missing or ambiguous"
row=$(jq -c '.[0]' <<<"$rows")
[ "$(jq -r '.name' <<<"$row")" = "$root" ] ||
  fail "candidate alias binds a different registry digest"
[ "$(jq '.metadata.container.tags | length' <<<"$row")" -eq 1 ] ||
  fail "candidate registry version has extra aliases"
[ "$(jq -r '.metadata.container.tags[0]' <<<"$row")" = "$alias" ] ||
  fail "candidate registry alias binding is not exact"

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
  [.manifests[] | select(
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    .platform.os == "linux" and .platform.architecture == "amd64" and
    ((.platform.variant? // "") == "")
  )] | if length == 1 then .[0] else empty end
' "$raw")
[ -n "$platform_descriptor" ] || fail "root index has no unique exact linux/amd64 platform"
platform=$(jq -r '.digest' <<<"$platform_descriptor")
platform_media=$(jq -r '.mediaType' <<<"$platform_descriptor")
platform_size=$(jq -r '.size' <<<"$platform_descriptor")
validate_digest "$root"
validate_digest "$platform"
[ "$root" != "$platform" ] || fail "root and platform digests are identical"
jq -e --arg root "$root" --arg platform "$platform" '
  all(.manifests[];
    (.digest == $platform and .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      .platform.os == "linux" and .platform.architecture == "amd64" and
      ((.platform.variant? // "") == "")) or
    (.mediaType == "application/vnd.oci.image.manifest.v1+json" and
      .platform.os == "unknown" and .platform.architecture == "unknown" and
      .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
      (.annotations["vnd.docker.reference.digest"] == $root or
       .annotations["vnd.docker.reference.digest"] == $platform))
  )
' "$raw" >/dev/null || fail "root index contains a foreign or inexact platform descriptor"

platform_raw=$tmp/platform.json
read_raw_manifest "$platform" "$platform_raw" "$platform" "$platform_media" "$platform_size" >/dev/null
jq -e '
  .schemaVersion == 2 and .mediaType == "application/vnd.oci.image.manifest.v1+json" and
  (.config | type == "object") and (.layers | type == "array")
' "$platform_raw" >/dev/null || fail "linux/amd64 platform manifest is malformed"
docker pull "$image@$platform" >/dev/null 2>&1 || fail "platform image pull failed"
labels=$(docker image inspect "$image@$platform" --format '{{json .Config.Labels}}') ||
  fail "platform label read failed"
jq -e 'type == "object"' <<<"$labels" >/dev/null || fail "platform labels are malformed"
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
  descriptor_subject=$(jq -r '.annotations["vnd.docker.reference.digest"] // empty' <<<"$descriptor")
  validate_digest "$descriptor_subject"
  [ "$descriptor_subject" = "$root" ] || [ "$descriptor_subject" = "$platform" ] ||
    fail "attestation descriptor is bound to a foreign subject"
  referrer_raw=$tmp/referrer-${referrer_digest#sha256:}.json
  read_raw_manifest "$referrer_digest" "$referrer_raw" "$referrer_digest" \
    "$referrer_media" "$referrer_size" >/dev/null
  declared_subject=$(jq -r '.subject.digest // empty' "$referrer_raw")
  [ -z "$declared_subject" ] || [ "$declared_subject" = "$descriptor_subject" ] ||
    fail "attestation manifest subject disagrees with its descriptor"
  wrapper_artifact_type=$(jq -r '.artifactType // empty' "$referrer_raw")
  [ -n "$wrapper_artifact_type" ] || fail "attestation manifest artifact type is missing"
  jq -e '
    (.layers | type == "array" and length > 0) and
    all(.layers[]; (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.mediaType | type == "string" and length > 0) and
      (.size | type == "number" and floor == . and . > 0) and
      (.annotations["in-toto.io/predicate-type"] | type == "string" and length > 0))
  ' "$referrer_raw" >/dev/null || fail "attestation predicate binding is missing"
  while IFS= read -r layer; do
    kind=
    predicate=$(jq -r '.annotations["in-toto.io/predicate-type"]' <<<"$layer")
    case "$predicate" in
      https://slsa.dev/provenance/*) kind=provenance ;;
      https://spdx.dev/Document|http://cyclonedx.org/schema) kind=sbom ;;
      *) fail "attestation predicate type is unsupported" ;;
    esac
    jq -cnS --arg digest "$(jq -r '.digest' <<<"$layer")" \
      --arg subject "$descriptor_subject" --arg kind "$kind" \
      --arg artifactType "$(jq -r '.mediaType' <<<"$layer")" \
      --arg predicateType "$predicate" \
      '{digest:$digest,subject:$subject,kind:$kind,artifactType:$artifactType,predicateType:$predicateType}' \
      >>"$tmp/referrers.jsonl"
  done < <(jq -cS '.layers[]' "$referrer_raw")
done < <(jq -c '.manifests[] | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest")' "$raw")
referrers=$(jq -cS -s 'sort_by(.kind,.digest,.predicateType)' "$tmp/referrers.jsonl")
[ "$(jq '[.[] | select(.kind=="provenance")] | length' <<<"$referrers")" -eq 1 ] ||
  fail "provenance descriptor binding is not unique"
[ "$(jq '[.[] | select(.kind=="sbom")] | length' <<<"$referrers")" -eq 1 ] ||
  fail "SBOM descriptor binding is not unique"

attestation_status=missing
github_attestations=[]
attestation_api=$tmp/attestations.json
if ! gh api "repos/$GITHUB_REPOSITORY/attestations/$root" >"$attestation_api" 2>"$tmp/attestation-error"; then
  fail "GitHub attestation collection failed"
fi
raw_attestations=$tmp/raw-attestations.json
normalize_raw_attestations "$attestation_api" "$raw_attestations"
if [ "$(jq 'length' "$raw_attestations")" -gt 0 ]; then
  verified=$tmp/verified-attestations.json
  gh attestation verify "oci://$image@$root" --repo "$GITHUB_REPOSITORY" \
    --source-digest "$source" --format json >"$verified" 2>"$tmp/verify-error" ||
    fail "GitHub OCI attestation verification failed"
  verified_attestations=$tmp/verified-attestations-normalized.json
  normalize_verified_attestations "$verified" "$verified_attestations"
  jq -n -e --slurpfile raw "$raw_attestations" \
    --slurpfile verified "$verified_attestations" '
    ($raw[0] | length) == ($verified[0] | length) and
    ([$raw[0][].bundleDigest] | sort) ==
      ([$verified[0][].bundleDigest] | sort) and
    ([$raw[0][].claimKey] | sort) ==
      ([$verified[0][].claimKey] | sort)
  ' >/dev/null ||
    fail "raw and cryptographically verified attestations do not correspond one-to-one"
  github_attestations=$(jq -cS --arg version "$actual_version" '
    map({
      subject,
      repository:.sourceRepository,
      source:.sourceDigest,
      revision:.sourceDigest,
      version:$version,
      workflow
    })
  ' "$verified_attestations")
  attestation_status=verified
fi

root_manifest=$(jq -c '[.manifests[] | select(.digest == $platform)] | .[0]' \
  --arg platform "$platform" "$raw")
jq -cnS --arg alias "$alias" --arg root "$root" --arg rootMedia "$root_media" \
  --arg platform "$platform" --arg platformMedia "$platform_media" \
  --arg attestationStatus "$attestation_status" --argjson labels "$labels" \
  --argjson rootManifest "$root_manifest" --argjson referrers "$referrers" \
  --argjson githubAttestations "$github_attestations" '
  {bindings:[{alias:$alias,digest:$root,rootDigest:$root,platformDigest:$platform,
    attestationStatus:$attestationStatus,
    root:{digest:$root,mediaType:$rootMedia,manifests:[$rootManifest],labels:$labels},
    platform:{digest:$platform,mediaType:$platformMedia,labels:$labels},
    referrers:$referrers,githubAttestations:$githubAttestations}]}
'
