#!/usr/bin/env bash
set -euo pipefail
fail() { echo "protected snapshot capture failed: $*" >&2; exit 1; }
repository=${GITHUB_REPOSITORY:-}
image=
blocked_id=368531227
blocked_version=1.1.0
immutable_id=367640510
immutable_version=1.0.1
output=
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
[ -n "$repository" ] && [ -n "$image" ] && [ -n "$output" ] || fail "required option missing"
command -v gh >/dev/null 2>&1 || fail "gh is required"
canonical_repository=$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')
blocked=$(gh api "repos/$repository/releases/$blocked_id") || fail "blocked release read failed"
immutable=$(gh api "repos/$repository/releases/$immutable_id") || fail "immutable predecessor read failed"
jq -n -S \
  --arg schema "meet-backend/protected-release-history/v1" \
  --arg repository "$canonical_repository" --arg image "${image,,}" \
  --arg blockedVersion "$blocked_version" --arg immutableVersion "$immutable_version" \
  --argjson blockedId "$blocked_id" --argjson immutableId "$immutable_id" \
  --argjson blocked "$blocked" --argjson immutable "$immutable" \
  '{
    schema:$schema, repository:$repository, image:$image,
    objects:{
      blockedV1_1_0:{identity:{releaseId:$blockedId,version:$blockedVersion,tag:"v"+$blockedVersion},
        release:{draft:$blocked.draft,prerelease:$blocked.prerelease,immutable:($blocked.immutable // false),
          targetCommitish:$blocked.target_commitish,publishedAt:$blocked.published_at},
        assets:[$blocked.assets[]? | {name,id,size,label:(.label // null),digest:(.digest // null)}]},
      immutableV1_0_1:{identity:{releaseId:$immutableId,version:$immutableVersion,tag:"v"+$immutableVersion},
        release:{draft:$immutable.draft,prerelease:$immutable.prerelease,immutable:($immutable.immutable // false),
          targetCommitish:$immutable.target_commitish,publishedAt:$immutable.published_at},
        assets:[$immutable.assets[]? | {name,id,size,label:(.label // null),digest:(.digest // null)}]}
    }
  }' >"$output" || fail "snapshot normalization failed"
