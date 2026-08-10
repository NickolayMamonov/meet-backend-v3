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

STATE_MODE=auto
RELEASE_REF=
case "${1:-}" in
  "")
    ;;
  --auto-state)
    [ "$#" -eq 1 ] || fail "usage: $0 [--auto-state|--bootstrap-state|--release-state vVERSION]"
    ;;
  --bootstrap-state)
    [ "$#" -eq 1 ] || fail "usage: $0 [--auto-state|--bootstrap-state|--release-state vVERSION]"
    STATE_MODE=bootstrap
    ;;
  --release-state)
    [ "$#" -eq 2 ] || fail "usage: $0 [--auto-state|--bootstrap-state|--release-state vVERSION]"
    STATE_MODE=release
    RELEASE_REF=$2
    ;;
  *)
    fail "usage: $0 [--auto-state|--bootstrap-state|--release-state vVERSION]"
    ;;
esac

require_file() {
  test -f "$1" || fail "missing required file: $1"
}

require_text() {
  local needle=$1
  grep -Fq -- "$needle" <<<"$WORKFLOW_TEXT" ||
    fail "release workflow is missing a required invariant"
}

require_regex() {
  local pattern=$1
  grep -Eq -- "$pattern" <<<"$WORKFLOW_TEXT" ||
    fail "release workflow is missing a required structure"
}

command -v jq >/dev/null 2>&1 ||
  fail "jq is required; hosted CI provides the supported JSON validator"

for file in "$CONFIG" "$MANIFEST" "$VERSION_FILE" "$CHANGELOG" "$RELEASE_WORKFLOW"; do
  require_file "$file"
done
require_file scripts/verify-release-resume-state.sh
require_file scripts/verify-ghcr-package-inventory.sh

WORKFLOW_TEXT=$(sed 's/\r$//' "$RELEASE_WORKFLOW")
RESUME_TEXT=$(sed 's/\r$//' scripts/verify-release-resume-state.sh)

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

verify_release_files() {
  local release_version=$1
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

verify_release_state() {
  [[ "$RELEASE_REF" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail "release-state mode requires a repository-local vVERSION tag"
  verify_release_files "${RELEASE_REF#v}"
}

verify_auto_state() {
  local manifest_version version
  manifest_version=$(jq -r '.["."]' "$MANIFEST")
  version=$(jq -r '.version' "$VERSION_FILE")
  [[ "$manifest_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail "manifest does not contain a canonical release version"
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail "version.json does not contain a canonical release version"
  [ "$manifest_version" = "$version" ] ||
    fail "manifest and version.json release versions do not match"

  if [ "$version" = "1.0.0" ]; then
    verify_bootstrap_state
  else
    verify_release_files "$version"
  fi
}

case "$STATE_MODE" in
  auto)
    verify_auto_state
    ;;
  bootstrap)
    verify_bootstrap_state
    ;;
  release)
    verify_release_state
    ;;
esac

require_regex '^on:$'
require_text '  push:'
require_text '    branches: [dev]'
require_text 'uses: googleapis/release-please-action@c2a5a2bd6a758a0937f1ddb1e8950609867ed15c'
require_text 'token: ${{ secrets.RELEASE_PLEASE_TOKEN }}'
require_text 'target-branch: dev'
require_text 'manifest-file: .release-please-manifest.json'
require_text 'config-file: release-please-config.json'

# Release Please is the creator/tag authority, while the resolver is the only
# source of a release descriptor. A draft tag may be absent until publication.
require_text 'scripts/resolve-release-descriptor.sh recover'
require_text 'scripts/resolve-release-descriptor.sh created'
require_text 'scripts/resolve-release-descriptor.sh verify'
require_text 'scripts/resolve-release-descriptor.sh pre-action'
require_text 'if: steps.pre_action.outputs.route == '\''action'\'''
require_text 'mutate-release-metadata.sh canonicalize'
require_text 'mutate-release-metadata.sh publish'
grep -Fq 'verify-ghcr-package-inventory.sh' <<<"$RESUME_TEXT" ||
  fail "resume verifier is missing GHCR inventory closure"
require_text 'if: needs.release.outputs.active == '\''true'\'''
require_text 'source_sha: ${{ needs.release.outputs.source_sha }}'
require_text 'release_tag: ${{ needs.release.outputs.release_tag }}'
require_text 'release_version: ${{ needs.release.outputs.release_version }}'
require_text 'release_id: ${{ needs.release.outputs.release_id }}'
require_text 'ref: ${{ github.sha }}'
require_text 'ref: ${{ env.SOURCE_SHA }}'
require_text 'path: tooling'
require_text 'path: source'
require_text 'ASSET_INVENTORY_KIND'
require_text 'complete_unverified'
require_text 'resume-registry'
require_text 'registry_digest'
require_text 'verify-release-resume-state.sh'
require_text 'revalidate-release-mutation.sh'
require_text '[ "$latest" = absent ]'
require_text 'acquire-release-lease.sh'
require_text '--platform linux/amd64'
require_text '--provenance=true'
require_text '--sbom=true'
require_text '--tag "$IMAGE:$TAG"'
require_text '--tag "$IMAGE:$VERSION"'
require_text '--tag "$IMAGE:sha-$SOURCE_SHA"'
require_text 'publicationPolicy: "exactly-three-aliases-publish-last"'
require_text 'release-manifest.json'
require_text 'image-index.json'
require_text 'image-inspect.txt'
require_text 'SHA256SUMS'
require_text '--image-ref "$IMAGE@$digest"'
require_text 'repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID'
require_text 'repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID/assets?name=$file'
require_text 'Fetch exact origin/dev authority'
require_text 'Read-only publication verification'

pre_action_block=$(sed -n '/id: pre_action/,/id: action_descriptor/p' \
  <<<"$WORKFLOW_TEXT")
action_descriptor_block=$(sed -n '/id: action_descriptor/,/^  gates:/p' \
  <<<"$WORKFLOW_TEXT")
if grep -Fq 'steps.release.outputs' <<<"$pre_action_block"; then
  fail "pre-action recovery classification consumes action outputs"
fi
grep -Fq 'steps.release.outputs' <<<"$action_descriptor_block" ||
  fail "action descriptor does not consume Release Please outputs on action route"
action_guard_count=$( (grep -F "if: steps.pre_action.outputs.route == 'action'" \
  <<<"$WORKFLOW_TEXT" || true) | wc -l | tr -d '[:space:]')
[ "$action_guard_count" -eq 2 ] ||
  fail "Release Please and action normalization do not share the exact action guard"

if grep -Fq 'release_created == '\''true'\''' <<<"$WORKFLOW_TEXT"; then
  fail "publication must be gated by the verified descriptor, not Release Please output"
fi
for forbidden in \
  'ref: ${{ needs.release.outputs.tag }}' \
  'git rev-list -n 1 "$TAG"' \
  'gh release upload' \
  'gh release edit' \
  'refs/tags/$TAG' \
  '--tag "$IMAGE:latest"'; do
  if grep -Fq -- "$forbidden" <<<"$WORKFLOW_TEXT"; then
    fail "release workflow contains forbidden tag-first or mutable operation: $forbidden"
  fi
done

alias_count=$(grep -E '^[[:space:]]+--tag "\$IMAGE:' <<<"$WORKFLOW_TEXT" |
  sort -u | wc -l | tr -d '[:space:]')
[ "$alias_count" -eq 3 ] ||
  fail "release workflow must publish exactly three immutable aliases"

patch_count=$( (grep -F 'gh api --method PATCH' <<<"$WORKFLOW_TEXT" || true) |
  wc -l | tr -d '[:space:]')
[ "$patch_count" -eq 0 ] ||
  fail "workflow must not contain a direct release PATCH"

checkout_line=$(grep -n 'Checkout reviewed release tooling' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
fetch_line=$(grep -n 'Fetch exact origin/dev authority' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
pre_action_line=$(grep -n 'Classify current authority before Release Please' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
action_line=$(grep -n 'uses: googleapis/release-please-action@' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
deep_verify_first=$(grep -n 'verify-release-resume-state.sh' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
canonicalize_line=$(grep -n 'mutate-release-metadata.sh canonicalize' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
deep_verify_second=$(grep -n 'verify-release-resume-state.sh' <<<"$WORKFLOW_TEXT" |
  tail -1 | cut -d: -f1)
publish_line=$(grep -n 'mutate-release-metadata.sh publish' <<<"$WORKFLOW_TEXT" |
  tail -1 | cut -d: -f1)
readonly_line=$(grep -n 'Read-only publication verification' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
[ -n "$checkout_line" ] && [ -n "$fetch_line" ] &&
  [ -n "$pre_action_line" ] && [ -n "$action_line" ] &&
  [ -n "$deep_verify_first" ] && [ -n "$canonicalize_line" ] &&
  [ -n "$deep_verify_second" ] && [ -n "$publish_line" ] &&
  [ -n "$readonly_line" ] &&
  [ "$checkout_line" -lt "$fetch_line" ] &&
  [ "$fetch_line" -lt "$pre_action_line" ] &&
  [ "$pre_action_line" -lt "$action_line" ] &&
  [ "$deep_verify_first" -lt "$canonicalize_line" ] &&
  [ "$canonicalize_line" -lt "$deep_verify_second" ] &&
  [ "$deep_verify_second" -lt "$publish_line" ] &&
  [ "$publish_line" -lt "$readonly_line" ] ||
  fail "release ordering is not statically provable"

CI_WORKFLOW=.github/workflows/ci.yml
require_file "$CI_WORKFLOW"
CI_TEXT=$(sed 's/\r$//' "$CI_WORKFLOW")
grep -Fq 'test-release-resume-state.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the release resume fixtures"
grep -Fq 'test-release-mutation-revalidation.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the mutation revalidation regression"
for input in source_sha release_tag release_version release_id; do
  grep -Eq "^[[:space:]]+$input:" <<<"$CI_TEXT" ||
    fail "reusable CI is missing additive input: $input"
done
grep -Fq 'ref: ${{ inputs.source_sha }}' <<<"$CI_TEXT" ||
  fail "reusable CI does not check out the exact source SHA"
grep -Fq 'path: tooling' <<<"$CI_TEXT" ||
  fail "reusable CI is missing the current tooling checkout"
grep -Fq 'path: source' <<<"$CI_TEXT" ||
  fail "reusable CI is missing the exact source checkout"

RECOVERY_WORKFLOW=.github/workflows/release-recovery.yml
require_file "$RECOVERY_WORKFLOW"
RECOVERY_TEXT=$(sed 's/\r$//' "$RECOVERY_WORKFLOW")
grep -Fq 'release_id:' <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must accept a numeric release ID"
grep -Fq 'scripts/resolve-release-descriptor.sh pre-action' <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must use the shared resolver"
grep -Fq 'REQUESTED_RELEASE_ID' <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must bind evidence to the requested numeric ID"
grep -Fq 'test "$(value release_id)" = "$REQUESTED_RELEASE_ID"' \
  <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must prove the requested numeric ID"
if grep -Fq 'refs/tags/$TAG' <<<"$RECOVERY_TEXT"; then
  fail "manual recovery must not require a draft tag ref"
fi
if grep -Fq 'gh api --method PATCH' <<<"$RECOVERY_TEXT"; then
  fail "manual recovery must remain read-only"
fi

patch_callers=$( (grep -R -l --exclude='verify-release-please-bootstrap.sh' \
  'gh api --method PATCH' scripts || true) |
  sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
[ "$patch_callers" = "scripts/mutate-release-metadata.sh" ] ||
  fail "release metadata PATCH has more than the sole helper caller"

case "$STATE_MODE" in
  auto)
    echo "release-please state verified: version=$(jq -r '.version' "$VERSION_FILE")"
    ;;
  bootstrap)
    echo "release-please bootstrap verified"
    ;;
  release)
    echo "release-please release state verified: ref=$RELEASE_REF version=${RELEASE_REF#v}"
    ;;
esac
