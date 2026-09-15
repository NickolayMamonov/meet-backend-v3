#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

historical_authority_rows() {
  jq -cnS '[
    {id:367640510,tag:"v1.0.1",version:"1.0.1",source:"d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc",signer:"4bff2902511e8e739d7604bf120b121429e60aeb",packageId:1115681835,root:"sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6",platform:"sha256:2e2f41478f341da8df7e573c48c59ee1734ee7d29e9a7be614f3660adac64554",draft:false,prerelease:false,immutable:false,invocation:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/31368625251/attempts/1",subject:"ghcr.io/nickolaymamonov/meet-backend-v3",storage:"oci-registry-bundle",bundle:"sha256:8b1037a95682b343c47b7db24e8576a6a97d8b59de3ae80e7fe76341a6168f2a"},
    {id:368531227,tag:"v1.1.0",version:"1.1.0",source:"36ffd11ea4d35147f1df9c1cafa6a330300c1339",signer:"8598a31e60d0bae784bebf43404f3b1e91d603e1",packageId:1123238824,root:"sha256:c156a8a1436b008eea2980711b233b6f800cf60a36cdbe08faf480a2c97e6570",platform:"sha256:a04f84d5325cbe67b536b3000353da765ae4412ab0b0b9acabce1ecbba61c3ee",draft:true,prerelease:false,immutable:false,invocation:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/31551286770/attempts/1",subject:"ghcr.io/nickolaymamonov/meet-backend-v3",storage:"oci-registry-bundle",bundle:"sha256:9e41130252d1edf5ff4a82e9c6b24b4f50b67b4c05430be26e8f474a354739c8"},
    {id:371012814,tag:"v1.2.0",version:"1.2.0",source:"9b6d2b06c0336ab8d153564dcf6328e81c4d7b36",signer:"9af0723444f918594101999a4338b418607cbd01",packageId:1135861098,root:"sha256:e92bf70ddd26cf723ec48ae79d1e3bea77b6a4c0f2100e1573f8fb458c6cedda",platform:"sha256:3d2741adeb501f103b1fdc2b79c9e2cdb30f30ab257805d2fe67e57bc6d222b6",draft:false,prerelease:false,immutable:true,invocation:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/31880582935/attempts/1",subject:"image-index.json",storage:"github-api-workflow-artifact",bundle:"sha256:6fc87b8c7167fdc24de74853264ed3dde855896913fd609f41680267c265f414"},
    {id:377201468,tag:"v1.3.0",version:"1.3.0",source:"a7abfe04f6852f479291a4710ebdee23e9ae8a34",signer:"79263bfed6427dc1a45900e338805c52dbd5f59d",packageId:1178492365,root:"sha256:88b697872331ed2786f2d9009c769a87c32470086702faacf9874576fe094e9e",platform:"sha256:b98ef109b9f0aeed909a15d44908087093b9177313813040ddbeb2d415c51961",draft:false,prerelease:false,immutable:true,invocation:"https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/33075760603/attempts/1",subject:"image-index.json",storage:"github-api-workflow-artifact",bundle:"sha256:7675da813f32cba607a12305dbeeaef475a85b204d83709642316ddb14887084"}
  ]'
}
select_historical_authority() { local p=$1; historical_authority_rows | jq -cS --argjson p "$p" 'def a($p;$r):($p.package.tags|type=="array" and length==3 and length==(unique|length) and sort==(["sha-"+$r.source,$r.version,$r.tag]|sort)); def d($p;$r):$p.release.id==$r.id or $p.release.tag==$r.tag or $p.release.version==$r.version or $p.release.source==$r.source or $p.package.id==$r.packageId or $p.rootDigest==$r.root or $p.platform.digest==$r.platform or any($p.package.tags[]?; .==("sha-"+$r.source) or .==$r.version or .==$r.tag); [.[]|select(d($p;.))] as $m | if ($m|length)==0 then {status:"unrelated"} elif ($m|length)!=1 then error("ambiguous historical authority") else $m[0] as $r | if $p.repository=="NickolayMamonov/meet-backend-v3" and $p.image=="ghcr.io/nickolaymamonov/meet-backend-v3" and $p.release=={id:$r.id,tag:$r.tag,version:$r.version,source:$r.source,draft:$r.draft,prerelease:$r.prerelease,immutable:$r.immutable} and $p.package.id==$r.packageId and $p.package.digest==$r.root and a($p;$r) and $p.rootDigest==$r.root and $p.platform.digest==$r.platform and $p.platform.mediaType=="application/vnd.oci.image.manifest.v1+json" and $p.platform.size==1815 and $p.platform.platform=={architecture:"amd64",os:"linux"} then {status:"historical",row:$r} else error("historical product tuple mismatch") end end'; }
validate_historical_attestation() { local response=$1 selection=$2 subject=$3 row obs hash record; row=$(jq -c '.row' <<<"$selection") || return 1; record=$(jq -c '.[0]' <<<"$response") || return 1; obs=$(jq -cS --arg subject "${subject#sha256:}" 'if type!="array" or length!=1 then error("result cardinality") else .[0] end | .attestation.bundle as $b | .verificationResult as $r | $r.signature.certificate as $c | $r.statement.subject as $s | if ($b|type)!="object" or ($s|type)!="array" or ($s|length)!=1 or $s[0].digest.sha256!=$subject then error("observed evidence malformed") else {bundle:$b,predicateType:$r.statement.predicateType,sourceRepository:$c.sourceRepositoryURI,sourceDigest:$c.sourceRepositoryDigest,workflowRef:$c.sourceRepositoryRef,signerWorkflow:$c.buildSignerURI,signerDigest:$c.buildSignerDigest,certificateIdentity:$c.subjectAlternativeName,issuer:$c.issuer,invocationURI:$c.runInvocationURI,subjectName:$s[0].name} end' <<<"$response") || return 1; hash=$(jq -cS '.attestation.bundle' <<<"$record" | sha256sum|awk '{print $1}') || return 1; jq -e -n --argjson a "$obs" --argjson r "$row" '$a.sourceRepository=="https://github.com/NickolayMamonov/meet-backend-v3" and $a.sourceDigest==$r.signer and $a.workflowRef=="refs/heads/dev" and $a.signerWorkflow=="https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" and $a.signerDigest==$r.signer and $a.certificateIdentity=="https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" and $a.issuer=="https://token.actions.githubusercontent.com" and $a.invocationURI==$r.invocation and $a.predicateType=="https://slsa.dev/provenance/v1" and $a.subjectName==$r.subject' >/dev/null || return 1; [ "sha256:$hash" = "$(jq -r '.row.bundle' <<<"$selection")" ] || return 1; jq -cnS --arg subject "$subject" --arg source "$(jq -r '.row.signer' <<<"$selection")" --arg bundle "sha256:$hash" --arg signerWorkflow "$(jq -r '.signerWorkflow' <<<"$obs")" '{subjectDigest:$subject,predicateType:"https://slsa.dev/provenance/v1",sourceRepository:"https://github.com/NickolayMamonov/meet-backend-v3",sourceDigest:$source,workflowRef:"refs/heads/dev",signerWorkflow:$signerWorkflow,bundleDigest:$bundle}'; }

validate_historical_attestation() {
  local response=$1 selection=$2 subject=$3 normalized compact_bundle hash expected_bundle
  record=$(jq -c '.[0]' <<<"$response") || return 1
  normalized=$(jq -cS --arg subject "${subject#sha256:}" --argjson selection "$selection" '
    if type != "array" or length != 1 then
      error("result cardinality")
    else
      .[0] as $record |
      $record.attestation.bundle as $bundle |
      $record.verificationResult as $result |
      $result.signature.certificate as $certificate |
      $result.statement.subject as $subjects |
      if ($bundle | type) != "object" or
         ($subjects | type) != "array" or
         ($subjects | length) != 1 or
         $subjects[0].digest.sha256 != $subject or
         $certificate.sourceRepositoryURI != "https://github.com/NickolayMamonov/meet-backend-v3" or
         $certificate.sourceRepositoryDigest != $selection.row.signer or
         $certificate.sourceRepositoryRef != "refs/heads/dev" or
         $certificate.buildSignerURI != "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" or
         $certificate.buildSignerDigest != $selection.row.signer or
         $certificate.subjectAlternativeName != "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" or
         $certificate.issuer != "https://token.actions.githubusercontent.com" or
         $certificate.runInvocationURI != $selection.row.invocation or
         $result.statement.predicateType != "https://slsa.dev/provenance/v1" or
         $subjects[0].name != $selection.row.subject
      then
        error("observed evidence mismatch")
      else
        {
          bundle:$bundle,
          output:{
            subjectDigest:("sha256:" + $subject),
            predicateType:$result.statement.predicateType,
            sourceRepository:$certificate.sourceRepositoryURI,
            sourceDigest:$certificate.sourceRepositoryDigest,
            workflowRef:$certificate.sourceRepositoryRef,
            signerWorkflow:$certificate.buildSignerURI,
            bundleDigest:null
          }
        }
      end
    end
  ' <<<"$response") || return 1
  compact_bundle=$(jq -cS '.attestation.bundle' <<<"$record") || return 1
  compact_bundle=${compact_bundle%$'\r'}
  hash=$(printf '%s\n' "$compact_bundle" | sha256sum | awk '{print $1}') ||
    return 1
  expected_bundle=$(jq -r '.row.bundle' <<<"$selection") || return 1
  [ "sha256:$hash" = "$expected_bundle" ] || return 1
  jq -cnS --argjson normalized "$normalized" --arg bundle "sha256:$hash" \
    '$normalized.output | .bundleDigest = $bundle'
}

download_workflow_artifact() {
  local release_id=$1 expected_digest=$2 destination=$3
  local asset asset_id asset_digest asset_size actual_digest actual_size
  asset=$(jq -c --argjson releaseId "$release_id" '
    [.[] | select(.id == $releaseId) | .assets[] |
      select(.name == "image-index.json")] |
    if length == 1 then .[0] else empty end
  ' "$tmp/releases-normalized.json") ||
    fail "workflow artifact inventory lookup failed for release $release_id"
  [ -n "$asset" ] || fail "release $release_id does not have exactly one image-index.json asset"
  asset_id=$(jq -r '.id // empty' <<<"$asset")
  asset_digest=$(jq -r '.sha256 // empty' <<<"$asset")
  asset_size=$(jq -r '.size // empty' <<<"$asset")
  jq -e '.id | type == "number" and floor == . and . > 0' <<<"$asset" >/dev/null ||
    fail "workflow artifact ID is malformed for release $release_id"
  [[ "$asset_id" =~ ^[1-9][0-9]*$ ]] ||
    fail "workflow artifact ID is malformed for release $release_id"
  [ "$asset_digest" = "${expected_digest#sha256:}" ] ||
    fail "workflow artifact digest disagrees with image root for release $release_id"
  [[ "$asset_size" =~ ^[0-9]+$ ]] || fail "workflow artifact size is malformed for release $release_id"
  gh api --header 'Accept: application/octet-stream' \
    "repos/$repository/releases/assets/$asset_id" >"$destination" ||
    fail "workflow artifact read failed for release $release_id"
  actual_digest=$(sha256sum "$destination" | awk '{print $1}')
  [ "$actual_digest" = "$asset_digest" ] ||
    fail "workflow artifact bytes do not match release asset digest for $release_id"
  actual_size=$(wc -c <"$destination" | tr -d ' ')
  [ "$actual_size" -eq "$asset_size" ] ||
    fail "workflow artifact bytes do not match release asset size for $release_id"
}

collect_verified_attestations() {
  local digest=$1 source_digest=$2 record compact_bundle bundle_sha
  local selection=${3:-}
  local selection_status=
  if [ -n "$selection" ]; then
    selection_status=$(jq -r '.status // empty' <<<"$selection")
  fi
  if [ "$selection_status" = historical ]; then
    local signer storage release_id artifact
    local -a common_args=() args=()
    signer=$(jq -r '.row.signer' <<<"$selection")
    storage=$(jq -r '.row.storage' <<<"$selection")
    release_id=$(jq -r '.row.id' <<<"$selection")
    common_args=(--repo "$repository" --source-digest "$signer"
      --source-ref refs/heads/dev
      --signer-workflow github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml
      --signer-digest "$signer"
      --cert-oidc-issuer https://token.actions.githubusercontent.com
      --predicate-type https://slsa.dev/provenance/v1 --format json)
    case "$storage" in
      github-api-workflow-artifact)
        artifact="$tmp/workflow-artifact-${digest#sha256:}.json"
        download_workflow_artifact "$release_id" "$digest" "$artifact"
        args=("$artifact" "${common_args[@]}")
        ;;
      oci-registry-bundle)
        args=("oci://$image@$digest" --bundle-from-oci "${common_args[@]}")
        ;;
      *)
        fail "historical authority has unsupported verification transport: $storage"
        ;;
    esac
    local historical_file="$tmp/github-${digest#sha256:}.json"
    gh attestation verify "${args[@]}" >"$historical_file" || fail "GitHub attestation verification failed for $digest"
    validate_historical_attestation "$(<"$historical_file")" "$selection" "$digest" >"$tmp/historical-${digest#sha256:}.json" || fail "historical GitHub attestation evidence is malformed for $digest"
    cat "$tmp/historical-${digest#sha256:}.json" >>"$tmp/attestations.jsonl"
    return
  fi
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
    compact_bundle=$(jq -cS '.attestation.bundle' <<<"$record") ||
      fail "verified GitHub attestation bundle hashing failed for $digest"
    compact_bundle=${compact_bundle%$'\r'}
    bundle_sha=$(printf '%s\n' "$compact_bundle" | sha256sum | awk '{print $1}') ||
      fail "verified GitHub attestation bundle hashing failed for $digest"
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

usage() {
  echo "usage: $0 --repository OWNER/REPO --image ghcr.io/OWNER/IMAGE --output PATH [--candidate-alias ALIAS]" >&2
  exit 2
}

fail() { echo "test-promotion protected-state collection failed: $*" >&2; exit 1; }

main() {
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
    all(.assets[];
      (.id | type == "number" and floor == . and . > 0) and
      (.sha256 | test("^[0-9a-f]{64}$"))
    )
  )
' "$tmp/releases-normalized.json" >/dev/null ||
  fail "release inventory contains an unsupported or undigested asset"

release_tags=$(jq -r '.[].tag_name' "$tmp/releases-normalized.json")
tag_refs=$(
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    target=$(jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .target_commitish' \
      "$tmp/releases-normalized.json")
is_draft=$(jq -r --arg tag "$tag" '.[]|select(.tag_name==$tag)|.draft' "$tmp/releases-normalized.json")
    if [ "$tag" = v1.1.0 ] && [ "$is_draft" = true ]; then
      matching_refs=$(gh api "repos/$repository/git/matching-refs/tags/v1.1.0") || fail "draft tag absence read failed"
      jq -e 'type=="array" and all(.[]; type=="object" and (.ref|type=="string")) and ([.[]|select(.ref=="refs/tags/v1.1.0")]|length)==0' <<<"$matching_refs" >/dev/null || fail "draft v1.1.0 exact tag is present or malformed"
      jq -cnS --arg tag "$tag" '{tag:$tag,state:"absent"}'
      continue
    fi
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
release_record=$(jq -c --argjson id "$release_id" '.[]|select(.id==$id)|{id,tag:.tag_name,version:(.tag_name|sub("^v";"")),source:.target_commitish,draft,prerelease,immutable}' "$tmp/releases-normalized.json")
      product_context=$(jq -cnS --arg repository "$repository" --arg image "$image" --argjson release "$release_record" --argjson packageId "$version_id" --arg digest "$digest" --argjson tags "$tags_json" --argjson platform "$platform_descriptor" '{repository:$repository,image:$image,release:$release,package:{id:$packageId,digest:$digest,tags:$tags},rootDigest:$digest,platform:$platform}')
      selection=$(select_historical_authority "$product_context") || fail "historical product authority selection failed for $digest"
      jq -cnS --arg digest "$digest" --argjson releaseId "$release_id" \
        --arg platformDigest "$platform_digest" --argjson aliases "$tags_json" \
        '{digest:$digest,kind:"root",releaseId:$releaseId,rootDigest:null,
          platformDigest:$platformDigest,aliases:$aliases}' >>"$tmp/subjects.jsonl"
      release_source=$(jq -r --argjson id "$release_id" \
        '.[] | select(.id == $id) | .target_commitish' \
        "$tmp/releases-normalized.json")
      collect_verified_attestations "$digest" "$release_source" "$selection"
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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
