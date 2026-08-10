#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER="$ROOT_DIR/scripts/resolve-release-descriptor.sh"
FIXTURES="$ROOT_DIR/scripts/fixtures/release-descriptor/scenarios.json"
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT
export GIT_AUTHOR_NAME='Resolver Fixture'
export GIT_AUTHOR_EMAIL='resolver@example.invalid'
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

pass=0
failures=0

make_commit() {
  local repo=$1 version=$2 mode=${3:-both}
  if [ "$mode" = both ] || [ "$mode" = manifest ]; then
    printf '{".":"%s"}\n' "$version" >"$repo/.release-please-manifest.json"
  fi
  if [ "$mode" = both ] || [ "$mode" = version ]; then
    printf '{"version":"%s"}\n' "$version" >"$repo/version.json"
  fi
  git -C "$repo" add .release-please-manifest.json version.json 2>/dev/null || true
  git -C "$repo" commit -qm "$version-$mode"
}

make_valid_repo() {
  local repo=$1
  git init -q "$repo"
  git -C "$repo" config core.autocrlf false
  make_commit "$repo" 1.0.0
  OLD=$(git -C "$repo" rev-parse HEAD)
  make_commit "$repo" 1.0.1
  SOURCE=$(git -C "$repo" rev-parse HEAD)
  echo fixture >"$repo/unrelated.txt"
  git -C "$repo" add unrelated.txt
  git -C "$repo" commit -qm post-boundary
  TIP=$(git -C "$repo" rev-parse HEAD)
}

materialize() {
  local key=$1 output=$2
  jq --arg source "$SOURCE" --arg old "$OLD" --arg tip "$TIP" '
    .[$key] | walk(
      if type == "string" then
        gsub("@SOURCE@"; $source) | gsub("@OLD@"; $old) | gsub("@TIP@"; $tip)
      else . end
    )
  ' --arg key "$key" "$FIXTURES" >"$output"
}

refs_absent() {
  printf '{"refs":{},"tags":{}}\n' >"$1"
}

refs_matching() {
  jq -n --arg sha "$SOURCE" \
    '{refs:{"v1.0.1":{type:"commit",sha:$sha}},tags:{}}' >"$1"
}

refs_conflicting() {
  jq -n --arg sha "$OLD" \
    '{refs:{"v1.0.1":{type:"commit",sha:$sha}},tags:{}}' >"$1"
}

make_array() {
  local output=$1
  shift
  jq -s '.' "$@" >"$output"
}

expect_success() {
  local name=$1 pattern=$2
  shift 2
  if output=$("$@" 2>"$TMP/error"); then
    if grep -Eq "$pattern" <<<"$output"; then
      echo "ok - $name"
      pass=$((pass + 1))
    else
      echo "not ok - $name (unexpected output)" >&2
      echo "$output" >&2
      failures=$((failures + 1))
    fi
  else
    echo "not ok - $name" >&2
    sed 's/^/  /' "$TMP/error" >&2
    failures=$((failures + 1))
  fi
}

expect_failure() {
  local name=$1
  shift
  if output=$("$@" 2>"$TMP/error"); then
    echo "not ok - $name (unexpected success)" >&2
    echo "$output" >&2
    failures=$((failures + 1))
  elif [ -n "$output" ]; then
    echo "not ok - $name (failure emitted a partial descriptor)" >&2
    echo "$output" >&2
    failures=$((failures + 1))
  else
    echo "ok - $name"
    pass=$((pass + 1))
  fi
}

BASE="$TMP/base"
make_valid_repo "$BASE"
EMPTY="$TMP/empty.json"
COMPLETE="$TMP/complete.json"
OLD_RELEASE="$TMP/old.json"
WRONG="$TMP/wrong.json"
FUTURE="$TMP/future.json"
PARTIAL="$TMP/partial.json"
FOREIGN="$TMP/foreign.json"
NON_DRAFT="$TMP/non-draft.json"
PUBLISHED_WRONG="$TMP/published-wrong.json"
PUBLISHED_FUTURE="$TMP/published-future.json"
DRIFT_TAG="$TMP/drift-tag.json"
DRIFT_TARGET="$TMP/drift-target.json"
DRIFT_PUBLISHED="$TMP/drift-published.json"
DRIFT_ID="$TMP/drift-id.json"
materialize emptyCurrent "$EMPTY"
materialize completeCurrent "$COMPLETE"
materialize oldReachable "$OLD_RELEASE"
materialize wrongSourceCurrentTag "$WRONG"
materialize future "$FUTURE"
materialize partialAssets "$PARTIAL"
materialize foreignAssets "$FOREIGN"
materialize unpublishedNonDraft "$NON_DRAFT"
materialize publishedWrongSourceCurrent "$PUBLISHED_WRONG"
materialize publishedFuture "$PUBLISHED_FUTURE"
materialize driftTag "$DRIFT_TAG"
materialize driftTarget "$DRIFT_TARGET"
materialize driftPublishedState "$DRIFT_PUBLISHED"
materialize driftReleaseId "$DRIFT_ID"
ABSENT="$TMP/refs-absent.json"
MATCHING="$TMP/refs-matching.json"
CONFLICTING="$TMP/refs-conflicting.json"
refs_absent "$ABSENT"
refs_matching "$MATCHING"
refs_conflicting "$CONFLICTING"
EMPTY_ARRAY="$TMP/empty-array.json"
COMPLETE_ARRAY="$TMP/complete-array.json"
OLD_ARRAY="$TMP/old-array.json"
OLD_CURRENT_ARRAY="$TMP/old-current-array.json"
WRONG_ARRAY="$TMP/wrong-array.json"
FUTURE_ARRAY="$TMP/future-array.json"
DUPLICATE_ARRAY="$TMP/duplicate-array.json"
PARTIAL_ARRAY="$TMP/partial-array.json"
FOREIGN_ARRAY="$TMP/foreign-array.json"
NON_DRAFT_ARRAY="$TMP/non-draft-array.json"
PUBLISHED_WRONG_ARRAY="$TMP/published-wrong-array.json"
PUBLISHED_FUTURE_ARRAY="$TMP/published-future-array.json"
PUBLISHED_EXACT="$TMP/published-exact.json"
PUBLISHED_EXACT_ARRAY="$TMP/published-exact-array.json"
make_array "$EMPTY_ARRAY" "$EMPTY"
make_array "$COMPLETE_ARRAY" "$COMPLETE"
make_array "$OLD_ARRAY" "$OLD_RELEASE"
make_array "$OLD_CURRENT_ARRAY" "$OLD_RELEASE" "$EMPTY"
make_array "$WRONG_ARRAY" "$WRONG"
make_array "$FUTURE_ARRAY" "$FUTURE"
make_array "$DUPLICATE_ARRAY" "$EMPTY" "$EMPTY"
make_array "$PARTIAL_ARRAY" "$PARTIAL"
make_array "$FOREIGN_ARRAY" "$FOREIGN"
make_array "$NON_DRAFT_ARRAY" "$NON_DRAFT"
make_array "$PUBLISHED_WRONG_ARRAY" "$PUBLISHED_WRONG"
make_array "$PUBLISHED_FUTURE_ARRAY" "$PUBLISHED_FUTURE"
jq '.draft = false | .published_at = "2026-08-10T02:00:00Z"' \
  "$COMPLETE" >"$PUBLISHED_EXACT"
make_array "$PUBLISHED_EXACT_ARRAY" "$PUBLISHED_EXACT"

common=(--repo-dir "$BASE" --dev-ref HEAD --refs-file "$ABSENT")
expect_success "created draft without materialized tag" \
  '^origin=created$' "$RESOLVER" created \
  --release-id 101 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --release-file "$EMPTY" "${common[@]}"

expect_success "recovered empty draft" \
  '^asset_inventory_kind=empty$' "$RESOLVER" recover \
  --releases-file "$EMPTY_ARRAY" "${common[@]}"

COMPLETE_RECOVERY_OUTPUT=$("$RESOLVER" recover \
  --releases-file "$COMPLETE_ARRAY" "${common[@]}")
if grep -Fx 'asset_inventory_kind=complete_unverified' \
    <<<"$COMPLETE_RECOVERY_OUTPUT" >/dev/null &&
   ! grep -Eq '(^|_)(resume|resume_ready|resume_admission)=' \
    <<<"$COMPLETE_RECOVERY_OUTPUT"; then
  echo "ok - recovered complete metadata remains unverified"
  pass=$((pass + 1))
else
  echo "not ok - metadata-only resolver claimed deep resume" >&2
  failures=$((failures + 1))
fi

expect_success "old reachable draft is unrelated no-op" \
  '^active=false$' "$RESOLVER" recover \
  --releases-file "$OLD_ARRAY" "${common[@]}"

expect_success "old reachable plus current selects current" \
  '^release_id=101$' "$RESOLVER" recover \
  --releases-file "$OLD_CURRENT_ARRAY" "${common[@]}"

expect_success "source-identical existing tag is accepted" \
  '^release_id=101$' "$RESOLVER" recover \
  --releases-file "$EMPTY_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"

expect_failure "current tag with wrong source is relevant" "$RESOLVER" recover \
  --releases-file "$WRONG_ARRAY" "${common[@]}"
expect_failure "future canonical draft is relevant" "$RESOLVER" recover \
  --releases-file "$FUTURE_ARRAY" "${common[@]}"
expect_failure "duplicate current drafts are ambiguous" "$RESOLVER" recover \
  --releases-file "$DUPLICATE_ARRAY" "${common[@]}"
expect_failure "conflicting materialized tag fails closed" "$RESOLVER" recover \
  --releases-file "$EMPTY_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$CONFLICTING"
expect_failure "partial asset inventory fails closed" "$RESOLVER" recover \
  --releases-file "$PARTIAL_ARRAY" "${common[@]}"
expect_failure "foreign asset inventory fails closed" "$RESOLVER" recover \
  --releases-file "$FOREIGN_ARRAY" "${common[@]}"
expect_failure "current unpublished non-draft fails closed" "$RESOLVER" recover \
  --releases-file "$NON_DRAFT_ARRAY" "${common[@]}"
expect_failure "published current tag with wrong source fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_WRONG_ARRAY" "${common[@]}"
expect_failure "published future release fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_FUTURE_ARRAY" "${common[@]}"
expect_success "exact published authority tuple is a completed no-op" \
  '^origin=completed$' "$RESOLVER" recover \
  --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"

NO_CANDIDATES="$TMP/no-candidates.json"
printf '[]\n' >"$NO_CANDIDATES"
expect_success "zero candidates is an unrelated no-op" \
  '^active=false$' "$RESOLVER" recover \
  --releases-file "$NO_CANDIDATES" "${common[@]}"

CREATED_OUTPUT=$("$RESOLVER" created \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --release-file "$COMPLETE" "${common[@]}")
FINGERPRINT=$(awk -F= '$1 == "asset_inventory_fingerprint" {print $2}' \
  <<<"$CREATED_OUTPUT")
expect_success "unchanged descriptor verifies" '^origin=verified$' \
  "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --release-file "$COMPLETE" "${common[@]}"
expect_failure "descriptor asset drift fails closed" "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$(printf '0%.0s' {1..64})" \
  --release-file "$COMPLETE" "${common[@]}"
expect_failure "descriptor tag drift fails closed" "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --release-file "$DRIFT_TAG" "${common[@]}"
expect_failure "descriptor target drift fails closed" "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --release-file "$DRIFT_TARGET" "${common[@]}"
expect_failure "descriptor draft/publication drift fails closed" "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --release-file "$DRIFT_PUBLISHED" "${common[@]}"
expect_failure "descriptor release ID drift fails closed" "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --release-file "$DRIFT_ID" "${common[@]}"

DISAGREE="$TMP/disagree"
cp -R "$BASE" "$DISAGREE"
printf '{"version":"1.0.2"}\n' >"$DISAGREE/version.json"
git -C "$DISAGREE" add version.json
git -C "$DISAGREE" commit -qm disagreement
expect_failure "tip authority disagreement fails globally" "$RESOLVER" recover \
  --releases-file "$NO_CANDIDATES" \
  --repo-dir "$DISAGREE" --dev-ref HEAD --refs-file "$ABSENT"

MISSING_CHANGE="$TMP/missing-change"
git init -q "$MISSING_CHANGE"
git -C "$MISSING_CHANGE" config core.autocrlf false
make_commit "$MISSING_CHANGE" 1.0.0
make_commit "$MISSING_CHANGE" 1.0.1 manifest
make_commit "$MISSING_CHANGE" 1.0.1 version
expect_failure "boundary must change both authority files" "$RESOLVER" recover \
  --releases-file "$NO_CANDIDATES" \
  --repo-dir "$MISSING_CHANGE" --dev-ref HEAD --refs-file "$ABSENT"

AMBIGUOUS="$TMP/ambiguous"
git init -q "$AMBIGUOUS"
git -C "$AMBIGUOUS" config core.autocrlf false
make_commit "$AMBIGUOUS" 1.0.0
make_commit "$AMBIGUOUS" 1.0.1
make_commit "$AMBIGUOUS" 1.0.0
make_commit "$AMBIGUOUS" 1.0.1
expect_failure "repeated authority boundary is ambiguous drift" "$RESOLVER" recover \
  --releases-file "$NO_CANDIDATES" \
  --repo-dir "$AMBIGUOUS" --dev-ref HEAD --refs-file "$ABSENT"

POST_DRIFT="$TMP/post-drift"
git init -q "$POST_DRIFT"
git -C "$POST_DRIFT" config core.autocrlf false
make_commit "$POST_DRIFT" 1.0.0
make_commit "$POST_DRIFT" 1.0.1
make_commit "$POST_DRIFT" 1.0.2 manifest
make_commit "$POST_DRIFT" 1.0.1 manifest
expect_failure "post-boundary authority drift fails closed" "$RESOLVER" recover \
  --releases-file "$NO_CANDIDATES" \
  --repo-dir "$POST_DRIFT" --dev-ref HEAD --refs-file "$ABSENT"

echo "$pass resolver fixture checks passed"
[ "$failures" -eq 0 ] || {
  echo "$failures resolver fixture checks failed" >&2
  exit 1
}
