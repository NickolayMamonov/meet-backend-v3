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
      immutable:(if (.immutable | type) == "boolean" then .immutable else error("release immutable field is missing or not boolean") end),
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

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "registry descriptor digest is malformed"
}

validate_descriptor() {
  local descriptor=$1
  jq -e '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . > 0)
  ' <<<"$descriptor" >/dev/null ||
    fail "registry descriptor is malformed"
}

read_raw_manifest() {
  local digest=$1 destination=$2 expected_media=${3:-} expected_size=${4:-}
  local actual_digest actual_media actual_size
  validate_digest "$digest"
  docker buildx imagetools inspect --raw "$image@$digest" >"$destination" 2>/dev/null ||
    fail "registry manifest read failed for $digest"
  jq -e 'type == "object" and .schemaVersion == 2' "$destination" >/dev/null ||
    fail "registry manifest is malformed for $digest"
  actual_digest="sha256:$(sha256sum "$destination" | awk '{print $1}')"
  [ "$actual_digest" = "$digest" ] ||
    fail "registry manifest bytes do not match $digest"
  actual_media=$(jq -r '.mediaType // empty' "$destination")
  [ -n "$actual_media" ] || fail "registry manifest has no media type for $digest"
  actual_size=$(wc -c <"$destination" | tr -d ' ')
  [ "$actual_size" -gt 0 ] || fail "registry manifest is empty for $digest"
  [ -z "$expected_media" ] || [ "$actual_media" = "$expected_media" ] ||
    fail "registry descriptor media type disagrees with manifest for $digest"
  [ -z "$expected_size" ] || [ "$actual_size" -eq "$expected_size" ] ||
    fail "registry descriptor size disagrees with manifest for $digest"
}

collect_verified_attestations() {
  local digest=$1 source_digest=$2 record bundle_sha
  local verified_file="$tmp/github-${digest#sha256:}.json"
  if [ ! -f "$verified_file" ]; then
    gh attestation verify "oci://$image@$digest" \
      --repo "$repository" --source-digest "$source_digest" --format json \
      >"$verified_file" ||
      fail "GitHub attestation verification failed for $digest"
  fi
  jq -e --arg subject "${digest#sha256:}" \
    --arg repository "https://github.com/$repository" \
    --arg source "$source_digest" '
    type == "array" and length > 0 and
    all(.[];
      (.attestation.bundle | type == "object") and
      (.verificationResult | type == "object") and
      (.verificationResult.statement.predicateType |
        type == "string" and length > 0) and
      ([.verificationResult.statement.subject[]? |
        select(.digest.sha256? == $subject)] | length) == 1 and
      (.verificationResult.signature.certificate as $certificate |
        $certificate.sourceRepositoryURI == $repository and
        $certificate.sourceRepositoryDigest == $source and
        ($certificate.sourceRepositoryRef |
          type == "string" and startswith("refs/")) and
        ($certificate.buildSignerURI |
          type == "string" and
          startswith($repository + "/.github/workflows/") and
          endswith("@" + $certificate.sourceRepositoryRef)) and
        $certificate.subjectAlternativeName == $certificate.buildSignerURI)
    )
  ' "$verified_file" >/dev/null ||
    fail "verified GitHub attestation evidence is malformed for $digest"
  while IFS= read -r record; do
    bundle_sha=$(
      jq -cS '.attestation.bundle' <<<"$record" |
        sha256sum | awk '{print $1}'
    ) || fail "verified GitHub attestation bundle hashing failed for $digest"
    jq -cS --arg subjectDigest "$digest" \
      --arg bundleDigest "sha256:$bundle_sha" '
      .verificationResult as $result |
      $result.signature.certificate as $certificate |
      {
        subjectDigest:$subjectDigest,
        predicateType:$result.statement.predicateType,
        sourceRepository:$certificate.sourceRepositoryURI,
        sourceDigest:$certificate.sourceRepositoryDigest,
        workflowRef:$certificate.sourceRepositoryRef,
        signerWorkflow:$certificate.buildSignerURI,
        bundleDigest:$bundleDigest
      }
    ' <<<"$record" >>"$tmp/attestations.jsonl" ||
      fail "verified GitHub attestation normalization failed for $digest"
  done < <(jq -c '.[]' "$verified_file")
}

while IFS=$'\t' read -r version_id digest tags_json; do
  raw="$tmp/raw-${digest#sha256:}.json"
  read_raw_manifest "$digest" "$raw"
  media_type=$(jq -r '.mediaType // empty' "$raw")
  manifest_size=$(wc -c <"$raw" | tr -d ' ')
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
    jq -e '
      (.manifests | type == "array" and length > 0) and
      all(.manifests[]; type == "object")
    ' "$raw" >/dev/null || fail "registry image index is malformed for $digest"
    while IFS= read -r descriptor; do validate_descriptor "$descriptor"; done < <(
      jq -c '.manifests[]' "$raw"
    )
    platform_descriptor=$(jq -c '
      [.manifests[] |
        select(
          .platform.os == "linux" and
          .platform.architecture == "amd64" and
          ((.platform.variant? // "") == "")
        )] |
      if length == 1 then .[0] else empty end
    ' "$raw")
    platform_digest=$(jq -r '.digest // empty' <<<"$platform_descriptor")
    if [ "$release_id" -gt 0 ]; then
      [ -n "$platform_digest" ] ||
        fail "release image index has no unique linux/amd64 subject"
    fi
    if [ "$release_id" -gt 0 ]; then
      jq -cnS --arg digest "$digest" --argjson releaseId "$release_id" \
        --arg platformDigest "$platform_digest" --argjson aliases "$tags_json" \
        '{digest:$digest,kind:"root",releaseId:$releaseId,rootDigest:null,
          platformDigest:$platformDigest,aliases:$aliases}' >>"$tmp/subjects.jsonl"
      release_source=$(jq -r --argjson id "$release_id" \
        '.[] | select(.id == $id) | .target_commitish' \
        "$tmp/releases-normalized.json")
      collect_verified_attestations "$digest" "$release_source"
    fi
    jq -cnS --arg digest "$digest" --arg mediaType "$media_type" \
      --argjson size "$manifest_size" \
      --argjson children "$(jq '[.manifests[] | .digest]' "$raw")" \
      '{digest:$digest,mediaType:$mediaType,size:$size,subjectDigest:null,
        artifactType:null,predicateTypes:[],children:$children}' >>"$tmp/manifests.jsonl"
    while IFS= read -r descriptor; do
      child_digest=$(jq -r '.digest' <<<"$descriptor")
      child_media=$(jq -r '.mediaType' <<<"$descriptor")
      child_size=$(jq -r '.size' <<<"$descriptor")
      child_raw="$tmp/raw-${child_digest#sha256:}.json"
      read_raw_manifest "$child_digest" "$child_raw" "$child_media" "$child_size"
      if [ "$release_id" -gt 0 ] &&
         jq -e '
           .platform.os == "linux" and
           .platform.architecture == "amd64" and
           ((.platform.variant? // "") == "")
         ' \
           <<<"$descriptor" >/dev/null; then
        jq -cnS --arg digest "$child_digest" --arg mediaType "$child_media" \
          --arg rootDigest "$digest" --argjson releaseId "$release_id" \
          '{digest:$digest,kind:"platform",releaseId:$releaseId,rootDigest:$rootDigest,
            platformDigest:null,aliases:[]}' >>"$tmp/subjects.jsonl"
      fi
      if jq -e \
        '.annotations["vnd.docker.reference.type"] == "attestation-manifest"' \
        <<<"$descriptor" >/dev/null; then
        descriptor_subject=$(jq -r \
          '.annotations["vnd.docker.reference.digest"] // empty' <<<"$descriptor")
        actual_subject=$(jq -r '.subject.digest // empty' "$child_raw")
        artifact_type=$(jq -r '.artifactType // empty' "$child_raw")
        predicate_types=$(jq -c '
          [.layers[]?.annotations["in-toto.io/predicate-type"]?] |
          map(select(type == "string" and length > 0)) | unique | sort
        ' "$child_raw")
        validate_digest "$descriptor_subject"
        [ -z "$actual_subject" ] ||
          [ "$descriptor_subject" = "$actual_subject" ] ||
          fail "attestation subject binding disagrees for $child_digest"
        [ "$descriptor_subject" = "$digest" ] ||
          [ "$descriptor_subject" = "$platform_digest" ] ||
          fail "attestation is bound to a foreign subject for $child_digest"
        [ -n "$artifact_type" ] ||
          fail "attestation artifact type is missing for $child_digest"
        [ "$(jq length <<<"$predicate_types")" -gt 0 ] ||
          fail "attestation predicate binding is missing for $child_digest"
        jq -cnS --arg digest "$child_digest" --arg mediaType "$child_media" \
          --argjson size "$child_size" \
          --arg subjectDigest "$descriptor_subject" \
          --arg artifactType "$artifact_type" \
          --argjson predicateTypes "$predicate_types" \
          '{digest:$digest,mediaType:$mediaType,size:$size,
            subjectDigest:$subjectDigest,artifactType:$artifactType,
            predicateTypes:$predicateTypes,children:[]}' >>"$tmp/manifests.jsonl"
      else
        jq -cnS --arg digest "$child_digest" --arg mediaType "$child_media" \
          --argjson size "$child_size" \
          '{digest:$digest,mediaType:$mediaType,size:$size,subjectDigest:null,
            artifactType:null,predicateTypes:[],children:[]}' >>"$tmp/manifests.jsonl"
      fi
    done < <(jq -c '.manifests[]' "$raw")
  else
    subject_digest=$(jq -r '.subject.digest // empty' "$raw")
    artifact_type=$(jq -r '.artifactType // empty' "$raw")
    predicate_types=$(jq -c '
      [.layers[]?.annotations["in-toto.io/predicate-type"]?] |
      map(select(type == "string" and length > 0)) | unique | sort
    ' "$raw")
    if [ -n "$subject_digest" ] || [ -n "$artifact_type" ] ||
       [ "$(jq length <<<"$predicate_types")" -gt 0 ]; then
      [ -n "$artifact_type" ] ||
        fail "artifact manifest type is missing for $digest"
      [ "$(jq length <<<"$predicate_types")" -gt 0 ] ||
        fail "artifact manifest predicate binding is missing for $digest"
      if [ -z "$subject_digest" ]; then
        continue
      fi
      validate_digest "$subject_digest"
      jq -cnS --arg digest "$digest" --arg mediaType "$media_type" \
        --argjson size "$manifest_size" --arg subjectDigest "$subject_digest" \
        --arg artifactType "$artifact_type" \
        --argjson predicateTypes "$predicate_types" \
        '{digest:$digest,mediaType:$mediaType,size:$size,
          subjectDigest:$subjectDigest,artifactType:$artifactType,
          predicateTypes:$predicateTypes,children:[]}' >>"$tmp/manifests.jsonl"
    else
      jq -cnS --arg digest "$digest" --arg mediaType "$media_type" \
        --argjson size "$manifest_size" \
        '{digest:$digest,mediaType:$mediaType,size:$size,subjectDigest:null,
          artifactType:null,predicateTypes:[],children:[]}' >>"$tmp/manifests.jsonl"
    fi
  fi
done < <(jq -r '.[] | [.id,.digest,(.tags | @json)] | @tsv' "$tmp/versions.json")

jq -sS '
  group_by(.digest) |
  map(if (unique | length) == 1 then .[0]
      else error("conflicting registry subject bindings") end) |
  sort_by(.digest)
' "$tmp/subjects.jsonl" >"$tmp/subjects.json" ||
  fail "registry subject bindings conflict"
jq -sS '
  group_by(.digest) |
  map(if (unique | length) == 1 then .[0]
      else error("conflicting registry manifest descriptors") end) |
  sort_by(.digest)
' "$tmp/manifests.jsonl" >"$tmp/manifests.json" ||
  fail "registry manifest descriptors conflict"
jq -e --slurpfile manifests "$tmp/manifests.json" '
  [.[] as $version |
    any($manifests[0][]; .digest == $version.digest)] |
  all
' "$tmp/versions.json" >/dev/null ||
  fail "package inventory contains an unbound manifest"
jq -sS '
  group_by(.bundleDigest) |
  map(if (unique | length) == 1 then .[0]
      else error("conflicting verified GitHub attestation records") end) |
  sort_by(.subjectDigest,.predicateType,.bundleDigest)
' "$tmp/attestations.jsonl" >"$tmp/attestations.json" ||
  fail "verified GitHub attestation records conflict"

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
