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
require_text '--tag "$IMAGE:$TAG"'
require_text '--tag "$IMAGE:$VERSION"'
require_text '--tag "$IMAGE:sha-$SOURCE_SHA"'
require_text 'aliases: ["v" + $version, $version, "sha-" + $sourceSha]'
require_text 'publicationPolicy: "exactly-three-aliases-publish-last"'
require_text 'gh release upload "$TAG" release-manifest.json image-index.json image-inspect.txt SHA256SUMS'
require_text 'gh release edit "$TAG" --draft=false'

echo "release-please bootstrap verified"
