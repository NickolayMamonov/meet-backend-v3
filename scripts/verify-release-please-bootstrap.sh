#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

CONFIG=release-please-config.json
MANIFEST=.release-please-manifest.json
VERSION_FILE=version.json
CHANGELOG=CHANGELOG.md
RELEASE_WORKFLOW=.github/workflows/release-please.yml
BOOTSTRAP_SHA=bea6672443c16ee7be2297cc39ad5cd4e2a077c4

fail() {
  echo "release-please bootstrap verification failed: $1" >&2
  exit 1
}

STATE_MODE=bootstrap
RELEASE_REF=
case "${1:-}" in
  "")
    ;;
  --bootstrap-state)
    [ "$#" -eq 1 ] || fail "usage: $0 [--bootstrap-state|--release-state vVERSION]"
    ;;
  --release-state)
    [ "$#" -eq 2 ] || fail "usage: $0 [--bootstrap-state|--release-state vVERSION]"
    STATE_MODE=release
    RELEASE_REF=$2
    ;;
  *)
    fail "usage: $0 [--bootstrap-state|--release-state vVERSION]"
    ;;
esac

require_file() {
  test -f "$1" || fail "missing required file: $1"
}

require_text() {
  local needle=$1
  grep -Fq -- "$needle" "$RELEASE_WORKFLOW" ||
    fail "release workflow is missing a required invariant"
}

require_regex() {
  local pattern=$1
  grep -Eq -- "$pattern" "$RELEASE_WORKFLOW" ||
    fail "release workflow is missing a required structure"
}

command -v jq >/dev/null 2>&1 ||
  fail "jq is required; hosted CI provides the supported JSON validator"

for file in "$CONFIG" "$MANIFEST" "$VERSION_FILE" "$CHANGELOG" "$RELEASE_WORKFLOW"; do
  require_file "$file"
done

jq empty "$CONFIG" "$MANIFEST" "$VERSION_FILE" >/dev/null ||
  fail "release configuration or bootstrap state is not valid JSON"

jq -e --arg bootstrap_sha "$BOOTSTRAP_SHA" '
  type == "object" and
  .["release-type"] == "simple" and
  .["package-name"] == "meet-backend" and
  .["initial-version"] == "1.0.0" and
  .["bootstrap-sha"] == $bootstrap_sha and
  .["include-component-in-tag"] == false and
  .["include-v-in-tag"] == true and
  .draft == true and
  (.["changelog-sections"] == [
    {"type": "feat", "section": "Features"},
    {"type": "fix", "section": "Fixes"},
    {"type": "perf", "section": "Performance"},
    {"type": "refactor", "section": "Refactoring"}
  ]) and
  (.packages | type == "object" and keys == ["."]) and
  (.packages["."] | type == "object") and
  (.packages["."]["release-type"] == "simple") and
  (.packages["."]["package-name"] == "meet-backend") and
  (.packages["."] | has("include-component-in-tag") | not) and
  (.packages["."]["extra-files"] == [
    {"type": "json", "path": "version.json", "jsonpath": "$.version"}
  ]) and
  ([paths | select(length > 0 and .[-1] == "last-release-sha")] | length == 0) and
  (. as $root
   | ($root + $root.packages["."]) as $effective
   | $effective["include-component-in-tag"] == false
   and $effective["include-v-in-tag"] == true
   and $effective["release-type"] == "simple"
   and $effective["package-name"] == "meet-backend")
' "$CONFIG" >/dev/null ||
  fail "Release Please config does not have the required effective root package"

verify_bootstrap_state() {
  jq -e '
    type == "object" and
    length == 1 and
    .["."] == "1.0.0"
  ' "$MANIFEST" >/dev/null ||
    fail "Release Please manifest bootstrap state must remain exactly 1.0.0"

  jq -e '
    type == "object" and
    length == 1 and
    .version == "1.0.0"
  ' "$VERSION_FILE" >/dev/null ||
    fail "version.json bootstrap state must remain exactly 1.0.0"

  expected_changelog=$'# Changelog\n\nAll notable backend releases are recorded here by Release Please.'
  actual_changelog=$(sed 's/\r$//' "$CHANGELOG")
  [[ "$actual_changelog" == "$expected_changelog" ]] ||
    fail "CHANGELOG.md bootstrap state must remain unchanged"
}

verify_release_state() {
  [[ "$RELEASE_REF" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail "release-state mode requires a repository-local vVERSION tag"
  release_version=${RELEASE_REF#v}

  jq -e --arg release_version "$release_version" '
    type == "object" and
    length == 1 and
    .["."] == $release_version
  ' "$MANIFEST" >/dev/null ||
    fail "release manifest does not match the checked-out release tag"

  jq -e --arg release_version "$release_version" '
    type == "object" and
    length == 1 and
    .version == $release_version
  ' "$VERSION_FILE" >/dev/null ||
    fail "version.json does not match the checked-out release tag"

  expected_changelog=$'# Changelog\n\nAll notable backend releases are recorded here by Release Please.'
  actual_changelog=$(sed 's/\r$//' "$CHANGELOG")
  [[ "$actual_changelog" != "$expected_changelog" ]] ||
    fail "release-tag validation received the bootstrap changelog"
  grep -Eq "^## \\[?$release_version(\\]|[[:space:]])" "$CHANGELOG" ||
    fail "CHANGELOG.md does not contain the checked-out release version"
}

if [ "$STATE_MODE" = bootstrap ]; then
  verify_bootstrap_state
else
  verify_release_state
fi

require_regex '^on:$'
require_text '  push:'
require_text '    branches: [dev]'
require_text 'uses: googleapis/release-please-action@c2a5a2bd6a758a0937f1ddb1e8950609867ed15c'
require_text 'token: ${{ secrets.RELEASE_PLEASE_TOKEN }}'
require_text 'target-branch: dev'
require_text 'manifest-file: .release-please-manifest.json'
require_text 'config-file: release-please-config.json'

require_text 'needs: release'
require_text "if: needs.release.outputs.created == 'true'"
require_text 'uses: ./.github/workflows/ci.yml'
require_text 'ref: ${{ needs.release.outputs.tag }}'
require_text 'needs: [release, gates]'
require_text 'TAG: ${{ needs.release.outputs.tag }}'
require_text 'VERSION: ${{ needs.release.outputs.version }}'
require_text 'SOURCE_SHA: ${{ needs.release.outputs.sha }}'

require_text 'test "$TAG" = "v$VERSION"'
require_text 'test "$SOURCE_SHA" = "$(git rev-list -n 1 "$TAG")"'
require_text 'test "$(git show "$SOURCE_SHA:version.json" | jq -r '\''.version'\'')" = "$VERSION"'
require_text 'test "$revision" = "$SOURCE_SHA"'
image_tag_lines=()
mapfile -t image_tag_lines < <(
  grep -E '^[[:space:]]+--tag "\$IMAGE:[^"]+"' "$RELEASE_WORKFLOW" || true
)
[ "${#image_tag_lines[@]}" -eq 3 ] ||
  fail "release workflow must publish exactly three immutable image aliases"
for expected_tag in \
  '--tag "$IMAGE:$TAG"' \
  '--tag "$IMAGE:$VERSION"' \
  '--tag "$IMAGE:sha-$SOURCE_SHA"'; do
  expected_count=$(grep -F -- "$expected_tag" "$RELEASE_WORKFLOW" |
    wc -l | tr -d '[:space:]' || true)
  [ "$expected_count" -eq 1 ] ||
    fail "release workflow is missing or duplicating an immutable image alias"
done
if grep -Eiq '^[[:space:]]+--tag "\$IMAGE:latest"' "$RELEASE_WORKFLOW"; then
  fail "release workflow must not publish the latest image alias"
fi
alias_line_count=$(grep -E '^[[:space:]]+aliases:' "$RELEASE_WORKFLOW" |
  wc -l | tr -d '[:space:]' || true)
[ "$alias_line_count" -eq 1 ] ||
  fail "release manifest must declare exactly one alias list"
require_text 'aliases: ["v" + $version, $version, "sha-" + $sourceSha]'
require_text 'publicationPolicy: "exactly-three-aliases-publish-last"'
require_text 'gh release upload "$TAG" release-manifest.json image-index.json image-inspect.txt SHA256SUMS'
require_text 'gh release edit "$TAG" --draft=false'

if [ "$STATE_MODE" = bootstrap ]; then
  echo "release-please bootstrap verified"
else
  echo "release-please release state verified: ref=$RELEASE_REF version=$release_version"
fi
