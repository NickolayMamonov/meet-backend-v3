#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <image> <subject-digest> <raw-index.json>" >&2
  exit 2
fi

IMAGE=$1
SUBJECT_DIGEST=$2
RAW_INDEX=$3
[[ "$SUBJECT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
test -s "$RAW_INDEX"
command -v jq >/dev/null || { echo "jq is required for OCI evidence inspection" >&2; exit 2; }

PLATFORM_SUBJECT=$(jq -r '
  [
    .manifests[]?
    | select(
        .mediaType == "application/vnd.oci.image.manifest.v1+json" and
        .platform.os == "linux" and
        .platform.architecture == "amd64"
      )
    | .digest
  ] | if length == 1 then .[0] else empty end
' "$RAW_INDEX")
if [ -z "$PLATFORM_SUBJECT" ]; then
  jq -e \
    '.mediaType == "application/vnd.oci.image.manifest.v1+json"' \
    "$RAW_INDEX" >/dev/null || {
    echo "OCI index does not contain exactly one linux/amd64 subject manifest" >&2
    exit 1
  }
  PLATFORM_SUBJECT=$SUBJECT_DIGEST
fi

mapfile -t ATTESTATION_DIGESTS < <(
  jq -r --arg subject "$SUBJECT_DIGEST" --arg platform_subject "$PLATFORM_SUBJECT" '
    .manifests[]?
    | select(
        .mediaType == "application/vnd.oci.image.manifest.v1+json" and
        .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
        (
          .annotations["vnd.docker.reference.digest"] == $subject or
          .annotations["vnd.docker.reference.digest"] == $platform_subject
        )
      )
    | .digest
  ' "$RAW_INDEX" | tr -d '\r'
)
[ "${#ATTESTATION_DIGESTS[@]}" -ge 1 ] || {
  echo "OCI index does not contain a subject-bound attestation descriptor" >&2
  exit 1
}

provenance=false
sbom=false
for attestation_digest in "${ATTESTATION_DIGESTS[@]}"; do
  attestation_json=$(docker buildx imagetools inspect --raw "$IMAGE@$attestation_digest")
  while IFS=$'\t' read -r media_type predicate_type; do
    case "$predicate_type" in
      *slsa.dev/provenance*|*in-toto.io/Statement*) provenance=true ;;
      *spdx.dev/Document*|*cyclonedx.org/bom*) sbom=true ;;
    esac
    case "$media_type" in
      application/vnd.in-toto+json|application/vnd.oci.image.layer.v1.tar+gzip) ;;
      *) echo "unexpected attestation layer media type" >&2; exit 1 ;;
    esac
  done < <(
    jq -r '
      .layers[]?
      | [
          .mediaType,
          (.annotations["in-toto.io/predicate-type"] // "")
        ]
      | @tsv
    ' <<<"$attestation_json"
  )
done

[ "$provenance" = true ] || { echo "subject-bound provenance descriptor is missing" >&2; exit 1; }
[ "$sbom" = true ] || { echo "subject-bound SBOM descriptor is missing" >&2; exit 1; }
printf 'provenance=true\nsbom=true\n'
