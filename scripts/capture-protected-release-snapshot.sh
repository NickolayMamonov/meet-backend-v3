#!/usr/bin/env bash
set -euo pipefail

fail() { echo "protected snapshot capture failed: $*" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository=${GITHUB_REPOSITORY:-}
image=
blocked_id=368531227
blocked_version=1.1.0
immutable_id=367640510
immutable_version=1.0.1
output=
work_dir=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --image) image=${2:?}; shift 2 ;;
    --blocked-release-id) blocked_id=${2:?}; shift 2 ;;
    --blocked-version) blocked_version=${2:?}; shift 2 ;;
    --immutable-release-id) immutable_id=${2:?}; shift 2 ;;
    --immutable-version) immutable_version=${2:?}; shift 2 ;;
    --output) output=${2:?}; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "repository is invalid"
[[ "$image" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "image is invalid"
[ -n "$output" ] || fail "output is required"
command -v gh >/dev/null 2>&1 || fail "gh is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

work_dir=$(mktemp -d)
trap 'rm -r -- "$work_dir"' EXIT HUP INT TERM

body_sha() {
  local body=$1
  printf '%s' "$body" | sha256sum | awk '{print $1}'
}

asset_records() {
  local release=$1 asset_dir=$2 asset id response sha
  mkdir -p "$asset_dir"
  : >"$asset_dir/records.jsonl"
  while IFS= read -r asset; do
    id=$(jq -r --arg name "$asset" \
      '.assets[] | select(.name == $name) | .id' "$release")
    response=$asset_dir/$asset
    gh api --method GET \
      --header 'Accept: application/octet-stream' \
      "repos/$repository/releases/assets/$id" \
      >"$response" || fail "release asset download failed"
    sha=$(sha256sum "$response" | awk '{print $1}')
    jq -cn \
      --argjson id "$id" \
      --arg name "$asset" \
      --arg sha256 "$sha" \
      --argjson asset "$(
        jq -c --arg name "$asset" '.assets[] | select(.name == $name)' "$release"
      )" '
      {
        id:$id,nodeId:($asset.node_id // null),apiUrl:($asset.url // null),
        browserDownloadUrl:($asset.browser_download_url // null),name:$name,
        label:($asset.label // null),size:($asset.size // null),
        state:($asset.state // null),contentType:($asset.content_type // null),
        createdAt:($asset.created_at // null),updatedAt:($asset.updated_at // null),
        apiDigest:($asset.digest // null),sha256:$sha256
      }
    ' >>"$asset_dir/records.jsonl"
  done < <(jq -r '.assets[]?.name' "$release" | tr -d '\r' | sort)
  jq -cS -s 'sort_by(.name)' "$asset_dir/records.jsonl"
}

read_ref() {
  local tag=$1 output_file=$2 error_file object type sha peeled
  error_file=$work_dir/ref-error
  if object=$(gh api "repos/$repository/git/ref/tags/$tag" 2>"$error_file"); then
    type=$(jq -r '.object.type' <<<"$object")
    sha=$(jq -r '.object.sha' <<<"$object")
    peeled=$sha
    if [ "$type" = tag ]; then
      object=$(gh api "repos/$repository/git/tags/$sha") ||
        fail "annotated tag object read failed"
      peeled=$(jq -r '.object.sha' <<<"$object")
    fi
    jq -n -S --arg tag "$tag" --arg type "$type" --arg sha "$sha" \
      --arg peeled "$peeled" '
      {tag:$tag,state:"present",objectType:$type,objectSha:$sha,
       peeledCommitSha:$peeled,annotatedChain:[]}
    ' >"$output_file"
  else
    grep -Eq 'HTTP 404|Not Found' "$error_file" ||
      fail "protected tag ref read failed"
    jq -n -S --arg tag "$tag" '{tag:$tag,state:"absent"}' >"$output_file"
  fi
}

registry_versions() {
  local package owner name file
  package=${image#ghcr.io/}
  owner=${package%%/*}
  name=${package#*/}
  file=$work_dir/registry-versions
  if ! gh api --paginate --slurp \
      "users/$owner/packages/container/$name/versions?per_page=100" |
      jq -c 'add // []' >"$file"; then
    gh api --paginate --slurp \
      "orgs/$owner/packages/container/$name/versions?per_page=100" |
      jq -c 'add // []' >"$file" || fail "GHCR package inventory read failed"
  fi
  jq -cS '
    map({
      id,
      digest:(.name // null),
      tags:((.metadata.container.tags // []) | sort)
    }) |
    sort_by(.digest)
  ' "$file"
}

registry_referrers() {
  local digest=$1 package=${image#ghcr.io/} github_token registry_token username
  local response status netrc
  local item ref_digest raw raw_sha predicate_types size
  local records=$work_dir/referrers.jsonl
  [ -n "$digest" ] || { printf '[]'; return; }
  github_token=$(gh auth token 2>/dev/null) || fail "GHCR credential read failed"
  [ -n "$github_token" ] || fail "GHCR credential is empty"
  username=$("$SCRIPT_DIR/resolve-ghcr-username.sh") ||
    fail "GHCR username resolution failed"
  netrc=$work_dir/ghcr.netrc
  umask 077
  printf 'machine ghcr.io login %s password %s\n' "$username" "$github_token" \
    >"$netrc"
  registry_token=$(
    curl --silent --show-error --fail-with-body --connect-timeout 10 --max-time 30 \
      --netrc-file "$netrc" \
      "https://ghcr.io/token?service=ghcr.io&scope=repository:$package:pull" |
      jq -r '.token // empty'
  ) || fail "GHCR registry token exchange failed"
  [ -n "$registry_token" ] || fail "GHCR registry token is empty"
  response=$work_dir/referrers-response.json
  status=$(curl --silent --show-error --connect-timeout 10 --max-time 30 \
    --header "Authorization: Bearer $registry_token" \
    --header 'Accept: application/vnd.oci.image.index.v1+json' \
    --output "$response" --write-out '%{http_code}' \
    "https://ghcr.io/v2/$package/referrers/$digest") ||
    fail "OCI referrer transport failed"
  case "$status" in
    404) printf '[]'; return ;;
    200) ;;
    *) fail "OCI referrer read returned HTTP $status" ;;
  esac
  jq -e '.manifests | type == "array"' "$response" >/dev/null ||
    fail "OCI referrer response is malformed"
  : >"$records"
  while IFS= read -r item; do
    ref_digest=$(jq -r '.digest' <<<"$item")
    size=$(jq -r '.size // 0' <<<"$item")
    raw=$work_dir/referrer-${ref_digest//:/-}.json
    status=$(curl --silent --show-error --fail-with-body \
      --connect-timeout 10 --max-time 30 \
      --header "Authorization: Bearer $registry_token" \
      --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
      --output "$raw" --write-out '%{http_code}' \
      "https://ghcr.io/v2/$package/manifests/$ref_digest") ||
      fail "OCI referrer manifest transport failed"
    [ "$status" = 200 ] || fail "OCI referrer manifest read returned HTTP $status"
    jq -e . "$raw" >/dev/null || fail "OCI referrer manifest is malformed"
    raw_sha=$(sha256sum "$raw" | awk '{print $1}')
    predicate_types=$(jq -c '
      [(.annotations["in-toto.io/predicate-type"] // empty)] |
      map(select(type == "string")) | sort
    ' "$raw")
    jq -cn \
      --arg digest "$ref_digest" \
      --arg mediaType "$(jq -r '.mediaType // ""' <<<"$item")" \
      --argjson size "$size" \
      --arg subjectDigest "$digest" \
      --arg artifactType "$(jq -r '.artifactType // ""' <<<"$item")" \
      --argjson predicateTypes "$predicate_types" \
      --arg rawManifestSha256 "$raw_sha" '
      {digest:$digest,mediaType:$mediaType,size:$size,subjectDigest:$subjectDigest,
       artifactType:(if $artifactType == "" then null else $artifactType end),
       predicateTypes:$predicateTypes,rawManifestSha256:$rawManifestSha256}
    ' >>"$records"
  done < <(jq -c '.manifests[]' "$response")
  jq -cS -s 'sort_by(.digest)' "$records"
}

registry_state() {
  local version=$1 source=$2 versions_file=$work_dir/versions.json
  local versions subject digest bindings protected_versions referrers
  registry_versions >"$versions_file"
  versions=$(jq -cS . "$versions_file")
  subject=$(jq -c --arg version "$version" --arg source "$source" '
    [
      .[] |
      select((.tags | index("v"+$version)) or
        (.tags | index($version)) or
        (.tags | index("sha-"+$source)))
    ] | first // {}
  ' <<<"$versions")
  digest=$(jq -r '.digest // empty' <<<"$subject")
  bindings=$(jq -cn --arg version "$version" --arg source "$source" \
    --argjson versions "$versions" '
    reduce [("v"+$version),$version,("sha-"+$source),"latest"][] as $alias
      ({};
       .[$alias] = (
         [$versions[] | select(.tags | index($alias)) | .digest] |
         unique |
         if length == 1 then .[0] else null end
       ))
  ')
  protected_versions=$(jq -cS --arg digest "$digest" '
    if $digest == "" then [] else map(select(.digest == $digest)) end
  ' <<<"$versions")
  if ! referrers=$(registry_referrers "$digest"); then
    fail "OCI referrer closure capture failed"
  fi
  jq -n -cS --argjson bindings "$bindings" --argjson subject "$subject" \
    --argjson versions "$protected_versions" --argjson referrers "$referrers" '
    {
      protectedAliasBindings:$bindings,
      subjectDigest:($subject.digest // null),
      subjectAliases:($subject.tags // [] | sort),
      versions:$versions,
      referrers:$referrers
    }
  '
}

attestation_state() {
  local digest=$1 file=$work_dir/attestations.json
  [ "$digest" != null ] || { printf '[]'; return; }
  if ! gh api "repos/$repository/attestations/$digest" \
      >"$file" 2>"$work_dir/attestation-error"; then
    grep -Eq 'HTTP 404|Not Found' "$work_dir/attestation-error" ||
      fail "GitHub attestation read failed"
    printf '[]'
    return
  fi
  "$SCRIPT_DIR/normalize-github-attestations.sh" \
    --input "$file" \
    --subject-digest "$digest"
}

snapshot_object() {
  local release_file=$1 version=$2 ref_file=$3 asset_dir=$4
  local release assets body_file body_hash registry
  release=$(jq -c . "$release_file") || fail "release response is malformed"
  assets=$(asset_records "$release_file" "$asset_dir")
  body_file=$asset_dir/body.txt
  jq -rj '.body // ""' "$release_file" | tr -d '\r' >"$body_file"
  body_hash=$(sha256sum "$body_file" | awk '{print $1}')
  registry=$(registry_state "$version" "$(jq -r '.target_commitish' <<<"$release")")
  jq -n -cS \
    --arg version "$version" --arg bodyHash "$body_hash" \
    --arg tag "$(jq -r '.tag_name' <<<"$release")" \
    --arg source "$(jq -r '.target_commitish' <<<"$release")" \
    --slurpfile releaseData "$release_file" --argjson assets "$assets" \
    --argjson gitRef "$(cat "$ref_file")" \
    --argjson registry "$registry" \
    --argjson attestations "$(attestation_state "$(jq -r '.subjectDigest // null' <<<"$registry")")" '
    {
      identity:{
        releaseId:$releaseData[0].id,version:$version,tag:$tag,sourceSha:$source
      },
      release:{
        id:$releaseData[0].id,nodeId:($releaseData[0].node_id // null),
        apiUrl:($releaseData[0].url // null),htmlUrl:($releaseData[0].html_url // null),
        assetsApiUrl:($releaseData[0].assets_url // null),
        uploadUrlTemplate:($releaseData[0].upload_url // null),
        tarballUrl:($releaseData[0].tarball_url // null),
        zipballUrl:($releaseData[0].zipball_url // null),
        tagName:$releaseData[0].tag_name,name:($releaseData[0].name // null),
        targetCommitish:$releaseData[0].target_commitish,
        draft:$releaseData[0].draft,immutable:($releaseData[0].immutable // false),
        prerelease:$releaseData[0].prerelease,
        createdAt:($releaseData[0].created_at // null),
        updatedAt:($releaseData[0].updated_at // null),
        publishedAt:($releaseData[0].published_at // null),bodySha256:$bodyHash
      },
      assets:$assets,gitRef:$gitRef,
      registry:$registry,
      githubAttestations:$attestations
    }
  '
}

validate_single_object() {
  local label=$1 file=$2 shape
  shape=$(jq -c -s '
    map(
      if type == "object"
      then {type:type,keys:(keys | sort)}
      else {type:type}
      end
    )
  ' "$file") || fail "$label snapshot output is not valid JSON"
  [ "$shape" = '[{"type":"object","keys":["assets","gitRef","githubAttestations","identity","registry","release"]}]' ] ||
    fail "$label snapshot output shape is $shape"
}

main() {
  local blocked_file=$work_dir/blocked.json immutable_file=$work_dir/immutable.json
  local blocked_ref=$work_dir/blocked-ref.json immutable_ref=$work_dir/immutable-ref.json
  local blocked_assets=$work_dir/blocked-assets immutable_assets=$work_dir/immutable-assets
  local blocked_object=$work_dir/blocked-object.json
  local immutable_object=$work_dir/immutable-object.json
  gh api "repos/$repository/releases/$blocked_id" >"$blocked_file" ||
    fail "blocked release read failed"
  gh api "repos/$repository/releases/$immutable_id" >"$immutable_file" ||
    fail "immutable predecessor read failed"
  read_ref "v$blocked_version" "$blocked_ref"
  read_ref "v$immutable_version" "$immutable_ref"
  if ! snapshot_object "$blocked_file" "$blocked_version" \
    "$blocked_ref" "$blocked_assets" >"$blocked_object"; then
    fail "blocked snapshot normalization failed"
  fi
  validate_single_object blocked "$blocked_object"
  if ! snapshot_object "$immutable_file" "$immutable_version" \
    "$immutable_ref" "$immutable_assets" >"$immutable_object"; then
    fail "immutable snapshot normalization failed"
  fi
  validate_single_object immutable "$immutable_object"
  jq -n -cS \
    --arg schema "meet-backend/protected-release-history/v1" \
    --arg repository "$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')" \
    --arg image "$(printf '%s' "$image" | tr '[:upper:]' '[:lower:]')" \
    --slurpfile blocked "$blocked_object" \
    --slurpfile immutable "$immutable_object" '
    {
      schema:$schema,repository:$repository,image:$image,
      objects:{blockedV1_1_0:$blocked[0],immutableV1_0_1:$immutable[0]}
    }
  ' | tr -d '\r' >"$output" || fail "snapshot normalization failed"
}

main
