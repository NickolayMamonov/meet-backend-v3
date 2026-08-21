#!/usr/bin/env bash
set -euo pipefail
usage() { echo "usage: $0 IMAGE ALIAS SOURCE VERSION" >&2; exit 2; }
fail() { echo "test image registry read failed: $*" >&2; exit 1; }
[ "$#" -eq 4 ] || usage
image=$1; alias=$2; source=$3; version=$4
[[ "$image" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$alias" == "test-sha-$source" ]] || usage
[[ "$source" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
ref=$image:$alias
raw=$(mktemp); trap 'rm -f -- "$raw"' EXIT HUP INT TERM
if ! docker buildx imagetools inspect --raw "$ref" >"$raw" 2>/dev/null; then
  jq -cn '{bindings:[]}'; exit 0
fi
root=$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}')
platform=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest] | if length == 1 then .[0] else empty end' "$raw")
[[ "$root" =~ ^sha256:[0-9a-f]{64}$ ]] && [[ "$platform" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "image digests are malformed"
docker pull "$ref" >/dev/null 2>&1 || fail "image pull failed"
labels=$(docker image inspect "$ref" --format '{{json .Config.Labels}}')
referrers=$(jq -c '[.manifests[]? | select(.annotations["vnd.docker.reference.type"] == "attestation-manifest") | {digest,subject:(.annotations["vnd.docker.reference.digest"] // ""),artifactType:"attestation",kind:(if (.annotations["in-toto.io/predicate-type"] // "") | test("slsa|in-toto") then "provenance" else "sbom" end),predicateType:(.annotations["in-toto.io/predicate-type"] // "unknown")}]' "$raw")
[ "$(jq length <<<"$referrers")" -eq 2 ] || fail "provenance/SBOM referrer closure is incomplete"
gh attestation verify "oci://$ref" --repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" >/dev/null 2>&1 || fail "GitHub OCI attestation verification failed"
jq -cnS --arg alias "$alias" --arg image "$image" --arg source "$source" --arg version "$version" --arg root "$root" --arg platform "$platform" --argjson labels "$labels" --argjson referrers "$referrers" --arg repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" '{bindings:[{alias:$alias,digest:$root,root:{digest:$root,mediaType:"application/vnd.oci.image.index.v1+json",manifests:[{digest:$platform,mediaType:"application/vnd.oci.image.manifest.v1+json",platform:{os:"linux",architecture:"amd64"}}],labels:$labels},platform:{digest:$platform,mediaType:"application/vnd.oci.image.manifest.v1+json",labels:$labels},referrers:$referrers,githubAttestations:[{subject:$root,repository:("https://github.com/"+$repo),source:$source,revision:$source,version:$version,workflow:("https://github.com/"+$repo+"/.github/workflows/promote-dev-digest-to-test-vps.yml@refs/heads/dev")}]}]}'
