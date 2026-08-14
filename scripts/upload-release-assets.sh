#!/usr/bin/env bash
set -euo pipefail
fail() { echo "release asset upload failed: $*" >&2; exit 1; }
repository=${GITHUB_REPOSITORY:-}
release_id=
assets_dir=
policy_token_file=
credential_proof=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --release-id) release_id=${2:?}; shift 2 ;;
    --assets-dir) assets_dir=${2:?}; shift 2 ;;
    --policy-token-file) policy_token_file=${2:?}; shift 2 ;;
    --credential-proof) credential_proof=${2:?}; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[[ "$repository" =~ ^[^/]+/[^/]+$ ]] || fail "repository is required"
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || fail "release ID is required"
[ -d "$assets_dir" ] || fail "asset directory is missing"
assets=(release-manifest.json image-index.json image-inspect.txt SHA256SUMS)
for asset in "${assets[@]}"; do
  [ -f "$assets_dir/$asset" ] || fail "missing asset: $asset"
done
find "$assets_dir" -maxdepth 1 -type f -printf '%f\n' | sort | {
  expected=$(printf '%s\n' "${assets[@]}" | sort)
  actual=$(sed '/^$/d')
  [ "$actual" = "$expected" ] || fail "asset directory contains an unexpected file"
}
command -v gh >/dev/null 2>&1 || fail "gh is required"
if [ -n "$policy_token_file" ]; then
  [ -s "$policy_token_file" ] || fail "policy reader token file is missing"
  policy_args=(--repository "$repository" --token-file "$policy_token_file")
  [ -z "$credential_proof" ] || policy_args+=(--credential-proof "$credential_proof")
  "$(dirname "${BASH_SOURCE[0]}")/verify-immutable-release-policy.sh" \
    "${policy_args[@]}" >/dev/null
fi
for asset in "${assets[@]}"; do
  gh release upload "$release_id" "$assets_dir/$asset" \
    --repo "$repository"
done
