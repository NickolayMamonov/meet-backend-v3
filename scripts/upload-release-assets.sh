#!/usr/bin/env bash
set -euo pipefail

fail() { echo "release asset upload failed: $*" >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository=${GITHUB_REPOSITORY:-}
release_id=
tag=
version=
source_sha=
assets_dir=
policy_token_file=
credential_proof=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --release-id) release_id=${2:?}; shift 2 ;;
    --tag) tag=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --source-sha) source_sha=${2:?}; shift 2 ;;
    --assets-dir) assets_dir=${2:?}; shift 2 ;;
    --policy-token-file) policy_token_file=${2:?}; shift 2 ;;
    --credential-proof) credential_proof=${2:?}; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[[ "$repository" =~ ^[^/]+/[^/]+$ ]] || fail "repository is required"
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || fail "release ID is required"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "version is invalid"
[ "$tag" = "v$version" ] || fail "tag/version mismatch"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "source SHA is invalid"
[ -d "$assets_dir" ] || fail "asset directory is missing"
command -v gh >/dev/null 2>&1 || fail "gh is required"
[ -n "$policy_token_file" ] || fail "dedicated immutable-policy reader token is required"
[ -s "$policy_token_file" ] || fail "policy reader token file is missing"

assets=(release-manifest.json image-index.json image-inspect.txt SHA256SUMS)
for asset in "${assets[@]}"; do
  [ -f "$assets_dir/$asset" ] && [ ! -L "$assets_dir/$asset" ] ||
    fail "missing or unsafe asset: $asset"
  [ -s "$assets_dir/$asset" ] || fail "empty asset: $asset"
done
expected=$(printf '%s\n' "${assets[@]}" | sort)
actual=$(find "$assets_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
[ "$actual" = "$expected" ] || fail "asset directory contains an unexpected file"

policy_args=(--repository "$repository" --token-file "$policy_token_file")
[ -z "$credential_proof" ] || policy_args+=(--credential-proof "$credential_proof")

validate_prefix() {
  local phase=$1 release asset index expected_sha expected_size
  release=$(gh api "repos/$repository/releases/$release_id") ||
    fail "live release read failed before asset phase $phase"
  jq -e --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" \
    --argjson phase "$phase" '
    type == "object" and
    .id == $id and .name == $tag and .tag_name == $tag and
    .target_commitish == $source and
    .draft == true and .prerelease == false and
    has("immutable") and .immutable == false and
    has("published_at") and .published_at == null and
    (.assets | type == "array" and length == $phase) and
    ([.assets[].name] | unique | length == $phase) and
    ([.assets[].id] | unique | length == $phase) and
    ([.assets[].name] | sort) ==
      (["release-manifest.json","image-index.json","image-inspect.txt","SHA256SUMS"]
        [0:$phase] | sort) and
    all(.assets[];
      type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.name | type == "string") and
      .state == "uploaded" and
      (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.size | type == "number" and floor == . and . > 0)
    )
  ' <<<"$release" >/dev/null ||
    fail "numeric release is not the exact draft phase $phase"
  [ "$phase" -eq 0 ] || {
    index=0
    while [ "$index" -lt "$phase" ]; do
      asset=${assets[$index]}
      expected_sha=$(sha256sum "$assets_dir/$asset" | awk '{print $1}')
      expected_size=$(wc -c <"$assets_dir/$asset" | tr -d '[:space:]')
      jq -e --arg name "$asset" --arg digest "sha256:$expected_sha" \
        --argjson size "$expected_size" '
        [.assets[] | select(.name == $name)] | length == 1 and
        .[0].state == "uploaded" and .[0].digest == $digest and
        .[0].size == $size
      ' <<<"$release" >/dev/null ||
        fail "remote asset prefix does not match local asset $asset"
      index=$((index + 1))
    done
  }
}

phase=0
for asset in "${assets[@]}"; do
  "$script_dir/release-mutation-policy.sh" check \
    --repository "$repository" --release-id "$release_id" \
    --version "$version" --tag "$tag" --source-sha "$source_sha" \
    --operation upload-assets >/dev/null
  "$script_dir/verify-immutable-release-policy.sh" \
    "${policy_args[@]}" >/dev/null
  validate_prefix "$phase"
  gh release upload "$tag" "$assets_dir/$asset" --repo "$repository" ||
    fail "asset upload failed: $asset"
  phase=$((phase + 1))
done
validate_prefix "$phase"
