#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --repository OWNER/REPO --image ghcr.io/OWNER/IMAGE --output PATH [--candidate-alias ALIAS]" >&2
  exit 2
}

fail() { echo "test-promotion protected-state collection failed: $*" >&2; exit 1; }

repository=
image=
output=
candidate_alias=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] && [ -z "$repository" ] || usage; repository=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] && [ -z "$image" ] || usage; image=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
    --candidate-alias) [ "$#" -ge 2 ] && [ -z "$candidate_alias" ] || usage; candidate_alias=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$image" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[ -n "$output" ] || usage
[ -z "$candidate_alias" ] || [[ "$candidate_alias" =~ ^[A-Za-z0-9._-]+$ ]] || usage
for command_name in gh jq docker sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
done
: "${GH_TOKEN:?GH_TOKEN is required}"

output_dir=$(dirname -- "$output")
[ -d "$output_dir" ] && [ ! -L "$output_dir" ] || fail "output directory is unavailable"
[ ! -L "$output" ] || fail "output path is unsafe"

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM

gh api --paginate --slurp "repos/$repository/releases?per_page=100" \
  >"$tmp/releases.json" || fail "release inventory read failed"
gh api --paginate --slurp \
  "users/${repository%%/*}/packages/container/${repository##*/}/versions?per_page=100" \
  >"$tmp/packages.json" || fail "package inventory read failed"

jq -e 'type == "array" and all(.[]; type == "array")' "$tmp/releases.json" >/dev/null ||
  fail "release inventory response is malformed"
jq -e 'type == "array" and all(.[]; type == "array")' "$tmp/packages.json" >/dev/null ||
  fail "package inventory response is malformed"

jq -cS --arg repository "$repository" '
  [add // [] | .[] |
    {
      id,
      tag_name,
      target_commitish:(.target_commitish // ""),
      draft:(.draft // false),
      immutable:(.immutable // true),
      protected:(.protected // ((.draft // false) | not) and ((.prerelease // false) | not)),
      prerelease:(.prerelease // false),
      published_at,
      assets:(
        [.assets[] |
          {
            id,
            name,
            size,
            sha256:(.digest // "" | sub("^sha256:";""))
          }]
      )
    }
  ]
' "$tmp/releases.json" >"$tmp/releases-normalized.json" ||
  fail "release inventory normalization failed"

jq -e '
  all(.[];
    (.id | type == "number") and
    (.tag_name | type == "string" and test("^v[0-9]+[.][0-9]+[.][0-9]+$")) and
    (.target_commitish | type == "string" and test("^[0-9a-f]{40}$")) and
    all(.assets[]; .sha256 | test("^[0-9a-f]{64}$"))
  )
' "$tmp/releases-normalized.json" >/dev/null ||
  fail "release inventory contains an unsupported or undigested asset"

release_tags=$(jq -r '.[].tag_name' "$tmp/releases-normalized.json")
tag_refs=$(
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    target=$(jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .target_commitish' \
      "$tmp/releases-normalized.json")
    ref_json=$(gh api "repos/$repository/git/ref/tags/$tag" 2>/dev/null) ||
      fail "tag ref read failed for $tag"
    object_type=$(jq -r '.object.type // empty' <<<"$ref_json")
    object_sha=$(jq -r '.object.sha // empty' <<<"$ref_json")
    peeled_sha=$object_sha
    if [ "$object_type" = tag ]; then
      peeled_sha=$(gh api "repos/$repository/git/tags/$object_sha" |
        jq -r '.object.sha // empty')
    fi
    [ "$object_type" = commit ] || [ "$object_type" = tag ] ||
      fail "tag ref type is unsupported for $tag"
    [ "$object_sha" = "$target" ] || [ "$peeled_sha" = "$target" ] ||
      fail "tag ref does not match release target for $tag"
    jq -cnS --arg tag "$tag" --arg objectType "$object_type" \
      --arg objectSha "$object_sha" --arg peeledCommitSha "$peeled_sha" \
      '{tag:$tag,state:"present",objectType:$objectType,objectSha:$objectSha,peeledCommitSha:$peeledCommitSha}'
  done <<<"$release_tags"
)
printf '%s\n' "$tag_refs" | jq -sS . >"$tmp/tag-refs.json"

jq -cS '
  [add // [] | .[] |
    {
      id,
      digest:.name,
      tags:(.metadata.container.tags // [])
    }]
' "$tmp/packages.json" >"$tmp/versions.json" ||
  fail "package inventory normalization failed"
jq -e 'all(.[]; .digest | test("^sha256:[0-9a-f]{64}$"))' "$tmp/versions.json" >/dev/null ||
  fail "package inventory contains a malformed digest"

: >"$tmp/subjects.jsonl"
: >"$tmp/manifests.jsonl"
: >"$tmp/attestations.jsonl"
: >"$tmp/versions.jsonl"
while IFS=$'\t' read -r version_id digest tags_json; do
  raw="$tmp/raw-${digest#sha256:}.json"
  docker buildx imagetools inspect --raw "$image@$digest" >"$raw" 2>/dev/null ||
    fail "registry manifest read failed for $digest"
  media_type=$(jq -r '.mediaType // empty' "$raw")
  [ -n "$media_type" ] || fail "registry manifest has no media type"
  release_id=$(jq -r --argjson tags "$tags_json" '
    [.[] as $release |
      select(any($tags[]?; . == $release.tag_name or
        . == ($release.tag_name | sub("^v";"")) or
        . == ("sha-" + $release.target_commitish))) |
      $release.id] | first // 0
  ' "$tmp/releases-normalized.json")
  jq -cnS --argjson id "$version_id" --arg digest "$digest" \
    --argjson tags "$tags_json" '{id:$id,digest:$digest,tags:$tags}' >>"$tmp/versions.jsonl"
  if [ "$media_type" = application/vnd.oci.image.index.v1+json ]; then
    platform_digest=$(jq -r '
      [.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64") |
        .digest] | if length == 1 then .[0] else empty end
    ' "$raw")
    [ -n "$platform_digest" ] || fail "image index has no unique linux/amd64 subject"
    if [ "$release_id" -gt 0 ]; then
      jq -cnS --arg digest "$digest" --argjson releaseId "$release_id" \
        --arg platformDigest "$platform_digest" --argjson aliases "$tags_json" \
        '{digest:$digest,kind:"root",releaseId:$releaseId,rootDigest:null,
          platformDigest:$platformDigest,aliases:$aliases}' >>"$tmp/subjects.jsonl"
    fi
    jq -cnS --arg digest "$digest" --arg mediaType "$media_type" \
      --argjson children "$(jq '[.manifests[] | .digest]' "$raw")" \
      '{digest:$digest,mediaType:$mediaType,size:0,subjectDigest:null,
        artifactType:null,predicateTypes:[],children:$children}' >>"$tmp/manifests.jsonl"
    while IFS=$'\t' read -r child_digest child_media; do
      if [ "$release_id" -gt 0 ]; then
        jq -cnS --arg digest "$child_digest" --arg mediaType "$child_media" \
          --arg rootDigest "$digest" --argjson releaseId "$release_id" \
          '{digest:$digest,kind:"platform",releaseId:$releaseId,rootDigest:$rootDigest,
            platformDigest:null,aliases:[]}' >>"$tmp/subjects.jsonl"
      fi
      jq -cnS --arg digest "$child_digest" --arg mediaType "$child_media" \
        '{digest:$digest,mediaType:$mediaType,size:0,subjectDigest:null,
          artifactType:null,predicateTypes:[],children:[]}' >>"$tmp/manifests.jsonl"
    done < <(jq -r '.manifests[] | select(.platform != null) | [.digest,.mediaType] | @tsv' "$raw")
  else
    jq -cnS --arg digest "$digest" --arg mediaType "$media_type" \
      '{digest:$digest,mediaType:$mediaType,size:0,subjectDigest:null,
        artifactType:null,predicateTypes:[],children:[]}' >>"$tmp/manifests.jsonl"
  fi
  while IFS=$'\t' read -r child_digest subject artifact_type predicate; do
    [ -n "$child_digest" ] || continue
    jq -cnS --arg digest "$child_digest" --arg subject "$subject" \
      --arg artifactType "$artifact_type" --arg predicate "$predicate" \
      '{digest:$digest,mediaType:"application/vnd.oci.image.manifest.v1+json",size:0,
        subjectDigest:$subject,artifactType:$artifactType,
        predicateTypes:[$predicate],children:[]}' >>"$tmp/manifests.jsonl"
  done < <(jq -r '
    .manifests[]? |
    select(.annotations["vnd.docker.reference.type"] == "attestation-manifest") |
    [.digest,
      (.annotations["vnd.docker.reference.digest"] // ""),
      (.artifactType // "application/vnd.in-toto+json"),
      (.annotations["in-toto.io/predicate-type"] // "")]
    | @tsv
  ' "$raw")
done < <(jq -r '.[] | [.id,.digest,(.tags | @json)] | @tsv' "$tmp/versions.json")

jq -sS 'unique_by(.digest) | sort_by(.digest)' "$tmp/subjects.jsonl" >"$tmp/subjects.json"
jq -sS 'unique_by(.digest) | sort_by(.digest)' "$tmp/manifests.jsonl" >"$tmp/manifests.json"
jq -sS 'unique_by(.digest) | sort_by(.subjectDigest,.predicateType,.bundleDigest)' \
  "$tmp/attestations.jsonl" >"$tmp/attestations.json"

temporary=$output.tmp.$$
trap 'rm -f -- "$temporary"; rm -r -- "$tmp"' EXIT HUP INT TERM
jq -cnS \
  --arg repository "$repository" --arg image "$image" \
  --slurpfile releases "$tmp/releases-normalized.json" \
  --slurpfile tagRefs "$tmp/tag-refs.json" \
  --slurpfile versions "$tmp/versions.json" \
  --slurpfile subjects "$tmp/subjects.json" \
  --slurpfile manifests "$tmp/manifests.json" \
  --slurpfile attestations "$tmp/attestations.json" \
  --arg candidateAlias "$candidate_alias" '
  {
    schema:"meet-backend/test-promotion-protected-state-input/v1",
    repository:$repository,image:$image,
    releases:($releases[0] // []),
    tagRefs:($tagRefs[0] // []),
    registry:{
      versions:($versions[0] // []),
      subjects:($subjects[0] // []),
      manifests:($manifests[0] // []),
      attestations:($attestations[0] // [])
    },
    proof:{
      path:"docs/evidence/MEE2-48-protected-history-v1.json",
      sha256:"db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529",
      checksum:"db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529 *docs/evidence/MEE2-48-protected-history-v1.json"
    }
  }
' >"$temporary" || fail "protected-state input construction failed"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "protected-state input publication failed"
rm -r -- "$tmp"
trap - EXIT HUP INT TERM
