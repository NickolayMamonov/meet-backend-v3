#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 --input PATH --output PATH [--candidate-alias ALIAS]" >&2; exit 2; }
fail() { echo "test-promotion protected-state capture failed: $*" >&2; exit 1; }

input=
output=
candidate_alias=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) [ "$#" -ge 2 ] && [ -z "$input" ] || usage; input=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
    --candidate-alias)
      [ "$#" -ge 2 ] && [ -z "$candidate_alias" ] || usage
      candidate_alias=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$input" ] && [ -n "$output" ] || usage
[ -f "$input" ] && [ ! -L "$input" ] || fail "input is missing or unsafe"
[ ! -L "$output" ] || fail "output is unsafe"
[ -d "$(dirname -- "$output")" ] || fail "output directory is unavailable"
[ -z "$candidate_alias" ] ||
  [[ "$candidate_alias" =~ ^[A-Za-z0-9._-]+$ ]] ||
  fail "candidate alias is malformed"
command -v jq >/dev/null 2>&1 || fail "jq is required"

temporary=$output.tmp.$$
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM

# The complete API/registry capture is an explicit input shim.  This command
# intentionally has no network client, registry client, or mutation command.
if ! jq -cS \
  --arg proofSha db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529 \
  --arg checksum 'db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529 *docs/evidence/MEE2-48-protected-history-v1.json' \
  --arg candidateAlias "$candidate_alias" '
  def sha40: type == "string" and test("^[0-9a-f]{40}$");
  def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  def semver: type == "string" and test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$");
  def keys_are($keys): type == "object" and (keys | sort) == ($keys | sort);
  def member($array;$value): ($array | index($value)) != null;
  def valid_attestation:
    . as $a |
    keys_are(["bundleDigest","predicateType","signerWorkflow","sourceDigest","sourceRepository","subjectDigest","workflowRef"]) and
    ($a.bundleDigest | digest) and
    ($a.predicateType | type == "string" and length > 0) and
    ($a.sourceDigest | sha40) and
    ($a.subjectDigest | digest) and
    ($a.sourceRepository | type == "string" and test("^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
    ($a.workflowRef | type == "string" and startswith("refs/")) and
    ($a.signerWorkflow | type == "string" and
      startswith($a.sourceRepository + "/.github/workflows/") and
      endswith("@" + $a.workflowRef));

  . as $raw |
  (
    type == "object" and
    keys_are(["image","proof","releases","registry","repository","schema","tagRefs"]) and
    .schema == "meet-backend/test-promotion-protected-state-input/v1" and
    (.repository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") and . == ascii_downcase) and
    (.image | type == "string" and test("^ghcr[.]io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") and . == ascii_downcase) and
    (.releases | type == "array" and length > 0) and
    (.releases | (map((keys | sort) == ["assets","draft","id","immutable","prerelease","protected","published_at","tag_name","target_commitish"]) | all)) and
    (.releases | (map(.assets | map((keys | sort) == ["id","name","sha256","size"]) | all) | all)) and
    (.releases | (map(.id | type == "number" and floor == . and . > 0) | all)) and
    (.releases | (map(.tag_name | type == "string" and test("^v(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$")) | all)) and
    (.releases | (map(.target_commitish | sha40) | all)) and
    (.releases | (map(.draft | type == "boolean") | all)) and
    (.releases | (map(.immutable | type == "boolean") | all)) and
    (.releases | (map(.protected | type == "boolean") | all)) and
    (.releases | (map(.prerelease | type == "boolean") | all)) and
    (.releases | (map(.assets |
      map((.id | type == "number" and floor == . and . > 0) and
          (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")) and
          (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.size | type == "number" and floor == . and . >= 0)) | all) | all)) and
    (.releases | (map(.id) | unique | length) == length) and
    (.tagRefs | type == "array" and length > 0) and
    (.tagRefs | (map((keys | sort) == ["objectSha","objectType","peeledCommitSha","state","tag"]) | all)) and
    (.tagRefs | (map(.tag) | unique | length) == length) and
    (.tagRefs | (map(.tag | type == "string" and startswith("v")) | all)) and
    (.tagRefs | (map(
      if .state == "absent" then
        .objectType == null and .objectSha == null and .peeledCommitSha == null
      elif .state == "present" then
        (.objectType == "commit" or .objectType == "tag") and
        (.objectSha | sha40) and (.peeledCommitSha | sha40)
      else false end) | all)) and
    (.registry | keys_are(["attestations","manifests","subjects","versions"])) and
    (.registry.versions | type == "array" and
      (map((keys | sort) == ["digest","id","tags"]) | all) and
      (map(.digest | digest) | all) and
      ((map(.id) | unique | length) == length) and
      ((map(.digest) | unique | length) == length)) and
    (.registry.versions | (map(.tags | type == "array") | all)) and
    (.registry.versions | (map(.tags | all(.[]?; type == "string" and length > 0)) | all)) and
    (.registry.subjects | type == "array" and
      (map((keys | sort) == ["aliases","digest","kind","platformDigest","releaseId","rootDigest"]) | all) and
      (map(.digest | digest) | all) and
      ((map(.digest) | unique | length) == length) and
      (map(.kind == "root" or .kind == "platform") | all) and
      (map(.releaseId | type == "number" and floor == . and . > 0) | all) and
      (map(.aliases | type == "array" and all(.[]?; type == "string" and length > 0)) | all)) and
    (.registry.manifests | type == "array" and
      (map((keys | sort) == ["artifactType","children","digest","mediaType","predicateTypes","size","subjectDigest"]) | all) and
      (map(.digest | digest) | all) and
      ((map(.digest) | unique | length) == length) and
      (map(.children | type == "array") | all) and
      (map(.mediaType | type == "string" and length > 0) | all) and
      (map(.size | type == "number" and floor == . and . >= 0) | all) and
      (map(.predicateTypes | type == "array" and all(.[]?; type == "string" and length > 0)) | all)) and
    (.registry.attestations | type == "array" and
      (map((keys | sort) == ["bundleDigest","predicateType","signerWorkflow","sourceDigest","sourceRepository","subjectDigest","workflowRef"]) | all) and
      (map(valid_attestation) | all) and
      ((map(.bundleDigest) | unique | length) == length)) and
    (.registry.attestations | (map(.bundleDigest | digest) | all)) and
    (.proof | keys_are(["checksum","path","sha256"]) and
      .path == "docs/evidence/MEE2-48-protected-history-v1.json" and
      .sha256 == $proofSha and .checksum == $checksum)
  ) as $valid |
  if $valid then $raw else error("input shape or proof identity is invalid") end |
  ([.releases[] | select(.id == 371012814)] |
    if length == 1 then .[0] else error("public release identity is ambiguous") end) as $public |
  if ($public.tag_name == "v1.2.0" and
      ($public.draft | not) and ($public.prerelease | not) and
      $public.immutable and $public.published_at != null)
  then .
  else error("public v1.2.0 release identity is invalid")
  end |
  ([.releases[] | select(.protected or .id == 371012814)] | map(.id) | unique) as $protectedIds |
  ([.releases[] | select(member($protectedIds;.id))]) as $protectedReleases |
  (if ([
    $protectedReleases[] |
    . as $release |
    ([$raw.tagRefs[] | select(.tag == $release.tag_name)] |
      if length == 1 then
        .[0].state == "present" and .[0].peeledCommitSha == $release.target_commitish
      else false end)
  ] | all) then . else error("protected tag ref identity is invalid") end) |
  ([ $protectedIds[]? as $id |
     ([.registry.subjects[] | select(.kind == "root" and .releaseId == $id)] |
       if length == 1 then .[0] else error("protected root subject is ambiguous") end)
   ]) as $roots |
  ([ $roots[]? | .platformDigest ] | map(select(digest))) as $platformDigests |
  ([ $platformDigests[]? as $pd |
     ([.registry.subjects[] | select(.kind == "platform" and .digest == $pd)] |
       if length == 1 then .[0] else error("protected platform subject is ambiguous") end)
   ]) as $platforms |
  (if ([
    $platforms[] |
    . as $platform |
    any($roots[]?; .digest == $platform.rootDigest and .platformDigest == $platform.digest)
  ] | all) then . else error("protected platform subject is not bound to its root") end) |
  ([ $protectedReleases[]? | .tag_name, (.tag_name | sub("^v"; "")), ("sha-" + .target_commitish) ] | unique) as $identityAliases |
  (if ([
    $roots[] |
    . as $root |
    .aliases[]? |
    . as $alias |
    any($raw.registry.versions[]?; .digest == $root.digest and
      any(.tags[]?; . == $alias))
  ] | all) then . else error("protected subject aliases disagree with registry tags") end) |
  ([ $roots[]?.digest, $platforms[]?.digest ] | unique) as $baseDigests |
  ([.registry.versions[] | select(
    member($baseDigests;.digest) or
    any(.tags[]?; member($identityAliases;.)) or
    ($candidateAlias != "" and member($baseDigests;.digest) and
      any(.tags[]?; . == $candidateAlias))
  )]) as $touchedVersions |
  ([ $touchedVersions[]?.digest ] | unique) as $touchedDigests |
  ([ $baseDigests[]?, $touchedDigests[]? ] | unique) as $seeds |
  (.registry.manifests) as $manifestTable |
  (reduce range(0; 32) as $round ($seeds;
    . as $known |
    ([ $manifestTable[] | select(member($known;.digest) or (.subjectDigest != null and member($known;.subjectDigest))) |
       (.digest, .children[]?) ] | unique) as $next |
    ($known + $next | unique)
  )) as $closure |
  (if ([
    $closure[] |
    . as $closedDigest |
    any($manifestTable[]?; .digest == $closedDigest)
  ] | all) then . else error("referrer closure contains an unbound digest") end) |
  ([.registry.versions[] | select(
    member($closure;.digest) or
    any(.tags[]?; member($identityAliases;.)) or
    ($candidateAlias != "" and member($closure;.digest) and
      any(.tags[]?; . == $candidateAlias))
  )]) as $protectedVersions |
  ([ $protectedVersions[]?.tags[]? ] | unique) as $allAliases |
  ([ $identityAliases[]?, $allAliases[]? ] | unique | sort) as $aliases |
  ([ $aliases[]? as $alias |
     {alias:$alias,digests:([.registry.versions[] | select(any(.tags[]?; . == $alias)) | .digest] | unique | sort)}
   ] | sort_by(.alias)) as $aliasBindings |
  {
    schema:"meet-backend/test-promotion-protected-state/v1",
    repository:$raw.repository,
    image:$raw.image,
    publicRelease:{id:$public.id,tag:$public.tag_name,version:($public.tag_name | sub("^v"; "")),sourceSha:$public.target_commitish},
    releases:([$raw.releases[] | {id,tag:.tag_name,version:(.tag_name | sub("^v"; "")),sourceSha:.target_commitish,draft,immutable,protected,prerelease,publishedAt:.published_at}] | sort_by(.id)),
    tagRefs:([$raw.tagRefs[] | {tag,state,objectType,objectSha,peeledCommitSha}] | sort_by(.tag)),
    assets:([$raw.releases[] as $release | $release.assets[] | {releaseId:$release.id,id,name,size,sha256}] | sort_by(.releaseId,.name,.id)),
    protected:{
      releaseIds:$protectedIds,
      aliases:$aliasBindings,
      rootDigests:([ $roots[].digest ] | unique | sort),
      platformDigests:($platformDigests | unique | sort),
      subjectDigests:($closure | unique | sort),
      versions:([$protectedVersions[] | {id,digest,tags:(.tags | unique | sort)}] | sort_by(.digest,.id)),
      subjects:([
        $raw.registry.subjects[] | select(member($closure;.digest)) |
        {digest,kind,releaseId,rootDigest,platformDigest,aliases:(.aliases | unique | sort)}
      ] | sort_by(.digest)),
      manifests:([
        $raw.registry.manifests[] | select(member($closure;.digest)) |
        {digest,mediaType,size,subjectDigest,artifactType,predicateTypes:(.predicateTypes | unique | sort),children:(.children | unique | sort)}
      ] | sort_by(.digest)),
      referrerClosure:([
        $raw.registry.manifests[] |
        select(member($closure;.digest) and (.subjectDigest != null or (.children | length) > 0)) |
        {digest,mediaType,size,subjectDigest,artifactType,predicateTypes:(.predicateTypes | unique | sort),children:(.children | unique | sort)}
      ] | sort_by(.digest)),
      githubAttestations:([
        $raw.registry.attestations[] | select(member($closure;.subjectDigest)) |
        {subjectDigest,predicateType,sourceRepository,sourceDigest,workflowRef,signerWorkflow,bundleDigest}
      ] | sort_by(.subjectDigest,.predicateType,.bundleDigest))
    },
    proof:{path:$raw.proof.path,sha256:$raw.proof.sha256,checksum:$raw.proof.checksum}
  }
' "$input" >"$temporary"; then
  fail "input is malformed, ambiguous, or outside the protected contract"
fi
[ -s "$temporary" ] || fail "canonical projection is empty"
[ "$(wc -l <"$temporary" | tr -d " ")" -eq 1 ] || fail "canonical projection is not compact JSON"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "output publication failed"
trap - EXIT HUP INT TERM
