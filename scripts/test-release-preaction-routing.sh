#!/usr/bin/env bash
set -euo pipefail

# Contract exercised by this suite:
#   resolve-release-descriptor.sh pre-action [common resolver options]
# emits exactly one route:
#   route=recovery  - one canonical/current generated-placeholder draft exists
#   route=action    - no current-authority candidate exists
# Any malformed, conflicting, ambiguous, ref-divergent, or API-unverifiable
# state exits nonzero without emitting a route. Recovery also emits the
# canonical descriptor plus observed_state=canonical|generated_placeholder;
# origin is intentionally not part of this routing contract.
# The workflow may invoke Release Please only for route=action.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER=$ROOT_DIR/scripts/resolve-release-descriptor.sh
FIXTURES=$ROOT_DIR/scripts/fixtures/release-preaction-routing/scenarios.json
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

export GIT_AUTHOR_NAME='Pre-action Routing Fixture'
export GIT_AUTHOR_EMAIL='preaction-routing@example.invalid'
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

REPO=$TMP/repo
git init -q "$REPO"
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config user.name "$GIT_AUTHOR_NAME"
git -C "$REPO" config user.email "$GIT_AUTHOR_EMAIL"

commit_authority() {
  local version=$1
  printf '{".":"%s"}\n' "$version" \
    >"$REPO/.release-please-manifest.json"
  printf '{"version":"%s"}\n' "$version" >"$REPO/version.json"
  git -C "$REPO" add .release-please-manifest.json version.json
  git -C "$REPO" commit -qm "authority $version"
}

commit_authority 1.0.0
OLD=$(git -C "$REPO" rev-parse HEAD)
commit_authority 1.0.1
SOURCE=$(git -C "$REPO" rev-parse HEAD)
printf '%s\n' fixture >"$REPO/unrelated.txt"
git -C "$REPO" add unrelated.txt
git -C "$REPO" commit -qm 'post-boundary fixture'
TIP=$(git -C "$REPO" rev-parse HEAD)

mkdir "$TMP/bin"
ACTION_COUNT=$TMP/action-count
WRITE_LOG=$TMP/hosted-writes.log
printf '0\n' >"$ACTION_COUNT"
: >"$WRITE_LOG"
export ACTION_COUNT WRITE_LOG

{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'count=$(cat "$ACTION_COUNT")'
  echo 'printf "%s\n" "$((count + 1))" >"$ACTION_COUNT"'
} >"$TMP/bin/mock-release-please"
chmod +x "$TMP/bin/mock-release-please"

{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'method=GET'
  echo 'next_is_method=false'
  echo 'for argument in "$@"; do'
  echo '  if [ "$next_is_method" = true ]; then'
  echo '    method=$argument'
  echo '    next_is_method=false'
  echo '    continue'
  echo '  fi'
  echo '  case "$argument" in'
  echo '    --method) next_is_method=true ;;'
  echo '    --method=*) method=${argument#--method=} ;;'
  echo '  esac'
  echo 'done'
  echo 'if [ "$method" != GET ]; then'
  echo '  printf "gh api method=%s\n" "$method" >>"$WRITE_LOG"'
  echo 'fi'
  echo 'echo "fixture GitHub API read failed" >&2'
  echo 'exit 1'
} >"$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

PATH=$TMP/bin:$PATH
export PATH

materialize_case() {
  local case_name=$1 releases_file=$2 refs_file=$3
  jq --arg case_name "$case_name" \
    --arg source "$SOURCE" --arg old "$OLD" --arg tip "$TIP" '
      [
        .cases[$case_name].releasePatches[] as $patch |
        (.baseRelease + $patch)
      ] | walk(
        if type == "string" then
          gsub("@SOURCE@"; $source) |
          gsub("@OLD@"; $old) |
          gsub("@TIP@"; $tip)
        else
          .
        end
      )
    ' "$FIXTURES" >"$releases_file"
  jq --arg case_name "$case_name" \
    --arg source "$SOURCE" --arg old "$OLD" --arg tip "$TIP" '
      .cases[$case_name].refs | walk(
        if type == "string" then
          gsub("@SOURCE@"; $source) |
          gsub("@OLD@"; $old) |
          gsub("@TIP@"; $tip)
        else
          .
        end
      )
    ' "$FIXTURES" >"$refs_file"
}

value() {
  local key=$1 descriptor=$2
  awk -F= -v key="$key" '$1 == key {
    sub(/^[^=]*=/, "")
    print
  }' <<<"$descriptor"
}

assert_no_action_or_write() {
  local case_name=$1
  [ "$(cat "$ACTION_COUNT")" -eq 0 ] || {
    echo "not ok - $case_name invoked Release Please" >&2
    return 1
  }
  [ ! -s "$WRITE_LOG" ] || {
    echo "not ok - $case_name attempted a hosted write" >&2
    sed 's/^/  /' "$WRITE_LOG" >&2
    return 1
  }
}

run_case() {
  local case_name=$1 expected transport observed_state
  local releases_file=$TMP/$case_name-releases.json
  local refs_file=$TMP/$case_name-refs.json
  local output_file=$TMP/$case_name-output
  local error_file=$TMP/$case_name-error
  local -a args

  expected=$(jq -r --arg case_name "$case_name" \
    '.cases[$case_name].expected' "$FIXTURES")
  transport=$(jq -r --arg case_name "$case_name" \
    '.cases[$case_name].transport // "injected"' "$FIXTURES")
  materialize_case "$case_name" "$releases_file" "$refs_file"
  printf '0\n' >"$ACTION_COUNT"
  : >"$WRITE_LOG"

  args=(
    pre-action
    --repo-dir "$REPO"
    --dev-ref HEAD
    --repository fixture/repository
  )
  case "$transport" in
    injected)
      args+=(--releases-file "$releases_file" --refs-file "$refs_file")
      ;;
    release_api_error)
      args+=(--refs-file "$refs_file")
      ;;
    refs_api_error)
      args+=(--releases-file "$releases_file")
      ;;
    *)
      echo "unknown fixture transport: $transport" >&2
      return 1
      ;;
  esac

  if "$RESOLVER" "${args[@]}" >"$output_file" 2>"$error_file"; then
    descriptor=$(<"$output_file")
    route=$(value route "$descriptor")
    [ "$expected" != failure ] || {
      echo "not ok - $case_name unexpectedly succeeded" >&2
      return 1
    }
    [ "$route" = "$expected" ] || {
      echo "not ok - $case_name selected route '$route'" >&2
      return 1
    }

    case "$route" in
      recovery)
        observed_state=$(jq -r --arg case_name "$case_name" \
          '.cases[$case_name].observedState' "$FIXTURES")
        [ "$(value active "$descriptor")" = true ]
        [ "$(value observed_state "$descriptor")" = "$observed_state" ]
        [ "$(value release_id "$descriptor")" = 701 ]
        [ "$(value tag "$descriptor")" = v1.0.1 ]
        [ "$(value version "$descriptor")" = 1.0.1 ]
        [ "$(value source_sha "$descriptor")" = "$SOURCE" ]
        assert_no_action_or_write "$case_name"
        ;;
      action)
        "$TMP/bin/mock-release-please"
        [ "$(cat "$ACTION_COUNT")" -eq 1 ]
        [ ! -s "$WRITE_LOG" ]
        ;;
      *)
        echo "not ok - $case_name emitted unsupported route '$route'" >&2
        return 1
        ;;
    esac
  else
    [ "$expected" = failure ] || {
      echo "not ok - $case_name failed unexpectedly" >&2
      sed 's/^/  /' "$error_file" >&2
      return 1
    }
    if grep -Eq '^route=' "$output_file"; then
      echo "not ok - $case_name emitted a partial route before failure" >&2
      return 1
    fi
    assert_no_action_or_write "$case_name"
  fi

  echo "ok - $case_name"
}

failures=0
while IFS= read -r case_name; do
  case_name=${case_name%$'\r'}
  run_case "$case_name" || failures=$((failures + 1))
done < <(jq -r '.cases | keys[]' "$FIXTURES")

[ "$failures" -eq 0 ] || {
  echo "$failures pre-action routing fixture checks failed" >&2
  exit 1
}
echo "release pre-action routing fixtures passed: 9 cases"
