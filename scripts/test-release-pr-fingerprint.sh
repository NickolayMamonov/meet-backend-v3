#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CAPTURE=$ROOT_DIR/scripts/capture-release-pr-fingerprint.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

jq -n '{
  number: 28,
  title: "chore(dev): release 1.0.2",
  body: "release body must never be emitted",
  state: "open",
  draft: false,
  head: {sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",ref:"release-please--dev"},
  base: {ref:"dev"},
  labels: [{name:"autorelease: pending"}],
  assignees: [],
  milestone: null,
  updated_at: "2026-08-10T01:00:00Z",
  mergeable_state: "unknown"
}' >"$TMP/pull.json"
jq -n '{
  users: [{login:"reviewer"}],
  teams: [{slug:"release-team"}]
}' >"$TMP/reviewers.json"

"$CAPTURE" --repository fixture/repository --pr 28 \
  --pull-file "$TMP/pull.json" \
  --reviewers-file "$TMP/reviewers.json" \
  --output "$TMP/before.json"
jq '.updated_at = "2026-08-10T02:00:00Z" |
    .mergeable_state = "clean" |
    .comments = 17' "$TMP/pull.json" >"$TMP/pull-after.json"
"$CAPTURE" --repository fixture/repository --pr 28 \
  --pull-file "$TMP/pull-after.json" \
  --reviewers-file "$TMP/reviewers.json" \
  --output "$TMP/after.json"
cmp "$TMP/before.json" "$TMP/after.json"
jq -e '
  .number == 28 and
  .base_ref == "dev" and
  .head.ref == "release-please--dev" and
  (.requested_reviewers | length) == 2 and
  (has("body") | not) and
  (has("title") | not)
' "$TMP/before.json" >/dev/null
echo "release PR fingerprint fixtures passed: stable sanitized before/after equality"
