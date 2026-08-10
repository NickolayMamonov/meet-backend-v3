#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --repository owner/repo --pr NUMBER [--output PATH] [--pull-file PATH] [--reviewers-file PATH]" >&2
  exit 2
}

fail() {
  echo "release PR fingerprint capture failed: $*" >&2
  exit 1
}

REPOSITORY=
PR=
OUTPUT=
PULL_FILE=
REVIEWERS_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] || usage; REPOSITORY=$2; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; PR=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; OUTPUT=$2; shift 2 ;;
    --pull-file) [ "$#" -ge 2 ] || usage; PULL_FILE=$2; shift 2 ;;
    --reviewers-file) [ "$#" -ge 2 ] || usage; REVIEWERS_FILE=$2; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
[[ "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]] || usage
[[ "$PR" =~ ^[1-9][0-9]*$ ]] || usage

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM
if [ -n "$PULL_FILE" ]; then
  pull=$PULL_FILE
else
  command -v gh >/dev/null 2>&1 || fail "gh is required"
  pull=$tmp/pull.json
  gh api "repos/$REPOSITORY/pulls/$PR" >"$pull" 2>/dev/null ||
    fail "pull request lookup failed"
fi

if [ -n "$REVIEWERS_FILE" ]; then
  reviewers=$REVIEWERS_FILE
else
  reviewers=$tmp/reviewers.json
  gh api "repos/$REPOSITORY/pulls/$PR/requested_reviewers" \
    >"$reviewers" 2>/dev/null || fail "reviewer lookup failed"
fi

title_hash=$(jq -r '.title // empty' "$pull" | sha256sum | awk '{print $1}')
body_hash=$(jq -r '.body // ""' "$pull" | sha256sum | awk '{print $1}')
snapshot=$(jq -S -n \
  --argjson number "$(jq -r '.number' "$pull")" \
  --arg head_sha "$(jq -r '.head.sha' "$pull")" \
  --arg head_ref "$(jq -r '.head.ref' "$pull")" \
  --arg base_ref "$(jq -r '.base.ref' "$pull")" \
  --arg state "$(jq -r '.state' "$pull")" \
  --argjson draft "$(jq -r '.draft // false' "$pull")" \
  --arg title_hash "$title_hash" \
  --arg body_hash "$body_hash" \
  --argjson labels "$(jq -c '[.labels[]?.name] | sort' "$pull")" \
  --argjson assignees "$(jq -c '[.assignees[]?.login] | sort' "$pull")" \
  --argjson reviewers "$(jq -c '[
    (.users[]?.login | {kind:"user", value:.}),
    (.teams[]?.slug | {kind:"team", value:.})
  ] | sort_by(.kind, .value)' "$reviewers")" \
  --argjson milestone "$(jq -c 'if .milestone == null then null else
    {number:.milestone.number, title:.milestone.title} end' "$pull")" \
  '{
    number: $number,
    head: {sha: $head_sha, ref: $head_ref},
    base_ref: $base_ref,
    state: $state,
    draft: $draft,
    title_sha256: $title_hash,
    body_sha256: $body_hash,
    labels: $labels,
    assignees: $assignees,
    requested_reviewers: $reviewers,
    milestone: $milestone
  }')

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$snapshot" >"$OUTPUT"
else
  printf '%s\n' "$snapshot"
fi
