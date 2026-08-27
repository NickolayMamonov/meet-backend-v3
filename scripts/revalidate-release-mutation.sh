#!/usr/bin/env bash
set -euo pipefail

fail() { echo "release mutation revalidation failed: $*" >&2; exit 1; }
repository=${GITHUB_REPOSITORY:-}
release_id=
tag=
version=
source_sha=
expected_route=materialize
phase=complete
release_file=
policy_token_file=
credential_proof=
assets_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --release-id) release_id=${2:?}; shift 2 ;;
    --tag) tag=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --source-sha) source_sha=${2:?}; shift 2 ;;
    --expected-route) expected_route=${2:?}; shift 2 ;;
    --phase)
      phase=${2:?}
      [ "$phase" = empty ] || [ "$phase" = complete ] ||
        fail "phase must be empty or complete"
      shift 2
      ;;
    --release-file) release_file=${2:?}; shift 2 ;;
    --policy-token-file) policy_token_file=${2:?}; shift 2 ;;
    --credential-proof) credential_proof=${2:?}; shift 2 ;;
    --assets-dir) assets_dir=${2:?}; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[ "$expected_route" = materialize ] || fail "only materialize is publishable"
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || fail "release ID is invalid"
[ "$tag" = "v$version" ] || fail "tag/version mismatch"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "source SHA is invalid"
[ -n "$policy_token_file" ] || fail "dedicated immutable-policy reader token is required"
[ -s "$policy_token_file" ] || fail "policy reader token file is missing"
"$(dirname "${BASH_SOURCE[0]}")/release-mutation-policy.sh" check \
  --repository "$repository" --release-id "$release_id" --version "$version" \
  --tag "$tag" --source-sha "$source_sha" --operation publish >/dev/null
policy_args=(--repository "$repository" --token-file "$policy_token_file")
[ -z "$credential_proof" ] || policy_args+=(--credential-proof "$credential_proof")
"$(dirname "${BASH_SOURCE[0]}")/verify-immutable-release-policy.sh" \
  "${policy_args[@]}" >/dev/null
if [ -n "$release_file" ]; then
  release=$(jq -c . "$release_file") || fail "release snapshot is malformed"
else
  command -v gh >/dev/null 2>&1 || fail "gh is required"
  release=$(gh api "repos/$repository/releases/$release_id") ||
    fail "release read failed"
fi
assets=(release-manifest.json image-index.json image-inspect.txt SHA256SUMS)
if [ "$phase" = complete ] && [ -n "$assets_dir" ]; then
  [ -d "$assets_dir" ] || fail "asset directory is missing"
  for asset in "${assets[@]}"; do
    [ -f "$assets_dir/$asset" ] && [ ! -L "$assets_dir/$asset" ] ||
      fail "expected asset is missing or unsafe: $asset"
    [ -s "$assets_dir/$asset" ] || fail "expected asset is empty: $asset"
  done
  expected=$(printf '%s\n' "${assets[@]}" | sort)
  actual=$(find "$assets_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  [ "$actual" = "$expected" ] || fail "asset directory inventory is not exact"
fi
jq_filter='
  type == "object" and
  .id == $id and .name == $tag and .tag_name == $tag and
  .target_commitish == $source and
  .draft == true and .prerelease == false and
  has("immutable") and .immutable == false and
  has("published_at") and .published_at == null and
  (.assets | type == "array")
'
if [ "$phase" = empty ]; then
  jq_filter+=' and (.assets | length == 0)'
elif [ "$phase" = complete ]; then
  jq_filter+=' and
    (.assets | length == 4) and
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
    )'
fi
if [ "$phase" = complete ] && [ -n "$assets_dir" ]; then
  expected_sha256=(
    "$(sha256sum "$assets_dir/release-manifest.json" | awk '{print $1}')"
    "$(sha256sum "$assets_dir/image-index.json" | awk '{print $1}')"
    "$(sha256sum "$assets_dir/image-inspect.txt" | awk '{print $1}')"
    "$(sha256sum "$assets_dir/SHA256SUMS" | awk '{print $1}')"
  )
  expected_size=(
    "$(wc -c <"$assets_dir/release-manifest.json" | tr -d '[:space:]')"
    "$(wc -c <"$assets_dir/image-index.json" | tr -d '[:space:]')"
    "$(wc -c <"$assets_dir/image-inspect.txt" | tr -d '[:space:]')"
    "$(wc -c <"$assets_dir/SHA256SUMS" | tr -d '[:space:]')"
  )
  for index in "${!assets[@]}"; do
    jq_filter+=" and ([.assets[] | select(.name == \"${assets[$index]}\")] |
      length == 1 and
      .[0].digest == \"sha256:${expected_sha256[$index]}\" and
      .[0].size == ${expected_size[$index]})"
  done
fi
jq -e --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" \
  "$jq_filter" <<<"$release" >/dev/null || fail "release changed before publication"
echo "revalidated=true"
echo "release_id=$release_id"
echo "route=$expected_route"
echo "phase=$phase"
