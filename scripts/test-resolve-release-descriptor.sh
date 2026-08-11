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

refs_missing_peeled_object() {
  jq -n \
    '{refs:{"v1.0.1":{type:"tag",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},tags:{}}' \
    >"$1"
}

refs_malformed_object() {
  jq -n \
    '{refs:{"v1.0.1":{type:"commit",sha:"not-a-sha"}},tags:{}}' >"$1"
}

refs_unsupported_object() {
  jq -n \
    '{refs:{"v1.0.1":{type:"tree",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},tags:{}}' \
    >"$1"
}

refs_divergent_peeled_object() {
  jq -n --arg old "$OLD" \
    '{refs:{"v1.0.1":{type:"tag",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
      tags:{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{type:"commit",sha:$old}}}' \
    >"$1"
}

refs_malformed_peeled_object() {
  jq -n \
    '{refs:{"v1.0.1":{type:"tag",sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
      tags:{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{type:"commit",sha:"not-a-sha"}}}' \
    >"$1"
}

refs_overdeep_peeled_object() {
  local output=$1 index sha next
  sha=$(printf 'a%.0s' {1..40})
  printf '{"refs":{"v1.0.1":{"type":"tag","sha":"%s"}},"tags":{' "$sha" >"$output"
  for index in $(seq 1 18); do
    next=$(printf '%s' "$index" | awk '{printf "%040d", $1}')
    if [ "$index" -eq 18 ]; then
      printf '"%s":{"type":"commit","sha":"%s"}' "$sha" "$SOURCE" >>"$output"
    else
      printf '"%s":{"type":"tag","sha":"%s"},' "$sha" "$next" >>"$output"
    fi
    sha=$next
  done
  printf '}}\n' >>"$output"
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
POST_ACTION="$TMP/post-action.json"
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
materialize postActionCurrent "$POST_ACTION"
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
POST_ACTION_ARRAY="$TMP/post-action-array.json"
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
PUBLISHED_EMPTY_ASSETS="$TMP/published-empty-assets.json"
PUBLISHED_MALFORMED_ASSETS="$TMP/published-malformed-assets.json"
PUBLISHED_WRONG_ASSETS="$TMP/published-wrong-assets.json"
PUBLISHED_DUPLICATE_ASSETS="$TMP/published-duplicate-assets.json"
make_array "$EMPTY_ARRAY" "$EMPTY"
make_array "$COMPLETE_ARRAY" "$COMPLETE"
make_array "$POST_ACTION_ARRAY" "$POST_ACTION"
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
materialize publishedExactCurrent "$PUBLISHED_EXACT"
make_array "$PUBLISHED_EXACT_ARRAY" "$PUBLISHED_EXACT"
jq '.assets = []' "$PUBLISHED_EXACT" >"$PUBLISHED_EMPTY_ASSETS"
jq '.assets = {}' "$PUBLISHED_EXACT" >"$PUBLISHED_MALFORMED_ASSETS"
jq '.assets[0].state = "new"' "$PUBLISHED_EXACT" >"$PUBLISHED_WRONG_ASSETS"
jq '.assets[1].id = .assets[0].id' "$PUBLISHED_EXACT" \
  >"$PUBLISHED_DUPLICATE_ASSETS"

REFS_MISSING_PEELED="$TMP/refs-missing-peeled.json"
REFS_MALFORMED="$TMP/refs-malformed.json"
REFS_UNSUPPORTED="$TMP/refs-unsupported.json"
REFS_DIVERGENT_PEELED="$TMP/refs-divergent-peeled.json"
REFS_MALFORMED_PEELED="$TMP/refs-malformed-peeled.json"
REFS_OVERDEEP="$TMP/refs-overdeep.json"
refs_missing_peeled_object "$REFS_MISSING_PEELED"
refs_malformed_object "$REFS_MALFORMED"
refs_unsupported_object "$REFS_UNSUPPORTED"
refs_divergent_peeled_object "$REFS_DIVERGENT_PEELED"
refs_malformed_peeled_object "$REFS_MALFORMED_PEELED"
refs_overdeep_peeled_object "$REFS_OVERDEEP"
NO_CANDIDATES="$TMP/no-candidates.json"
printf '[]\n' >"$NO_CANDIDATES"

common=(--repo-dir "$BASE" --dev-ref HEAD --refs-file "$ABSENT")
expect_success "created draft without materialized tag" \
  '^origin=created$' "$RESOLVER" created \
  --release-id 101 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --release-file "$EMPTY" "${common[@]}"

POST_ACTION_OUTPUT=$("$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}")
if grep -Fx 'active=true' <<<"$POST_ACTION_OUTPUT" >/dev/null &&
   grep -Fx 'origin=post_action' <<<"$POST_ACTION_OUTPUT" >/dev/null &&
   grep -Fx 'route=materialize' <<<"$POST_ACTION_OUTPUT" >/dev/null &&
   grep -Fx 'release_id=111' <<<"$POST_ACTION_OUTPUT" >/dev/null &&
   grep -Fx "source_sha=$SOURCE" <<<"$POST_ACTION_OUTPUT" >/dev/null &&
   grep -Eq '^admission_fingerprint=[0-9a-f]{64}$' \
     <<<"$POST_ACTION_OUTPUT"; then
  echo "ok - post-action resolves one exact materialize admission"
  pass=$((pass + 1))
else
  echo "not ok - post-action did not emit the bound active descriptor" >&2
  echo "$POST_ACTION_OUTPUT" >&2
  failures=$((failures + 1))
fi
POST_ACTION_ADMISSION_FINGERPRINT=$(awk -F= \
  '$1 == "admission_fingerprint" {print $2}' <<<"$POST_ACTION_OUTPUT")
PRE_ACTION_OUTPUT=$("$RESOLVER" pre-action \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}")
PRE_ACTION_ADMISSION_FINGERPRINT=$(awk -F= \
  '$1 == "admission_fingerprint" {print $2}' <<<"$PRE_ACTION_OUTPUT")
if grep -Fx 'route=materialize' <<<"$PRE_ACTION_OUTPUT" >/dev/null &&
   [ "$PRE_ACTION_ADMISSION_FINGERPRINT" = \
     "$POST_ACTION_ADMISSION_FINGERPRINT" ] &&
   ! grep -Fx 'origin=post_action' <<<"$PRE_ACTION_OUTPUT" >/dev/null; then
  echo "ok - post-action to pre-action binding excludes diagnostic origin"
  pass=$((pass + 1))
else
  echo "not ok - post-action to pre-action binding drifted" >&2
  failures=$((failures + 1))
fi
PRE_ACTION_CONTINUATION_OUTPUT=$("$RESOLVER" pre-action \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}")
if [ "$(awk -F= '$1 == "admission_fingerprint" {print $2}' \
    <<<"$PRE_ACTION_CONTINUATION_OUTPUT")" = \
   "$PRE_ACTION_ADMISSION_FINGERPRINT" ]; then
  echo "ok - pre-action continuation binding is stable"
  pass=$((pass + 1))
else
  echo "not ok - pre-action continuation binding drifted" >&2
  failures=$((failures + 1))
fi

expect_failure "post-action rejects release ID input" "$RESOLVER" post-action \
  --release-id 111 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}"
expect_failure "post-action rejects release file input" "$RESOLVER" post-action \
  --release-file "$POST_ACTION" \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}"
expect_failure "post-action rejects noncanonical action tuple" "$RESOLVER" post-action \
  --tag v01.0.1 --version 01.0.1 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}"
expect_failure "post-action rejects action tuple source mismatch" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$OLD" \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}"
expect_failure "post-action rejects action tuple tag mismatch" "$RESOLVER" post-action \
  --tag v1.0.2 --version 1.0.2 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" "${common[@]}"
expect_success "post-action accepts source-identical materialized tag" \
  '^origin=post_action$' "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
expect_failure "post-action zero candidates fails closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$NO_CANDIDATES" "${common[@]}"
expect_failure "post-action duplicate drafts fail closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$DUPLICATE_ARRAY" "${common[@]}"
expect_failure "post-action wrong-source draft fails closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$WRONG_ARRAY" "${common[@]}"
expect_failure "post-action future conflict fails closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$FUTURE_ARRAY" "${common[@]}"
expect_failure "post-action non-draft state fails closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$NON_DRAFT_ARRAY" "${common[@]}"
expect_failure "post-action published state fails closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$PUBLISHED_EXACT_ARRAY" "${common[@]}"
expect_failure "post-action partial assets fail closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$PARTIAL_ARRAY" "${common[@]}"
expect_failure "post-action foreign assets fail closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$FOREIGN_ARRAY" "${common[@]}"
expect_failure "post-action conflicting peeled ref fails closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$CONFLICTING"
expect_failure "post-action malformed peeled ref fails closed" "$RESOLVER" post-action \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --releases-file "$POST_ACTION_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$REFS_MALFORMED"

POST_ACTION_LIVE="$TMP/post-action-pages.json"
mkdir "$TMP/post-action-bin"
jq -n --slurpfile current "$POST_ACTION" --slurpfile old "$OLD_RELEASE" \
  '[[$current[0]],[$old[0]]]' >"$POST_ACTION_LIVE"
cat >"$TMP/post-action-bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
endpoint=${!#}
case "$endpoint" in
  repos/fixture/repository/releases*) cat "$POST_ACTION_LIVE" ;;
  *) echo "unexpected post-action API endpoint: $endpoint" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/post-action-bin/gh"
export POST_ACTION_LIVE
expect_success "post-action enumerates every live page" \
  '^origin=post_action$' env PATH="$TMP/post-action-bin:$PATH" \
  "$RESOLVER" post-action \
  --repository fixture/repository \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$ABSENT"
printf '[null]\n' >"$POST_ACTION_LIVE"
expect_failure "post-action malformed page fails closed" env \
  PATH="$TMP/post-action-bin:$PATH" "$RESOLVER" post-action \
  --repository fixture/repository \
  --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$ABSENT"

expect_success "recovered empty draft" \
  '^asset_inventory_kind=empty$' "$RESOLVER" recover \
  --releases-file "$EMPTY_ARRAY" "${common[@]}"
RECOVERED_FALSE_OUTPUT=$("$RESOLVER" recover \
  --releases-file "$EMPTY_ARRAY" "${common[@]}")
if grep -Fx 'active=true' <<<"$RECOVERED_FALSE_OUTPUT" >/dev/null &&
   grep -Fx 'origin=recovered' <<<"$RECOVERED_FALSE_OUTPUT" >/dev/null &&
   grep -Fx 'release_id=101' <<<"$RECOVERED_FALSE_OUTPUT" >/dev/null &&
   grep -Fx "tag=v1.0.1" <<<"$RECOVERED_FALSE_OUTPUT" >/dev/null &&
   grep -Fx "version=1.0.1" <<<"$RECOVERED_FALSE_OUTPUT" >/dev/null &&
   grep -Fx "source_sha=$SOURCE" <<<"$RECOVERED_FALSE_OUTPUT" >/dev/null; then
  echo "ok - false-branch active recovery shape is exact"
  pass=$((pass + 1))
else
  echo "not ok - false-branch active recovery shape drifted" >&2
  echo "$RECOVERED_FALSE_OUTPUT" >&2
  failures=$((failures + 1))
fi

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
expect_failure "published predecessor missing peeled ref fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$REFS_MISSING_PEELED"
expect_failure "published predecessor divergent peeled ref fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$REFS_DIVERGENT_PEELED"
expect_failure "published predecessor malformed ref fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$REFS_MALFORMED"
expect_failure "published predecessor unsupported ref fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$REFS_UNSUPPORTED"
expect_failure "published predecessor malformed peeled ref fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$REFS_MALFORMED_PEELED"
expect_failure "published predecessor overdeep peeled ref fails closed" \
  "$RESOLVER" recover --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$REFS_OVERDEEP"
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
for publication_case in \
  id-string id-null id-array \
  tag-number tag-null tag-array \
  target-number target-null target-array \
  draft-string draft-number draft-null draft-array \
  prerelease-string prerelease-number prerelease-null prerelease-array \
  published-number published-boolean published-null published-array \
  published-object published-empty published-missing; do
  case "$publication_case" in
    id-string) mutation='.id = "108"' ;;
    id-null) mutation='.id = null' ;;
    id-array) mutation='.id = []' ;;
    tag-number) mutation='.tag_name = 108' ;;
    tag-null) mutation='.tag_name = null' ;;
    tag-array) mutation='.tag_name = []' ;;
    target-number) mutation='.target_commitish = 108' ;;
    target-null) mutation='.target_commitish = null' ;;
    target-array) mutation='.target_commitish = []' ;;
    draft-string) mutation='.draft = "false"' ;;
    draft-number) mutation='.draft = 0' ;;
    draft-null) mutation='.draft = null' ;;
    draft-array) mutation='.draft = []' ;;
    prerelease-string) mutation='.prerelease = "false"' ;;
    prerelease-number) mutation='.prerelease = 0' ;;
    prerelease-null) mutation='.prerelease = null' ;;
    prerelease-array) mutation='.prerelease = []' ;;
    published-number) mutation='.published_at = 1700000000' ;;
    published-boolean) mutation='.published_at = false' ;;
    published-null) mutation='.published_at = null' ;;
    published-array) mutation='.published_at = []' ;;
    published-object) mutation='.published_at = {}' ;;
    published-empty) mutation='.published_at = ""' ;;
    published-missing) mutation='del(.published_at)' ;;
  esac
  mutated="$TMP/published-$publication_case.json"
  mutated_array="$TMP/published-$publication_case-array.json"
  jq "$mutation" "$PUBLISHED_EXACT" >"$mutated"
  make_array "$mutated_array" "$mutated"
  expect_failure "published wrong-type $publication_case fails closed" \
    "$RESOLVER" recover --releases-file "$mutated_array" \
    --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
done
make_array "$TMP/published-empty-assets-array.json" "$PUBLISHED_EMPTY_ASSETS"
make_array "$TMP/published-malformed-assets-array.json" "$PUBLISHED_MALFORMED_ASSETS"
make_array "$TMP/published-wrong-assets-array.json" "$PUBLISHED_WRONG_ASSETS"
make_array "$TMP/published-duplicate-assets-array.json" "$PUBLISHED_DUPLICATE_ASSETS"
expect_failure "published empty assets fail closed" "$RESOLVER" recover \
  --releases-file "$TMP/published-empty-assets-array.json" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
expect_failure "published malformed assets fail closed" "$RESOLVER" recover \
  --releases-file "$TMP/published-malformed-assets-array.json" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
expect_failure "published wrong assets fail closed" "$RESOLVER" recover \
  --releases-file "$TMP/published-wrong-assets-array.json" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
expect_failure "published duplicate assets fail closed" "$RESOLVER" recover \
  --releases-file "$TMP/published-duplicate-assets-array.json" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
make_array "$TMP/duplicate-completed-array.json" \
  "$PUBLISHED_EXACT" "$PUBLISHED_EXACT"
make_array "$TMP/canonical-active-completed-array.json" \
  "$COMPLETE" "$PUBLISHED_EXACT"
PLACEHOLDER="$TMP/placeholder.json"
jq '.tag_name = "untagged-0123456789abcdef0123"' "$EMPTY" >"$PLACEHOLDER"
make_array "$TMP/placeholder-active-completed-array.json" \
  "$PLACEHOLDER" "$PUBLISHED_EXACT"
expect_failure "duplicate completed predecessors fail closed" "$RESOLVER" recover \
  --releases-file "$TMP/duplicate-completed-array.json" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
expect_failure "canonical active plus completed fails closed" "$RESOLVER" recover \
  --releases-file "$TMP/canonical-active-completed-array.json" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
expect_failure "placeholder active plus completed fails closed" "$RESOLVER" recover \
  --releases-file "$TMP/placeholder-active-completed-array.json" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING"
COMPLETED_CONTROL_OUTPUT=$("$RESOLVER" recover \
  --releases-file "$PUBLISHED_EXACT_ARRAY" \
  --repo-dir "$BASE" --dev-ref HEAD --refs-file "$MATCHING")
if grep -Fx 'active=false' <<<"$COMPLETED_CONTROL_OUTPUT" >/dev/null &&
   grep -Fx 'origin=completed' <<<"$COMPLETED_CONTROL_OUTPUT" >/dev/null &&
   ! grep -q '^release_id=' <<<"$COMPLETED_CONTROL_OUTPUT"; then
  echo "ok - exact published authority tuple is a completed no-op"
  pass=$((pass + 1))
else
  echo "not ok - exact published authority tuple is not the inactive completed control" >&2
  echo "$COMPLETED_CONTROL_OUTPUT" >&2
  failures=$((failures + 1))
fi

expect_success "zero candidates is an unrelated no-op" \
  '^active=false$' "$RESOLVER" recover \
  --releases-file "$NO_CANDIDATES" "${common[@]}"
NO_CANDIDATE_OUTPUT=$("$RESOLVER" recover \
  --releases-file "$NO_CANDIDATES" "${common[@]}")
if grep -Fx 'active=false' <<<"$NO_CANDIDATE_OUTPUT" >/dev/null &&
   grep -Fx 'origin=none' <<<"$NO_CANDIDATE_OUTPUT" >/dev/null &&
   ! grep -q '^release_id=' <<<"$NO_CANDIDATE_OUTPUT"; then
  echo "ok - false-branch inactive no-op shape is exact"
  pass=$((pass + 1))
else
  echo "not ok - false-branch inactive no-op shape drifted" >&2
  echo "$NO_CANDIDATE_OUTPUT" >&2
  failures=$((failures + 1))
fi

CREATED_OUTPUT=$("$RESOLVER" created \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --release-file "$COMPLETE" "${common[@]}")
FINGERPRINT=$(awk -F= '$1 == "asset_inventory_fingerprint" {print $2}' \
  <<<"$CREATED_OUTPUT")
ADMISSION_FINGERPRINT=$(awk -F= \
  '$1 == "admission_fingerprint" {print $2}' <<<"$CREATED_OUTPUT")
expect_success "unchanged descriptor verifies" '^origin=verified$' \
  "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --expected-route deep-recover \
  --expected-admission-fingerprint "$ADMISSION_FINGERPRINT" \
  --release-file "$COMPLETE" "${common[@]}"
expect_failure "descriptor route drift fails closed" "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --expected-route materialize \
  --release-file "$COMPLETE" "${common[@]}"
expect_failure "descriptor admission fingerprint drift fails closed" \
  "$RESOLVER" verify \
  --release-id 102 --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
  --asset-inventory-fingerprint "$FINGERPRINT" \
  --expected-route deep-recover \
  --expected-admission-fingerprint "$(printf '0%.0s' {1..64})" \
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
