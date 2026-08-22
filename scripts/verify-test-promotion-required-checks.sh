#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --repository OWNER/REPO --source-sha SHA --output PATH" >&2
  exit 2
}

fail() {
  echo "test promotion required-check verification failed: $*" >&2
  exit 1
}

repository=
source_sha=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] && [ -z "$repository" ] || usage; repository=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] && [ -z "$source_sha" ] || usage; source_sha=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || usage
[ -n "$output" ] && [ -d "$(dirname -- "$output")" ] || usage
[ ! -L "$output" ] || fail "output path is unsafe"
command -v gh >/dev/null 2>&1 || fail "gh is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
: "${GH_TOKEN:?GH_TOKEN is required}"

required_jobs_json='[
  "Validate reusable call",
  "Gradle tests and build",
  "PostgreSQL tests",
  "Compose, Bash, and ShellCheck",
  "Docker image verification"
]'

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM

gh api --paginate --slurp \
  "repos/$repository/actions/workflows/ci.yml/runs?head_sha=$source_sha&per_page=100" \
  >"$tmp/runs.json" || fail "CI run lookup failed"
jq -e 'type == "array" and all(.[]; type == "array")' "$tmp/runs.json" >/dev/null ||
  fail "CI run response is malformed"

selected=
while IFS= read -r run_id; do
  jobs="$tmp/jobs-$run_id.json"
  gh api --paginate --slurp "repos/$repository/actions/runs/$run_id/jobs?per_page=100" \
    >"$jobs" || fail "CI job lookup failed for run $run_id"
  if jq -e --argjson required "$required_jobs_json" '
    [add // [] | .[]] as $jobs |
    ($jobs | length > 0) and
    (all($jobs[]; .conclusion == "success")) and
    (all($required[] as $requiredJob;
      any($jobs[]; .name == $requiredJob and .conclusion == "success")))
  ' "$jobs" >/dev/null 2>&1; then
    selected=$run_id
    break
  fi
done < <(
  jq -r '[add // [] | .[] |
    select(.head_sha == "'"$source_sha"'" and .status == "completed" and .conclusion == "success") |
    .id] | unique[]' "$tmp/runs.json"
)

[ -n "$selected" ] || fail "no exact-SHA CI run satisfies the required-job allowlist"
jobs_file="$tmp/jobs-$selected.json"
jq -cnS --arg sourceSha "$source_sha" --arg runId "$selected" \
  --argjson required "$required_jobs_json" \
  --slurpfile jobs "$jobs_file" '
  {
    schema:"meet-backend/test-promotion-required-checks/v1",
    workflow:"ci.yml",
    sourceSha:$sourceSha,
    runId:($runId | tonumber),
    requiredJobs:$required,
    verifiedJobs:($jobs[0] | add // [] | map(.name) | unique | sort),
    exactSha:true,
    allRequiredChecksSuccessful:true
  }
' >"$output" || fail "required-check proof construction failed"
chmod 600 "$output" 2>/dev/null || true
