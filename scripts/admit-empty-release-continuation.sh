#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail() {
  echo "empty release continuation admission failed: $*" >&2
  exit 1
}
usage() {
  cat >&2 <<'EOF'
usage: admit-empty-release-continuation.sh
  --repository OWNER/REPO --repo-dir DIR --dev-ref REF
  --release-id ID --tag TAG --version VERSION --source-sha SHA
  --releases-file PATH --registry-state-file PATH [--refs-file PATH]
EOF
  exit 2
}
path_arg() {
  case "$1" in
    [A-Za-z]:/*)
      command -v cygpath >/dev/null 2>&1 && cygpath -u "$1" || printf '%s' "$1"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

repository=
repo_dir=
dev_ref=
release_id=
tag=
version=
source_sha=
releases_file=
registry_state_file=
refs_file=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --repo-dir) repo_dir=$(path_arg "${2:?}"); shift 2 ;;
    --dev-ref) dev_ref=${2:?}; shift 2 ;;
    --release-id) release_id=${2:?}; shift 2 ;;
    --tag) tag=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --source-sha) source_sha=${2:?}; shift 2 ;;
    --releases-file) releases_file=$(path_arg "${2:?}"); shift 2 ;;
    --registry-state-file) registry_state_file=$(path_arg "${2:?}"); shift 2 ;;
    --refs-file) refs_file=$(path_arg "${2:?}"); shift 2 ;;
    *) usage ;;
  esac
done

[[ "$repository" =~ ^[^/]+/[^/]+$ ]] || usage
[ -d "$repo_dir" ] || usage
[ -n "$dev_ref" ] || usage
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[ "$tag" = "v$version" ] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || usage
[ -f "$releases_file" ] || usage
[ -f "$registry_state_file" ] || usage
[ -z "$refs_file" ] || [ -f "$refs_file" ] || usage

[ "$release_id" != 368531227 ] || fail "permanently denied release ID"
[ "$tag" != v1.1.0 ] || fail "permanently denied tag"
[ "$source_sha" != 36ffd11ea4d35147f1df9c1cafa6a330300c1339 ] ||
  fail "permanently denied source"
if [ -z "$refs_file" ]; then
  if [ "$release_id" != 371012814 ] ||
     [ "$tag" != v1.2.0 ] ||
     [ "$version" != 1.2.0 ] ||
     [ "$source_sha" != 9b6d2b06c0336ab8d153564dcf6328e81c4d7b36 ]; then
    fail "only the exact quarantined v1.2.0 draft may continue"
  fi
fi

source_commit=$(git -C "$repo_dir" rev-parse --verify "${source_sha}^{commit}" 2>/dev/null) ||
  fail "release source commit is unavailable"
dev_commit=$(git -C "$repo_dir" rev-parse --verify "${dev_ref}^{commit}" 2>/dev/null) ||
  fail "current dev commit is unavailable"
[ "$source_commit" = "$source_sha" ] || fail "release source does not resolve exactly"
git -C "$repo_dir" merge-base --is-ancestor "$source_commit" "$dev_commit" ||
  fail "release source is not an ancestor of current dev"

for ref in "$source_commit" "$dev_commit"; do
  manifest=$(git -C "$repo_dir" show "$ref:.release-please-manifest.json" |
    jq -r '."."' 2>/dev/null || true)
  version_file=$(git -C "$repo_dir" show "$ref:version.json" |
    jq -r '.version' 2>/dev/null || true)
  [ "$manifest" = "$version" ] && [ "$version_file" = "$version" ] ||
    fail "release and current dev version authority must both remain exact"
done

if [ -n "$refs_file" ]; then
  "$ROOT_DIR/scripts/verify-release-tag-ref.sh" \
    --repository "$repository" --tag "$tag" --source-sha "$source_sha" \
    --fixture "$refs_file" --expect-absent >/dev/null
else
  "$ROOT_DIR/scripts/verify-release-tag-ref.sh" \
    --repository "$repository" --tag "$tag" --source-sha "$source_sha" \
    --expect-absent >/dev/null
fi

expected_registry=$(mktemp)
trap 'rm -f -- "$expected_registry"' EXIT
printf '%s\n' \
  "$tag absent" \
  "$version absent" \
  "sha-$source_sha absent" \
  "latest=absent" \
  "state=empty" >"$expected_registry"
cmp --silent "$expected_registry" "$registry_state_file" ||
  fail "candidate registry is not exactly empty"

"$ROOT_DIR/scripts/resolve-release-descriptor.sh" verify \
  --repo-dir "$repo_dir" --dev-ref "$source_sha" \
  --release-id "$release_id" --tag "$tag" --version "$version" \
  --source-sha "$source_sha" --phase empty \
  --releases-file "$releases_file"
