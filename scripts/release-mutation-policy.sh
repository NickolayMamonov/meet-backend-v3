#!/usr/bin/env bash
set -euo pipefail

fail() { echo "release mutation policy rejected: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
usage:
  release-mutation-policy.sh check --repository OWNER/REPO
    --release-id ID --version VERSION --tag TAG --source-sha SHA
    [--ref TAG|--operation OP]
EOF
  exit 2
}

[ "${1:-}" = check ] || usage
shift
repository=${GITHUB_REPOSITORY:-}
release_id=
version=
tag=
source_sha=
ref=
operation=read
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=${2:?}; shift 2 ;;
    --release-id) release_id=${2:?}; shift 2 ;;
    --version) version=${2:?}; shift 2 ;;
    --tag) tag=${2:?}; shift 2 ;;
    --source-sha) source_sha=${2:?}; shift 2 ;;
    --ref) ref=${2:?}; shift 2 ;;
    --operation) operation=${2:?}; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  fail "repository is not canonical"
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || fail "release ID is not numeric"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "version is not canonical"
[[ "$tag" = "v$version" ]] || fail "tag/version mismatch"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || fail "source SHA is not lowercase full SHA"
[ "$release_id" != 368531227 ] || fail "permanently denied release ID"
[ "$version" != 1.1.0 ] || fail "permanently denied version"
[ "$tag" != v1.1.0 ] || fail "permanently denied tag"
[ "$ref" != v1.1.0 ] || fail "permanently denied ref"
case "$operation" in
  read|verify|upload-assets|publish) ;;
  *) fail "unknown operation" ;;
esac

jq -n \
  --arg schema "meet-backend/release-mutation-policy/v1" \
  --arg repository "$repository" --arg releaseId "$release_id" \
  --arg version "$version" --arg tag "$tag" --arg sourceSha "$source_sha" \
  --arg operation "$operation" \
  '{
    schema: $schema, repository: $repository, releaseId: $releaseId,
    version: $version, tag: $tag, sourceSha: $sourceSha, operation: $operation,
    writerAllowed: true, blockedTuple: {releaseId:"368531227",version:"1.1.0",tag:"v1.1.0"}
  }'
