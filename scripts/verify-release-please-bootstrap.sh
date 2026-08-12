#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

CONFIG=release-please-config.json
MANIFEST=.release-please-manifest.json
VERSION_FILE=version.json
CHANGELOG=CHANGELOG.md
RELEASE_WORKFLOW=.github/workflows/release-please.yml
RECOVERY_WORKFLOW=.github/workflows/release-recovery.yml
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

for file in "$CONFIG" "$MANIFEST" "$VERSION_FILE" "$CHANGELOG" \
  "$RELEASE_WORKFLOW" "$RECOVERY_WORKFLOW"; do
  require_file "$file"
done
require_file scripts/verify-release-resume-state.sh
require_file scripts/release-asset-inventory.sh
require_file scripts/test-release-asset-inventory.sh
require_file scripts/fixtures/release-asset-inventory-incident.json
require_file scripts/verify-ghcr-package-inventory.sh
require_file scripts/verify-oci-referrer-closure.sh
require_file scripts/test-oci-referrer-closure.sh
require_file scripts/normalize-ghcr-package-inventory.sh
require_file scripts/test-ghcr-package-normalization.sh
require_file scripts/verify-release-tag-ref.sh
require_file scripts/test-release-tag-ref.sh
require_file scripts/test-release-metadata-mutation.sh
require_file scripts/test-resolve-release-descriptor.sh
require_file scripts/fixtures/release-descriptor/scenarios.json
require_file scripts/test-release-descriptor-schema.sh
require_file scripts/fixtures/release-descriptor-schema/active-keys.txt
require_file scripts/fixtures/release-descriptor-schema/scenarios.json

WORKFLOW_TEXT=$(sed 's/\r$//' "$RELEASE_WORKFLOW")
RESUME_TEXT=$(sed 's/\r$//' scripts/verify-release-resume-state.sh)
ASSET_TEST_TEXT=$(sed 's/\r$//' scripts/test-release-asset-inventory.sh)
CLOSURE_TEXT=$(sed 's/\r$//' scripts/verify-oci-referrer-closure.sh)
INVENTORY_TEXT=$(sed 's/\r$//' scripts/verify-ghcr-package-inventory.sh)
INVENTORY_TEST_TEXT=$(sed 's/\r$//' scripts/test-ghcr-package-inventory.sh)
TAG_REF_TEXT=$(sed 's/\r$//' scripts/verify-release-tag-ref.sh)
METADATA_TEST_TEXT=$(sed 's/\r$//' scripts/test-release-metadata-mutation.sh)
PRE_ACTION_FIXTURES=$(sed 's/\r$//' scripts/fixtures/release-preaction-routing/scenarios.json)
RESOLVER_TEST_TEXT=$(sed 's/\r$//' scripts/test-resolve-release-descriptor.sh)
DESCRIPTOR_FIXTURES=$(sed 's/\r$//' scripts/fixtures/release-descriptor/scenarios.json)
ACTIVE_SCHEMA_KEYS=$(sed 's/\r$//' \
  scripts/fixtures/release-descriptor-schema/active-keys.txt)
RESOLVER_TEXT=$(sed 's/\r$//' scripts/resolve-release-descriptor.sh)

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
require_text 'scripts/resolve-release-descriptor.sh post-action'
require_text 'scripts/resolve-release-descriptor.sh verify'
require_text 'scripts/resolve-release-descriptor.sh pre-action'
require_text 'admission_fingerprint'
require_text 'expected-route materialize'
require_text 'expected-route deep-recover'
require_text 'Bind canonical-empty materialize entry'
require_text 'Bind complete deep-recovery entry'
require_text 'RELEASE_CREATED: ${{ steps.release.outputs.release_created }}'
require_text 'CREATED_TAG: ${{ steps.release.outputs.tag_name }}'
require_text 'CREATED_VERSION: ${{ steps.release.outputs.version }}'
require_text 'CREATED_SOURCE_SHA: ${{ steps.release.outputs.sha }}'
require_text 'case "$RELEASE_CREATED" in'
require_text 'positive_id "$(value release_id)"'
require_text 'test -z "$(value release_id)"'
require_text 'output_block=$('
require_text 'printf '\''%s\n'\'' "$output_block" >> "$GITHUB_OUTPUT"'
require_text 'if: steps.pre_action.outputs.route == '\''action'\'''
require_text 'mutate-release-metadata.sh canonicalize'
require_text 'mutate-release-metadata.sh publish'

EXPECTED_ACTIVE_KEYS=$'route\nactive\norigin\nobserved_state\nobserved_tag\nrelease_id\ntag\nversion\nsource_sha\ntarget_commitish\ndraft\nprerelease\npublished_at\nauthority_version\nauthority_tag\nauthority_source_sha\nasset_inventory_kind\nasset_inventory_fingerprint\nasset_inventory_json\nadmission_fingerprint'
[ "$ACTIVE_SCHEMA_KEYS" = "$EXPECTED_ACTIVE_KEYS" ] ||
  fail "active descriptor schema must pin the exact ordered 20-key contract"
[ "$(grep -Ec '^[[:space:]]*construct_active_record\(\)' <<<"$RESOLVER_TEXT")" -eq 1 ] ||
  fail "resolver must define exactly one active descriptor constructor"
[ "$(grep -Ec '^[[:space:]]*serialize_active_record\(\)' <<<"$RESOLVER_TEXT")" -eq 1 ] ||
  fail "resolver must define exactly one active descriptor serializer"
if grep -Eq '^[[:space:]]*(emit_active|emit_pre_action_recovery)\(\)' \
    <<<"$RESOLVER_TEXT"; then
  fail "resolver retains a route-specific active descriptor emitter"
fi
SERIALIZER_BLOCK=$(sed -n \
  '/^serialize_active_record()/,/^}/p' <<<"$RESOLVER_TEXT")
SERIALIZER_KEYS=$(
  sed -n 's/^[[:space:]]*echo "\([^=]*\)=.*$/\1/p' <<<"$SERIALIZER_BLOCK"
)
[ "$SERIALIZER_KEYS" = "$EXPECTED_ACTIVE_KEYS" ] ||
  fail "active serializer does not emit the exact ordered 20-key contract"
for constructor_call in \
  'construct_active_record created' \
  'construct_active_record post_action' \
  'construct_active_record recovered' \
  'construct_active_record pre_action' \
  'construct_active_record verified'; do
  grep -Fq "$constructor_call" <<<"$RESOLVER_TEXT" ||
    fail "active mode does not use the shared constructor: $constructor_call"
done
[ "$(grep -Ec '^[[:space:]]+serialize_active_record$' <<<"$RESOLVER_TEXT")" -ge 5 ] ||
  fail "active modes do not use the shared serializer"
grep -Fq 'verify-ghcr-package-inventory.sh' <<<"$RESUME_TEXT" ||
  fail "resume verifier is missing GHCR inventory closure"
grep -Fq 'verify-oci-referrer-closure.sh' <<<"$RESUME_TEXT" ||
  fail "resume verifier is missing subject-bound OCI referrer closure"
grep -Fq 'normalize-ghcr-package-inventory.sh' <<<"$RESUME_TEXT" ||
  fail "resume verifier is missing page-array package normalization"
grep -Fq 'verify-release-tag-ref.sh' <<<"$WORKFLOW_TEXT" ||
  fail "release workflow is missing annotated/lightweight tag ref verification"
grep -Fq -- '--observed-tag "$OBSERVED_TAG"' <<<"$WORKFLOW_TEXT" ||
  fail "recovery canonicalization does not bind the observed placeholder tag"
grep -Fq 'ORIGINAL_ASSET_INVENTORY_FINGERPRINT' <<<"$WORKFLOW_TEXT" ||
  fail "release workflow does not preserve the original asset fingerprint"
grep -Fq 'POST_ACTION_ASSET_INVENTORY_FINGERPRINT' <<<"$WORKFLOW_TEXT" ||
  fail "release workflow does not bind the post-action asset fingerprint"
grep -Fq 'test "$POST_ACTION_ASSET_INVENTORY_FINGERPRINT" =' \
  <<<"$WORKFLOW_TEXT" ||
  fail "release workflow does not retain the post-action fingerprint expectation"
grep -Fq 'test "$fingerprint" = "$ASSET_INVENTORY_FINGERPRINT"' \
  <<<"$WORKFLOW_TEXT" ||
  fail "release workflow does not compare final assets to the publish expectation"
if grep -Fq -- '--expected-fingerprint "$fingerprint"' <<<"$WORKFLOW_TEXT"; then
  fail "release workflow re-adopts a freshly recomputed fingerprint for publication"
fi
grep -Fq 'observed-tag' <<<"$METADATA_TEST_TEXT" ||
  fail "metadata mutation fixtures are missing exact placeholder-tag binding"
grep -Fq 'same-name asset replacement' <<<"$METADATA_TEST_TEXT" ||
  fail "metadata mutation fixtures are missing same-name asset drift coverage"
grep -Fq 'depth=' <<<"$TAG_REF_TEXT" ||
  fail "tag ref verifier is missing annotated tag peeling"
grep -Fq 'SUBJECT_MARKER' <<<"$INVENTORY_TEXT" ||
  fail "GHCR inventory verifier is missing subject-marker uniqueness"
grep -Fq 'duplicate-subject-marker' <<<"$INVENTORY_TEST_TEXT" ||
  fail "GHCR inventory fixtures are missing duplicate subject-marker rejection"
grep -Fq 'validate_descriptor' <<<"$CLOSURE_TEXT" ||
  fail "OCI referrer closure is missing child descriptor validation"
grep -Fq 'fetch_raw' <<<"$CLOSURE_TEXT" ||
  fail "OCI referrer closure is missing raw manifest reads"
grep -Fq '#!/bin/sh' <<<"$(head -1 scripts/verify-release-resume-state.sh)" ||
  fail "resume verifier must remain POSIX /bin/sh"
if grep -Eq '(^|[[:space:]])\[\[[[:space:]]' <<<"$RESUME_TEXT"; then
  fail "POSIX resume verifier contains Bash conditional syntax"
fi
grep -Fq 'release-asset-inventory.sh' <<<"$RESUME_TEXT" ||
  fail "resume verifier does not execute the shared asset inventory helper"
grep -Fq 'canonical-json --release-file "$RELEASE_JSON"' <<<"$RESUME_TEXT" ||
  fail "resume verifier does not admit assets through the shared helper"
helper_line=$(grep -n 'canonical-json --release-file "$RELEASE_JSON"' \
  <<<"$RESUME_TEXT" | head -1 | cut -d: -f1)
download_line=$(grep -n '^[[:space:]]*download_asset "\$asset_id"' \
  <<<"$RESUME_TEXT" | head -1 | cut -d: -f1)
[ -n "$helper_line" ] && [ -n "$download_line" ] &&
  [ "$helper_line" -lt "$download_line" ] ||
  fail "resume helper admission must precede asset downloads"
for forbidden in EXPECTED_ASSETS 'sort_by(.name)' \
  '(.assets | length) == 4'; do
  if grep -Fq -- "$forbidden" <<<"$RESUME_TEXT"; then
    fail "resume verifier contains an independent asset admission predicate"
  fi
done
asset_fingerprint_gate_count=$(
  grep -F 'tooling/scripts/release-asset-inventory.sh fingerprint' \
    <<<"$WORKFLOW_TEXT" | wc -l | tr -d '[:space:]'
)
[ "$asset_fingerprint_gate_count" -eq 4 ] &&
grep -Fq -- '--release-file "$release_json"' <<<"$WORKFLOW_TEXT" ||
  fail "release workflow does not use the shared asset fingerprint helper"
for caller in scripts/resolve-release-descriptor.sh \
  scripts/mutate-release-metadata.sh scripts/revalidate-release-mutation.sh; do
  caller_text=$(sed 's/\r$//' "$caller")
  grep -Fq 'release-asset-inventory.sh' <<<"$caller_text" ||
    fail "$caller does not invoke the shared asset inventory helper"
  if grep -Eq 'sort_by\(\.name\)|created_at.*updated_at|updated_at.*url' \
      <<<"$caller_text"; then
    fail "$caller contains duplicate asset canonicalization logic"
  fi
done
grep -Fq 'a7a762e42d972e3131090effe5706265e03d21de8d47c7d2761f65096e7fa3f9' \
  <<<"$ASSET_TEST_TEXT" ||
  fail "asset inventory test does not pin the full incident fingerprint"
FULL_INCIDENT_DIGEST=a7a762e42d972e3131090effe5706265e03d21de8d47c7d2761f65096e7fa3f9
TRUNCATED_DIGEST_PATTERN="(^|[^0-9a-f])${FULL_INCIDENT_DIGEST%?}([^0-9a-f]|$)"
if grep -R -E -n --exclude='verify-release-please-bootstrap.sh' \
    "$TRUNCATED_DIGEST_PATTERN" scripts .github docs; then
  fail "repository contains the truncated incident fingerprint"
fi
grep -Fq 'published-current-conflict' <<<"$PRE_ACTION_FIXTURES" ||
  fail "pre-action fixtures are missing the published current conflict"
grep -Fq 'published-future-conflict' <<<"$PRE_ACTION_FIXTURES" ||
  fail "pre-action fixtures are missing the published future conflict"
for fixture in \
  published-predecessor-action \
  recovery-only-published-predecessor \
  canonical-active-completed-mix \
  placeholder-active-completed-mix; do
  grep -Fq "\"$fixture\"" <<<"$PRE_ACTION_FIXTURES" ||
    fail "pre-action fixtures are missing predecessor cardinality case: $fixture"
done
for marker in \
  'published predecessor missing peeled ref fails closed' \
  'published predecessor divergent peeled ref fails closed' \
  'published predecessor malformed ref fails closed' \
  'published predecessor unsupported ref fails closed' \
  'published predecessor malformed peeled ref fails closed' \
  'published predecessor overdeep peeled ref fails closed' \
  'draft-string' \
  'prerelease-string' \
  'published-number' \
  'published-object' \
  'published-empty' \
  'published-missing' \
  'published empty assets fail closed' \
  'published malformed assets fail closed' \
  'published wrong assets fail closed' \
  'published duplicate assets fail closed' \
  'duplicate completed predecessors fail closed' \
  'canonical active plus completed fails closed' \
  'placeholder active plus completed fails closed' \
  'exact published authority tuple is a completed no-op'; do
  grep -Fq "$marker" <<<"$RESOLVER_TEST_TEXT" ||
    fail "shared resolver fixtures are missing critical marker: $marker"
done
for marker in \
  'publishedExactCurrent' \
  'completeCurrent'; do
  grep -Fq "\"$marker\"" <<<"$DESCRIPTOR_FIXTURES" ||
    fail "shared resolver fixture data is missing marker: $marker"
done
grep -Fq 'no-candidate-canonical-ref' <<<"$PRE_ACTION_FIXTURES" ||
  fail "pre-action fixtures are missing the orphan canonical-ref conflict"
grep -Fq 'no-candidate-refs-api-error' <<<"$PRE_ACTION_FIXTURES" ||
  fail "pre-action fixtures are missing the zero-candidate refs API error"
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

PUBLISH_BLOCK=$(sed -n '/^  publish:/,/^  recovery:/p' <<<"$WORKFLOW_TEXT")
RECOVERY_BLOCK=$(sed -n '/^  recovery:/,$p' <<<"$WORKFLOW_TEXT")
GATES_BLOCK=$(sed -n '/^  gates:/,/^  publish:/p' <<<"$WORKFLOW_TEXT")
RELEASE_BLOCK=$(sed -n '/^  release:/,/^  gates:/p' <<<"$WORKFLOW_TEXT")
grep -Fq "needs.release.outputs.route == 'materialize'" <<<"$GATES_BLOCK" ||
  fail "reusable build gates are not materialize-only"
grep -Fq "needs.release.outputs.route == 'materialize'" <<<"$PUBLISH_BLOCK" ||
  fail "publish job is not materialize-only"
if grep -Fq 'mutate-release-metadata.sh canonicalize' <<<"$PUBLISH_BLOCK"; then
  fail "action-only publish job contains recovery canonicalization"
fi
grep -Fq "needs.release.outputs.route == 'deep-recover'" <<<"$RECOVERY_BLOCK" ||
  fail "recovery job does not require the deep-recover route"
grep -Eq '^[[:space:]]+needs: release$' <<<"$RECOVERY_BLOCK" ||
  fail "deep recovery is reachable through build/upload gates"
if grep -Eiq \
    'docker (build|push)|build-push-action|gradlew|gh release upload|uploads\.github\.com|Upload the exact evidence set' \
    <<<"$RECOVERY_BLOCK"; then
  fail "deep recovery contains a build or asset-upload path"
fi
if grep -Fq 'googleapis/release-please-action@' <<<"$RECOVERY_BLOCK" ||
   grep -Fq 'googleapis/release-please-action@' <<<"$PUBLISH_BLOCK" ||
   grep -Fq 'googleapis/release-please-action@' <<<"$GATES_BLOCK"; then
  fail "Release Please action is reachable outside the action-classification job"
fi
[ "$(grep -F 'googleapis/release-please-action@' <<<"$RELEASE_BLOCK" |
  wc -l | tr -d '[:space:]')" -eq 1 ] ||
  fail "release job must contain exactly one Release Please action"
grep -Fq 'contents: write' <<<"$RECOVERY_BLOCK" ||
  fail "recovery job cannot publish release metadata"
grep -Fq 'packages: read' <<<"$RECOVERY_BLOCK" ||
  fail "recovery job must inspect GHCR with packages:read"
if grep -Eq 'packages: write|attestations: write|id-token: write' \
    <<<"$RECOVERY_BLOCK"; then
  fail "recovery job has package, attestation, or OIDC write permission"
fi
for forbidden in \
  'git push' \
  'git tag' \
  'gh release create' \
  'gh release upload' \
  'gh api --method POST' \
  'gh api --method PUT' \
  'gh api --method DELETE'; do
  if grep -Fq -- "$forbidden" <<<"$RECOVERY_BLOCK"; then
    fail "deep recovery contains direct tag/ref or release mutation: $forbidden"
  fi
done
grep -Fq 'recovery-canonical-ref-before' <<<"$RECOVERY_BLOCK" ||
  fail "generated-placeholder recovery does not prove ref absence before canonicalization"
grep -Fq 'recovery-canonical-ref-after' <<<"$RECOVERY_BLOCK" ||
  fail "generated-placeholder recovery does not re-prove ref absence after canonicalization"
grep -Fq 'recovery-canonical-ref-final' <<<"$RECOVERY_BLOCK" ||
  fail "generated-placeholder recovery does not prove ref absence before publication"
if grep -Eiq \
    '(attach|upload)[^.!?]*quarantine JSON' \
    <<<"$(sed 's/\r$//' docs/operations/backend-release-publishing.md)"; then
  fail "operations docs instruct operators to attach or upload quarantine JSON"
fi

pre_action_block=$(sed -n '/id: pre_action/,/id: action_descriptor/p' \
  <<<"$WORKFLOW_TEXT")
action_descriptor_block=$(sed -n '/id: action_descriptor/,/^  gates:/p' \
  <<<"$WORKFLOW_TEXT")
if grep -Fq 'steps.release.outputs' <<<"$pre_action_block"; then
  fail "pre-action recovery classification consumes action outputs"
fi
grep -Fq 'steps.release.outputs' <<<"$action_descriptor_block" ||
  fail "action descriptor does not consume Release Please outputs on action route"
if grep -Fq 'steps.release.outputs.release_id' <<<"$WORKFLOW_TEXT" ||
   grep -Fq 'CREATED_RELEASE_ID' <<<"$WORKFLOW_TEXT"; then
  fail "action descriptor relies on the nonexistent Release Please release_id output"
fi
if grep -Eiq 'html_url|upload_url|releases\?[^[:space:]]*' \
    <<<"$action_descriptor_block"; then
  fail "action descriptor contains URL identity or YAML release enumeration"
fi
if [ "$(grep -F '>> "$GITHUB_OUTPUT"' <<<"$action_descriptor_block" |
    wc -l | tr -d '[:space:]')" -ne 1 ]; then
  fail "action descriptor does not append its complete output exactly once"
fi
grep -Fq 'post-action' <<<"$action_descriptor_block" ||
  fail "true Release Please results do not use the dedicated post-action resolver"
grep -Fq 'recover' <<<"$action_descriptor_block" ||
  fail "false Release Please results do not use recovery"
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
[ -n "$checkout_line" ] && [ -n "$fetch_line" ] &&
  [ -n "$pre_action_line" ] && [ -n "$action_line" ] &&
  [ "$checkout_line" -lt "$fetch_line" ] &&
  [ "$fetch_line" -lt "$pre_action_line" ] &&
  [ "$pre_action_line" -lt "$action_line" ] ||
  fail "release ordering is not statically provable"

action_deep_line=$(grep -n 'verify-release-resume-state.sh' <<<"$PUBLISH_BLOCK" |
  head -1 | cut -d: -f1)
action_publish_line=$(grep -n 'mutate-release-metadata.sh publish' <<<"$PUBLISH_BLOCK" |
  tail -1 | cut -d: -f1)
action_readonly_line=$(grep -n 'Read-only publication verification' <<<"$PUBLISH_BLOCK" |
  head -1 | cut -d: -f1)
[ -n "$action_deep_line" ] && [ -n "$action_publish_line" ] &&
  [ -n "$action_readonly_line" ] &&
  [ "$action_deep_line" -lt "$action_publish_line" ] &&
  [ "$action_publish_line" -lt "$action_readonly_line" ] ||
  fail "action publication ordering is not statically provable"

recovery_deep_first=$(grep -n 'verify-release-resume-state.sh' <<<"$RECOVERY_BLOCK" |
  sed -n '1p' | cut -d: -f1)
recovery_canonicalize=$(grep -n 'mutate-release-metadata.sh canonicalize' \
  <<<"$RECOVERY_BLOCK" | head -1 | cut -d: -f1)
recovery_deep_second=$(grep -n 'verify-release-resume-state.sh' <<<"$RECOVERY_BLOCK" |
  sed -n '2p' | cut -d: -f1)
recovery_publish=$(grep -n 'mutate-release-metadata.sh publish' <<<"$RECOVERY_BLOCK" |
  tail -1 | cut -d: -f1)
recovery_readonly=$(grep -n 'Read-only recovery verification' <<<"$RECOVERY_BLOCK" |
  head -1 | cut -d: -f1)
[ -n "$recovery_deep_first" ] && [ -n "$recovery_canonicalize" ] &&
  [ -n "$recovery_deep_second" ] && [ -n "$recovery_publish" ] &&
  [ -n "$recovery_readonly" ] &&
  [ "$recovery_deep_first" -lt "$recovery_canonicalize" ] &&
  [ "$recovery_canonicalize" -lt "$recovery_deep_second" ] &&
  [ "$recovery_deep_second" -lt "$recovery_publish" ] &&
  [ "$recovery_publish" -lt "$recovery_readonly" ] ||
  fail "recovery publication ordering is not statically provable"

CI_WORKFLOW=.github/workflows/ci.yml
require_file "$CI_WORKFLOW"
CI_TEXT=$(sed 's/\r$//' "$CI_WORKFLOW")
grep -Fq 'test-release-resume-state.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the release resume fixtures"
grep -Fq 'test-release-mutation-revalidation.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the mutation revalidation regression"
grep -Fq 'test-release-preaction-routing.sh' <<<"$CI_TEXT" ||
  fail "hosted CI does not run the mock-only pre-action authority matrix"
grep -Fq 'test-resolve-release-descriptor.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the shared resolver fixtures"
grep -Fq 'test-release-descriptor-schema.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the active descriptor schema contract"
grep -Fq 'contents: read' <<<"$CI_TEXT" ||
  fail "hosted pre-action matrix does not have read-only job permissions"
if grep -Fq 'RELEASE_PLEASE_TOKEN' <<<"$CI_TEXT" ||
   grep -Fq 'environment:' <<<"$CI_TEXT"; then
  fail "hosted pre-action matrix references a repository secret or environment"
fi
grep -Fq 'test-oci-referrer-closure.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the OCI referrer closure fixtures"
grep -Fq 'test-ghcr-package-normalization.sh' <<<"$CI_TEXT" ||
  fail "reusable CI does not run the GHCR page-array normalization fixtures"
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
PAT_STEP_NAMES=(
  "Normalize action descriptor with Release Please visibility"
  "Bind canonical-empty materialize entry (read-only Release Please visibility)"
  "Bind canonical-empty materialize upload snapshot (read-only Release Please visibility)"
  "Rebind canonical-empty materialize upload snapshot (read-only Release Please visibility)"
  "Bind post-upload complete snapshot (read-only Release Please visibility)"
  "Bind final materialize publication snapshot (read-only Release Please visibility)"
  "Bind complete deep-recovery entry (read-only Release Please visibility)"
  "Bind observed recovery asset fingerprint"
  "Bind generated-placeholder canonicalization snapshot (read-only Release Please visibility)"
  "Bind canonicalized recovery snapshot (read-only Release Please visibility)"
  "Bind final deep-recovery publication snapshot (read-only Release Please visibility)"
)
step_block() {
  local name=$1
  awk -v wanted="$name" '
    $0 == "      - name: " wanted { found=1; next }
    found && $0 ~ /^      - name:/ { exit }
    found && $0 ~ /^  (gates|publish|recovery):/ { exit }
    found { print }
  ' <<<"$WORKFLOW_TEXT"
}
for pat_step in "${PAT_STEP_NAMES[@]}"; do
  pat_block=$(step_block "$pat_step")
  [ -n "$pat_block" ] ||
    fail "missing named Release Please visibility step: $pat_step"
  grep -Fq 'GH_TOKEN: ${{ secrets.RELEASE_PLEASE_TOKEN }}' <<<"$pat_block" ||
    fail "visibility step is not scoped to RELEASE_PLEASE_TOKEN: $pat_step"
  if grep -Eiq \
      'gh api --method (PATCH|POST|PUT|DELETE)|uploads\.github\.com|gh release (create|edit|upload)|mutate-release-metadata|docker (build|push|tag)|attest|actions/attest' \
      <<<"$pat_block"; then
    fail "Release Please visibility step contains a mutation capability: $pat_step"
  fi
  grep -Fq 'sha256sum' <<<"$pat_block" ||
    fail "visibility step does not bind a digest-checked snapshot: $pat_step"
done
pat_step_count=$(
  grep -F 'GH_TOKEN: ${{ secrets.RELEASE_PLEASE_TOKEN }}' \
    <<<"$WORKFLOW_TEXT" | wc -l | tr -d '[:space:]'
)
[ "$pat_step_count" -eq "$(( ${#PAT_STEP_NAMES[@]} + 1 ))" ] ||
  fail "release workflow has an unexpected number of PAT capability steps"
pre_action_token_count=$(grep -F 'GH_TOKEN: ${{ secrets.RELEASE_PLEASE_TOKEN }}' \
  <<<"$pre_action_block" | wc -l | tr -d '[:space:]')
[ "$pre_action_token_count" -eq 1 ] ||
  fail "pre-action authority does not have exactly one step-scoped PAT"
if [ "$(grep -F 'token: ${{ secrets.RELEASE_PLEASE_TOKEN }}' \
    <<<"$WORKFLOW_TEXT" | wc -l | tr -d '[:space:]')" -ne 1 ]; then
  fail "Release Please must have one dedicated token expression"
fi
grep -Fq -- '--require-action-authority' <<<"$pre_action_block" ||
  fail "only the Release Please pre-action must request action admission"
if grep -Fq 'GITHUB_TOKEN' <<<"$pre_action_block"; then
  fail "action-admission pre-action contains a GITHUB_TOKEN fallback"
fi
MUTATION_STEP_NAMES=(
  "Verify admitted materialize snapshot with GITHUB_TOKEN evidence"
  "Independently verify the numeric draft descriptor from admitted snapshot"
  "Upload the exact evidence set by numeric release ID"
  "Verify post-upload snapshot with GITHUB_TOKEN evidence"
  "Final descriptor and deep admission, then publish last"
  "Verify admitted deep-recovery snapshot with GITHUB_TOKEN evidence"
  "Deep-verify observed recovery state"
  "Canonicalize generated placeholder metadata"
  "Re-verify canonical draft before publish"
  "Publish canonical release metadata last"
)
for mutation_step in "${MUTATION_STEP_NAMES[@]}"; do
  mutation_block=$(step_block "$mutation_step")
  [ -n "$mutation_block" ] ||
    fail "missing named GITHUB_TOKEN mutation/evidence step: $mutation_step"
  grep -Fq 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' <<<"$mutation_block" ||
    fail "mutation/evidence step is not GITHUB_TOKEN-backed: $mutation_step"
  if grep -Fq 'RELEASE_PLEASE_TOKEN' <<<"$mutation_block"; then
    fail "mutation/evidence step receives the release PAT: $mutation_step"
  fi
  if grep -Eq 'resolve-release-descriptor\.sh|revalidate-release-mutation\.sh' \
      <<<"$mutation_block" &&
     ! grep -Fq -- '--release-file "$RELEASE_SNAPSHOT"' <<<"$mutation_block"; then
    fail "mutation/evidence step performs live release admission: $mutation_step"
  fi
done
while IFS= read -r consumer_name; do
  [ -n "$consumer_name" ] || continue
  consumer_block=$(step_block "$consumer_name")
  if grep -Fq 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' <<<"$consumer_block" &&
     grep -Fq -- '--release-file "$RELEASE_SNAPSHOT"' <<<"$consumer_block"; then
    if grep -Fq 'RELEASE_PLEASE_TOKEN' <<<"$consumer_block"; then
      fail "supplied snapshot consumer receives the release PAT: $consumer_name"
    fi
    grep -Fq 'sha256sum "$RELEASE_SNAPSHOT"' <<<"$consumer_block" ||
      fail "supplied snapshot consumer lacks digest verification: $consumer_name"
    grep -Fq 'RELEASE_SNAPSHOT_SHA' <<<"$consumer_block" ||
      fail "supplied snapshot consumer lacks stored digest comparison: $consumer_name"
  fi
done < <(
  awk '
    /^      - name: / {
      name=$0
      sub(/^      - name: /, "", name)
      print name
    }
  ' <<<"$WORKFLOW_TEXT"
)
post_lease_visibility_line=$(grep -n \
  'Rebind canonical-empty materialize upload snapshot' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
upload_line=$(grep -n 'Upload the exact evidence set by numeric release ID' \
  <<<"$WORKFLOW_TEXT" | head -1 | cut -d: -f1)
final_materialize_visibility_line=$(grep -n \
  'Bind final materialize publication snapshot' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
final_materialize_mutation_line=$(grep -n \
  'Final descriptor and deep admission, then publish last' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
canonicalize_visibility_line=$(grep -n \
  'Bind generated-placeholder canonicalization snapshot' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
canonicalize_mutation_line=$(grep -n \
  'Canonicalize generated placeholder metadata' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
final_recovery_visibility_line=$(grep -n \
  'Bind final deep-recovery publication snapshot' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
final_recovery_mutation_line=$(grep -n \
  'Publish canonical release metadata last' <<<"$WORKFLOW_TEXT" |
  head -1 | cut -d: -f1)
[ -n "$post_lease_visibility_line" ] && [ -n "$upload_line" ] &&
  [ "$post_lease_visibility_line" -lt "$upload_line" ] ||
  fail "materialize upload has no fresh post-lease PAT admission"
adjacent_step_count=$(
  sed -n "${post_lease_visibility_line},${upload_line}p" <<<"$WORKFLOW_TEXT" |
    grep -E '^[[:space:]]+- name:' | wc -l | tr -d '[:space:]'
)
[ "$adjacent_step_count" -eq 2 ] ||
  fail "materialize upload PAT admission is not immediately adjacent"
[ -n "$final_materialize_visibility_line" ] &&
  [ -n "$final_materialize_mutation_line" ] &&
  [ "$final_materialize_visibility_line" -lt "$final_materialize_mutation_line" ] ||
  fail "materialize publication has no immediate PAT admission"
[ -n "$canonicalize_visibility_line" ] &&
  [ -n "$canonicalize_mutation_line" ] &&
  [ "$canonicalize_visibility_line" -lt "$canonicalize_mutation_line" ] ||
  fail "placeholder canonicalization has no immediate PAT admission"
[ -n "$final_recovery_visibility_line" ] &&
  [ -n "$final_recovery_mutation_line" ] &&
  [ "$final_recovery_visibility_line" -lt "$final_recovery_mutation_line" ] ||
  fail "deep recovery publication has no immediate PAT admission"
for snapshot_consumer in \
  "Deep-verify observed recovery state" \
  "Canonicalize generated placeholder metadata" \
  "Re-verify canonical draft before publish" \
  "Publish canonical release metadata last"; do
  consumer_block=$(step_block "$snapshot_consumer")
  grep -Fq 'sha256sum "$RELEASE_SNAPSHOT"' <<<"$consumer_block" ||
    fail "deep-recovery snapshot consumer lacks digest verification: $snapshot_consumer"
  grep -Fq 'RELEASE_SNAPSHOT_SHA' <<<"$consumer_block" ||
    fail "deep-recovery snapshot consumer lacks stored digest comparison: $snapshot_consumer"
done
workflow_action_option_count=$(
  grep -R -h --include='*.yml' --include='*.yaml' \
    -- '--require-action-authority' .github/workflows |
    wc -l | tr -d '[:space:]'
)
[ "$workflow_action_option_count" -eq 1 ] ||
  fail "more than one workflow caller can request action admission"
if grep -Fq -- '--require-action-authority' <<<"$RECOVERY_TEXT" ||
   grep -Fq -- '--require-action-authority' \
     scripts/mutate-release-metadata.sh; then
  fail "recovery-only callers request action admission"
fi
grep -Fq 'GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}' <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must remain GITHUB_TOKEN-backed"
if grep -Fq 'RELEASE_PLEASE_TOKEN' <<<"$RECOVERY_TEXT"; then
  fail "manual recovery must not receive the release PAT"
fi
grep -Fq 'workflow_dispatch:' <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must remain workflow_dispatch-only"
grep -Fq "github.ref == 'refs/heads/master'" <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must remain bound to master"
grep -Fq 'contents: read' <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must retain contents:read"
grep -Fq 'packages: read' <<<"$RECOVERY_TEXT" ||
  fail "manual recovery must retain packages:read"
if grep -Eiq \
    'contents: write|packages: write|attestations: write|id-token: write|googleapis/release-please-action|mutate-release-metadata|gh api --method (PATCH|POST|PUT|DELETE)|gh release (create|edit|upload)|docker (push|build)' \
    <<<"$RECOVERY_TEXT"; then
  fail "manual recovery contains an action or mutation construct"
fi
grep -Fq 'recovery-only-visible-placeholder-audit' \
  <<<"$PRE_ACTION_FIXTURES" ||
  fail "pre-action fixtures are missing the successful recovery audit case"
grep -Fq 'recovery-only-zero-candidate-safe-failure' \
  <<<"$PRE_ACTION_FIXTURES" ||
  fail "pre-action fixtures are missing the recovery-only zero-candidate case"
for fixture in \
  injected-malformed-release-item \
  injected-malformed-release-result \
  live-malformed-page \
  live-malformed-release-item; do
  grep -Fq "\"$fixture\"" <<<"$PRE_ACTION_FIXTURES" ||
    fail "pre-action fixtures are missing malformed enumeration case: $fixture"
done
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
