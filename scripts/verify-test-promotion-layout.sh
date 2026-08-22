#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --layout PATH --protected-state PATH --output PATH" >&2
  exit 2
}

fail() {
  echo "test promotion OCI layout verification failed: $*" >&2
  exit 1
}

layout=
protected_state=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --layout) [ "$#" -ge 2 ] && [ -z "$layout" ] || usage; layout=$2; shift 2 ;;
    --protected-state) [ "$#" -ge 2 ] && [ -z "$protected_state" ] || usage; protected_state=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done

[ -d "$layout" ] && [ ! -L "$layout" ] || usage
[ -f "$layout/index.json" ] && [ ! -L "$layout/index.json" ] || usage
[ -f "$layout/oci-layout" ] && [ ! -L "$layout/oci-layout" ] || usage
[ -f "$protected_state" ] && [ ! -L "$protected_state" ] || usage
[ -n "$output" ] && [ -d "$(dirname -- "$output")" ] || usage
[ ! -L "$output" ] || fail "output path is unsafe"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

tmp=$output.tmp.$$
trap 'rm -f -- "$tmp"' EXIT HUP INT TERM

layout_state=$(jq -cS '
  def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def descriptor:
    type == "object" and
    (.digest | digest) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . > 0);
  . as $index |
  if type == "object" and
     (.schemaVersion == 2) and
     (.manifests | type == "array" and length >= 1 and all(.[]; descriptor))
  then
    ([
      .manifests[] |
      select(.mediaType == "application/vnd.oci.image.index.v1+json" and
        (.platform? == null) and
        (.annotations["vnd.docker.reference.type"]? != "attestation-manifest"))
    ] | if length == 1 then .[0] else error("candidate root is not unique") end) as $root |
    ($root.digest) as $rootDigest |
    {
      rootDigest:$rootDigest,
      rootDescriptor:$root,
      indexDescriptors:($index.manifests | map(.digest) | unique | sort)
    }
  else error("OCI index shape is invalid")
  end
' "$layout/index.json") || fail "OCI index is not a closed candidate layout"

root_digest=$(jq -r '.rootDigest' <<<"$layout_state")
root_blob="$layout/blobs/sha256/${root_digest#sha256:}"
[ -f "$root_blob" ] && [ ! -L "$root_blob" ] || fail "candidate root blob is unavailable"
[ "sha256:$(sha256sum "$root_blob" | awk '{print $1}')" = "$root_digest" ] ||
  fail "candidate root blob digest does not match its descriptor"

root_state=$(jq -cS --arg root_digest "$root_digest" '
  def descriptor:
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . > 0);
  . as $root |
  if type == "object" and
     .schemaVersion == 2 and
     .mediaType == "application/vnd.oci.image.index.v1+json" and
     (.manifests | type == "array" and length >= 1 and all(.[]; descriptor))
  then
    ([
      .manifests[] |
      select(.mediaType == "application/vnd.oci.image.manifest.v1+json" and
        .platform.os == "linux" and .platform.architecture == "amd64" and
        ((.platform.variant? // "") == ""))
    ] | if length == 1 then .[0] else error("candidate linux/amd64 platform is not unique") end) as $platform |
    {
      rootDigest:$root_digest,
      platformDigest:$platform.digest,
      descriptors:([$root_digest, $platform.digest] +
        [$root.manifests[] | .digest] | unique | sort),
      referrerTargets:([$root.manifests[] |
        select(.annotations["vnd.docker.reference.type"]? == "attestation-manifest") |
        .annotations["vnd.docker.reference.digest"] // empty] | unique | sort)
    }
  else error("candidate root manifest shape is invalid")
  end
' "$root_blob") || fail "candidate root manifest is not a closed OCI index"

candidate_digests=$(jq -r '.descriptors[]' <<<"$root_state")
while IFS= read -r digest; do
  digest=${digest%$'\r'}
  [ -n "$digest" ] || continue
  blob="$layout/blobs/sha256/${digest#sha256:}"
  [ -f "$blob" ] && [ ! -L "$blob" ] || fail "candidate descriptor blob is unavailable: $digest"
done <<<"$candidate_digests"

protected=$(jq -cS '
  if type == "object" and
     (.schema == "meet-backend/test-promotion-protected-state/v1") and
     (.protected | type == "object") and
     (.protected.subjectDigests | type == "array" and
       all(.[]; type == "string" and test("^sha256:[0-9a-f]{64}$")))
  then .protected.subjectDigests
  else error("protected state shape is invalid")
  end
' "$protected_state") || fail "protected state is not a closed subject projection"

if jq -e --argjson protected "$protected" '
  any((.descriptors + .referrerTargets)[];
    . as $candidate | any($protected[]; . == $candidate))
' <<<"$root_state" >/dev/null; then
  fail "candidate root, platform, or referrer subject collides with protected history"
fi

jq -cnS --arg root "$root_digest" \
  --arg platform "$(jq -r '.platformDigest' <<<"$root_state")" \
  --argjson descriptors "$(jq '.descriptors' <<<"$root_state")" \
  --argjson referrerTargets "$(jq '.referrerTargets' <<<"$root_state")" \
  '{
    schema:"meet-backend/test-promotion-layout/v1",
    rootDigest:$root,
    platformDigest:$platform,
    descriptors:$descriptors,
    referrerTargets:$referrerTargets,
    protectedSubjectsExcluded:true
  }' >"$tmp" || fail "layout proof construction failed"
chmod 600 "$tmp" 2>/dev/null || true
mv -f -- "$tmp" "$output" || fail "layout proof publication failed"
trap - EXIT HUP INT TERM
