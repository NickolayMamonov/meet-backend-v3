#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 --sha SHA --output PATH" >&2; exit 2; }
sha='' output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha) [ "$#" -ge 2 ] || usage; sha=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$output" = /* && "$output" != *..* ]] || usage
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
command -v curl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
api=${GITHUB_API_URL:-https://api.github.com}
tmp=$(mktemp)
trap 'rm -f -- "$tmp" "$tmp.error"' EXIT
curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$api/repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$sha&branch=dev&event=push&per_page=100" \
  >"$tmp" 2>"$tmp.error" ||
  { echo 'BACKUP_CUSTODY_BLOCKED:ci_unavailable' >&2; exit 1; }
jq -e --arg sha "$sha" --arg repo "$GITHUB_REPOSITORY" '
  .workflow_runs
  | map(select(.path==".github/workflows/ci.yml" and .head_sha==$sha and
      .head_branch=="dev" and .status=="completed" and .conclusion=="success" and
      .head_repository.full_name==$repo))
  | sort_by(.run_number) | last
  | {conclusion:.conclusion,ref:"refs/heads/dev",sha:$sha,
     sourceSha:.head_sha,workflowPath:.path}
' "$tmp" >"$output" || { echo 'BACKUP_CUSTODY_BLOCKED:ci_provenance' >&2; exit 1; }
[ "$(wc -c <"$output")" -le 65536 ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:ci_evidence_oversize' >&2
  exit 1
}
chmod 600 "$output"
