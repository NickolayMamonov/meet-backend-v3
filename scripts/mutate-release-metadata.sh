#!/usr/bin/env bash
set -euo pipefail

fail() { echo "release metadata mutation failed: $*" >&2; exit 1; }
usage() {
  echo "usage: $0 publish --repository OWNER/REPO --release-id ID --version X.Y.Z --tag vX.Y.Z --source-sha SHA --assets-dir PATH [--release-file PATH] [--policy-token-file PATH] [--credential-proof PATH]" >&2
  exit 2
}
[ "${1:-}" = publish ] || usage
shift
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository=${GITHUB_REPOSITORY:-}
release_id=
version=
tag=
source_sha=
release_file=
policy_token_file=
credential_proof=
assets_dir=
repo_dir=.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --release-id) release_id=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --tag) tag=${2:?}; shift 2 ;;
    --source-sha) source_sha=${2:?}; shift 2 ;;
    --release-file) release_file=${2:?}; shift 2 ;;
    --policy-token-file) policy_token_file=${2:?}; shift 2 ;;
    --credential-proof) credential_proof=${2:?}; shift 2 ;;
    --assets-dir) assets_dir=${2:?}; shift 2 ;;
    --repo-dir) repo_dir=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$repository" =~ ^[^/]+/[^/]+$ ]] || usage
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[ "$tag" = "v$version" ] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || usage
[ -n "$policy_token_file" ] || fail "dedicated immutable-policy reader token is required"
[ -s "$policy_token_file" ] || fail "policy reader token file is missing"
[ -d "$assets_dir" ] || fail "asset directory is missing"
assets=(release-manifest.json image-index.json image-inspect.txt SHA256SUMS)
for asset in "${assets[@]}"; do
  [ -f "$assets_dir/$asset" ] && [ ! -L "$assets_dir/$asset" ] ||
    fail "missing or unsafe asset: $asset"
  [ -s "$assets_dir/$asset" ] || fail "empty asset: $asset"
done
expected=$(printf '%s\n' "${assets[@]}" | sort)
actual=$(find "$assets_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[ "$actual" = "$expected" ] || fail "asset directory contains an unexpected file"

validate_release() {
  local release=$1 asset expected_sha expected_size
  local expected actual
  expected=$(printf '%s\n' "${assets[@]}" | sort)
  actual=$(find "$assets_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [ "$actual" = "$expected" ] || fail "asset directory contains an unexpected file"
  for asset in "${assets[@]}"; do
    [ -f "$assets_dir/$asset" ] && [ ! -L "$assets_dir/$asset" ] &&
      [ -s "$assets_dir/$asset" ] || fail "missing, empty, or unsafe asset: $asset"
  done
  jq -e --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" '
    type == "object" and
    .id == $id and .name == $tag and .tag_name == $tag and
    .target_commitish == $source and
    .draft == true and .prerelease == false and
    has("immutable") and .immutable == false and
    has("published_at") and .published_at == null and
    (.assets | type == "array" and length == 4) and
    ([.assets[].name] | sort) ==
      ["SHA256SUMS","image-index.json","image-inspect.txt","release-manifest.json"] and
    ([.assets[].id] | unique | length == 4) and
    all(.assets[];
      type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.name | type == "string") and
      .state == "uploaded" and
      (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.size | type == "number" and floor == . and . > 0)
    )
  ' <<<"$release" >/dev/null || fail "release is not the exact publishable draft"
  for asset in "${assets[@]}"; do
    expected_sha=$(sha256sum "$assets_dir/$asset" | awk '{print $1}')
    expected_size=$(wc -c <"$assets_dir/$asset" | tr -d '[:space:]')
    jq -e --arg name "$asset" --arg digest "sha256:$expected_sha" \
      --argjson size "$expected_size" '
      [.assets[] | select(.name == $name)] | length == 1 and
      .[0].digest == $digest and .[0].state == "uploaded" and
      .[0].size == $size
    ' <<<"$release" >/dev/null ||
      fail "remote asset does not match local bytes: $asset"
  done
}

if [ -n "$release_file" ]; then
  before=$(jq -c . "$release_file") || fail "release fixture is malformed"
else
  command -v gh >/dev/null 2>&1 || fail "gh is required"
  before=$(gh api "repos/$repository/releases/$release_id") ||
    fail "release descriptor lookup failed"
fi
"$script_dir/release-mutation-policy.sh" check \
  --repository "$repository" --release-id "$release_id" --version "$version" \
  --tag "$tag" --source-sha "$source_sha" --operation publish >/dev/null
policy_args=(--repository "$repository" --token-file "$policy_token_file")
[ -z "$credential_proof" ] || policy_args+=(--credential-proof "$credential_proof")
"$script_dir/verify-immutable-release-policy.sh" \
  "${policy_args[@]}" >/dev/null
validate_release "$before"

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM
notes="$tmp/notes"
git -C "$repo_dir" show "$source_sha:CHANGELOG.md" >"$tmp/changelog" 2>/dev/null ||
  fail "source changelog is unavailable"
awk -v version="$version" '
  index($0, "## [" version "]") == 1 || index($0, "## " version) == 1 { found=1 }
  found && $0 ~ /^## / && index($0, "## [" version "]") != 1 &&
    index($0, "## " version) != 1 { exit }
  found { print }
  END { if (!found) exit 3 }
' "$tmp/changelog" >"$notes" || fail "release changelog section is missing"
payload="$tmp/payload.json"
jq -n --arg tag "$tag" --arg target "$source_sha" --rawfile body "$notes" '
  {tag_name:$tag,target_commitish:$target,name:$tag,body:$body,draft:false,
   prerelease:false,make_latest:"false",generate_release_notes:false}
' >"$payload"
if [ -n "$release_file" ]; then
  jq --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" '
    .id=$id | .tag_name=$tag | .target_commitish=$source | .draft=false |
    .prerelease=false | .name=$tag
  ' <<<"$before"
else
  "$script_dir/verify-immutable-release-policy.sh" \
    "${policy_args[@]}" >/dev/null
  "$script_dir/verify-release-tag-ref.sh" \
    --repository "$repository" --tag v1.1.0 \
    --source-sha 36ffd11ea4d35147f1df9c1cafa6a330300c1339 \
    --expect-absent
  "$script_dir/verify-release-tag-ref.sh" \
    --repository "$repository" --tag "$tag" \
    --source-sha "$source_sha" --expect-absent
  before=$(gh api "repos/$repository/releases/$release_id") ||
    fail "final release descriptor lookup failed"
  validate_release "$before"
  after=$(gh api --method PATCH "repos/$repository/releases/$release_id" --input "$payload") ||
    fail "release publication PATCH failed"
  jq -e --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" '
    type == "object" and
    .id == $id and .name == $tag and .tag_name == $tag and
    .target_commitish == $source and
    .draft == false and .prerelease == false and
    has("published_at") and
    (.published_at | type == "string" and length > 0) and
    (.assets | type == "array" and length == 4) and
    ([.assets[].name] | sort) ==
      ["SHA256SUMS","image-index.json","image-inspect.txt","release-manifest.json"] and
    ([.assets[].id] | unique | length == 4) and
    all(.assets[];
      type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.name | type == "string") and
      .state == "uploaded" and
      (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.size | type == "number" and floor == . and . > 0)
    )
  ' <<<"$after" >/dev/null ||
    fail "release publication response failed its postcondition"
  for asset in "${assets[@]}"; do
    expected_sha=$(sha256sum "$assets_dir/$asset" | awk '{print $1}')
    expected_size=$(wc -c <"$assets_dir/$asset" | tr -d '[:space:]')
    jq -e --arg name "$asset" --arg digest "sha256:$expected_sha" \
      --argjson size "$expected_size" '
      [.assets[] | select(.name == $name)] | length == 1 and
      .[0].digest == $digest and .[0].state == "uploaded" and
      .[0].size == $size
    ' <<<"$after" >/dev/null ||
      fail "release publication response does not match local bytes: $asset"
  done
fi
echo "mutation=verified"
echo "operation=publish"
echo "release_id=$release_id"
echo "post_patch_writers=none"
