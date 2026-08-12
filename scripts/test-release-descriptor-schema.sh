#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER=$ROOT_DIR/scripts/resolve-release-descriptor.sh
FIXTURE_DIR=$ROOT_DIR/scripts/fixtures/release-descriptor-schema
SCENARIOS=$FIXTURE_DIR/scenarios.json
EXPECTED_KEYS=$FIXTURE_DIR/active-keys.txt
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT

fail() {
  echo "release descriptor schema contract failed: $1" >&2
  exit 1
}

for command in git jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[ -x "$RESOLVER" ] || fail "resolver is missing or not executable"
jq -e 'type == "object" and length > 0' "$SCENARIOS" >/dev/null ||
  fail "scenario fixture is malformed"
[ "$(wc -l <"$EXPECTED_KEYS" | tr -d '[:space:]')" -eq 20 ] ||
  fail "active schema fixture must contain exactly 20 keys"
[ "$(sort "$EXPECTED_KEYS" | uniq | wc -l | tr -d '[:space:]')" -eq 20 ] ||
  fail "active schema fixture contains duplicate keys"

export GIT_AUTHOR_NAME='Descriptor Schema Fixture'
export GIT_AUTHOR_EMAIL='descriptor-schema@example.invalid'
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

REPO=$TMP/repo
git init -q "$REPO"
git -C "$REPO" config core.autocrlf false
echo '{".":"1.0.0"}' >"$REPO/.release-please-manifest.json"
echo '{"version":"1.0.0"}' >"$REPO/version.json"
git -C "$REPO" add .release-please-manifest.json version.json
git -C "$REPO" commit -qm bootstrap
echo '{".":"1.0.1"}' >"$REPO/.release-please-manifest.json"
echo '{"version":"1.0.1"}' >"$REPO/version.json"
git -C "$REPO" add .release-please-manifest.json version.json
git -C "$REPO" commit -qm release
SOURCE=$(git -C "$REPO" rev-parse HEAD)

EMPTY=$TMP/empty.json
COMPLETE=$TMP/complete.json
PLACEHOLDER=$TMP/placeholder.json
REFS=$TMP/refs.json
RELEASES=$TMP/releases.json

jq -n --arg source "$SOURCE" '{
  id: 102,
  tag_name: "v1.0.1",
  target_commitish: $source,
  draft: true,
  prerelease: false,
  published_at: null,
  assets: []
}' >"$EMPTY"
jq '.assets = [
  {"name":"release-manifest.json","id":201,"size":101,"state":"uploaded","created_at":"2026-08-10T01:00:00Z","updated_at":"2026-08-10T01:00:00Z","url":"https://api.github.test/releases/assets/201"},
  {"name":"image-index.json","id":202,"size":102,"state":"uploaded","created_at":"2026-08-10T01:00:00Z","updated_at":"2026-08-10T01:00:00Z","url":"https://api.github.test/releases/assets/202"},
  {"name":"image-inspect.txt","id":203,"size":103,"state":"uploaded","created_at":"2026-08-10T01:00:00Z","updated_at":"2026-08-10T01:00:00Z","url":"https://api.github.test/releases/assets/203"},
  {"name":"SHA256SUMS","id":204,"size":104,"state":"uploaded","created_at":"2026-08-10T01:00:00Z","updated_at":"2026-08-10T01:00:00Z","url":"https://api.github.test/releases/assets/204"}
]' "$EMPTY" >"$COMPLETE"
jq '.tag_name = "untagged-0123456789abcdef0123"' "$COMPLETE" >"$PLACEHOLDER"
echo '{"refs":{},"tags":{}}' >"$REFS"

value() {
  local key=$1 descriptor=$2
  awk -F= -v key="$key" '$1 == key {
    sub(/^[^=]*=/, "")
    print
  }' <<<"$descriptor"
}

jq_value() {
  jq -r "$@" | tr -d '\r'
}

validate_contract() {
  local name=$1 descriptor=$2 expected_route=$3 expected_origin=$4
  local expected_state=$5 expected_kind=$6 actual_keys inventory
  actual_keys=$TMP/actual-keys
  sed -n 's/^\([^=]*\)=.*$/\1/p' <<<"$descriptor" >"$actual_keys"
  cmp -s "$EXPECTED_KEYS" "$actual_keys" ||
    fail "$name changed the exact active key set or order"
  [ "$(wc -l <"$actual_keys" | tr -d '[:space:]')" -eq 20 ] ||
    fail "$name did not emit exactly 20 fields"
  [ "$(sort "$actual_keys" | uniq | wc -l | tr -d '[:space:]')" -eq 20 ] ||
    fail "$name emitted a duplicate field"

  [ "$(value route "$descriptor")" = "$expected_route" ] ||
    fail "$name emitted the wrong route"
  [ "$(value active "$descriptor")" = true ] ||
    fail "$name is not active"
  [ "$(value origin "$descriptor")" = "$expected_origin" ] ||
    fail "$name emitted the wrong origin"
  [ "$(value observed_state "$descriptor")" = "$expected_state" ] ||
    fail "$name emitted the wrong observed state"
  [ "$(value release_id "$descriptor")" = 102 ] ||
    fail "$name emitted the wrong release ID"
  [ "$(value tag "$descriptor")" = v1.0.1 ] ||
    fail "$name emitted the wrong canonical tag"
  [ "$(value version "$descriptor")" = 1.0.1 ] ||
    fail "$name emitted the wrong version"
  [ "$(value source_sha "$descriptor")" = "$SOURCE" ] &&
    [ "$(value target_commitish "$descriptor")" = "$SOURCE" ] &&
    [ "$(value authority_source_sha "$descriptor")" = "$SOURCE" ] ||
    fail "$name source authority tuple diverged"
  [ "$(value authority_version "$descriptor")" = 1.0.1 ] &&
    [ "$(value authority_tag "$descriptor")" = v1.0.1 ] ||
    fail "$name canonical authority tuple diverged"
  [ "$(value draft "$descriptor")" = true ] &&
    [ "$(value prerelease "$descriptor")" = false ] &&
    [ "$(value published_at "$descriptor")" = null ] ||
    fail "$name publication state diverged"
  [ "$(value asset_inventory_kind "$descriptor")" = "$expected_kind" ] ||
    fail "$name emitted the wrong inventory kind"
  [[ "$(value asset_inventory_fingerprint "$descriptor")" =~ ^[0-9a-f]{64}$ ]] ||
    fail "$name emitted a malformed inventory fingerprint"
  [[ "$(value admission_fingerprint "$descriptor")" =~ ^[0-9a-f]{64}$ ]] ||
    fail "$name emitted a malformed admission fingerprint"
  inventory=$(value asset_inventory_json "$descriptor")
  jq -e 'type == "array"' >/dev/null <<<"$inventory" ||
    fail "$name emitted malformed inventory JSON"
  if [ "$expected_kind" = empty ]; then
    [ "$(jq 'length' <<<"$inventory")" -eq 0 ] ||
      fail "$name empty inventory is not empty"
  else
    [ "$(jq 'length' <<<"$inventory")" -eq 4 ] ||
      fail "$name complete inventory does not contain four assets"
  fi
}

validate_shape() {
  local name=$1 descriptor=$2 actual_keys unique_keys
  actual_keys=$TMP/$name-keys
  unique_keys=$TMP/$name-unique-keys
  sed -n 's/^\([^=]*\)=.*$/\1/p' <<<"$descriptor" >"$actual_keys"
  cmp -s "$EXPECTED_KEYS" "$actual_keys" || return 1
  [ "$(wc -l <"$actual_keys" | tr -d '[:space:]')" -eq 20 ] || return 1
  sort "$actual_keys" | uniq >"$unique_keys"
  [ "$(wc -l <"$unique_keys" | tr -d '[:space:]')" -eq 20 ]
}

expect_invalid_shape() {
  local name=$1 descriptor=$2
  if validate_contract "$name" "$descriptor" materialize created canonical empty \
      >/dev/null 2>&1; then
    fail "negative contract case unexpectedly passed: $name"
  fi
  echo "ok - negative $name"
}

legacy_admission_fingerprint() {
  local descriptor=$1
  local route state observed_tag id tag version source target draft prerelease published
  local kind inventory_fingerprint
  route=$(value route "$descriptor")
  state=$(value observed_state "$descriptor")
  observed_tag=$(value observed_tag "$descriptor")
  id=$(value release_id "$descriptor")
  tag=$(value tag "$descriptor")
  version=$(value version "$descriptor")
  source=$(value source_sha "$descriptor")
  target=$(value target_commitish "$descriptor")
  draft=$(value draft "$descriptor")
  prerelease=$(value prerelease "$descriptor")
  published=$(value published_at "$descriptor")
  kind=$(value asset_inventory_kind "$descriptor")
  inventory_fingerprint=$(value asset_inventory_fingerprint "$descriptor")
  jq -nc \
    --arg publication_route "$route" \
    --arg observed_state "$state" \
    --arg observed_tag "$observed_tag" \
    --arg release_id "$id" \
    --arg tag "$tag" \
    --arg version "$version" \
    --arg source_sha "$source" \
    --arg target_commitish "$target" \
    --arg draft "$draft" \
    --arg prerelease "$prerelease" \
    --arg published_at "$published" \
    --arg asset_inventory_kind "$kind" \
    --arg asset_inventory_fingerprint "$inventory_fingerprint" \
    '{
      publication_route: $publication_route,
      observed_state: $observed_state,
      observed_tag: $observed_tag,
      release_id: $release_id,
      tag: $tag,
      version: $version,
      source_sha: $source_sha,
      target_commitish: $target_commitish,
      draft: $draft,
      prerelease: $prerelease,
      published_at: $published_at,
      asset_inventory_kind: $asset_inventory_kind,
      asset_inventory_fingerprint: $asset_inventory_fingerprint
    }' | sha256sum | awk '{print $1}'
}

while IFS= read -r name; do
  name=${name%$'\r'}
  mode=$(jq_value --arg name "$name" '.[$name].mode' "$SCENARIOS")
  release_kind=$(jq_value --arg name "$name" '.[$name].release' "$SCENARIOS")
  expected_route=$(jq_value --arg name "$name" '.[$name].expectedRoute' "$SCENARIOS")
  expected_origin=$(jq_value --arg name "$name" '.[$name].expectedOrigin' "$SCENARIOS")
  expected_state=$(jq_value --arg name "$name" '.[$name].expectedState' "$SCENARIOS")
  expected_kind=$(jq_value --arg name "$name" '.[$name].expectedInventoryKind' "$SCENARIOS")
  case "$release_kind" in
    empty) release_file=$EMPTY ;;
    complete) release_file=$COMPLETE ;;
    placeholder) release_file=$PLACEHOLDER ;;
    *) fail "$name has an unsupported release fixture" ;;
  esac
  jq -s '.' "$release_file" >"$RELEASES"
  common=(--repo-dir "$REPO" --dev-ref HEAD --refs-file "$REFS")
  case "$mode" in
    created)
      descriptor=$("$RESOLVER" created \
        --release-id 102 --tag v1.0.1 --version 1.0.1 \
        --source-sha "$SOURCE" --release-file "$release_file" "${common[@]}")
      ;;
    post-action)
      descriptor=$("$RESOLVER" post-action \
        --tag v1.0.1 --version 1.0.1 --source-sha "$SOURCE" \
        --releases-file "$RELEASES" "${common[@]}")
      ;;
    recover|pre-action)
      descriptor=$("$RESOLVER" "$mode" \
        --releases-file "$RELEASES" "${common[@]}")
      ;;
    verify)
      fingerprint=$("$ROOT_DIR/scripts/release-asset-inventory.sh" \
        fingerprint --allow-empty --release-file "$release_file")
      descriptor=$("$RESOLVER" verify \
        --release-id 102 --tag v1.0.1 --version 1.0.1 \
        --source-sha "$SOURCE" --asset-inventory-fingerprint "$fingerprint" \
        --expected-route "$expected_route" --release-file "$release_file" \
        "${common[@]}")
      ;;
    *) fail "$name has an unsupported resolver mode" ;;
  esac
  validate_contract "$name" "$descriptor" "$expected_route" "$expected_origin" \
    "$expected_state" "$expected_kind"
  if [ "$expected_state" = generated_placeholder ]; then
    [ "$(value admission_fingerprint "$descriptor")" = \
      "$(legacy_admission_fingerprint "$descriptor")" ] ||
      fail "$name changed generated-placeholder admission fingerprint semantics"
  fi
  echo "ok - $name"
done < <(jq -r 'to_entries[] | select(.value | type == "object" and has("mode")) | .key' \
  "$SCENARIOS" | tr -d '\r')

BASE_DESCRIPTOR=$("$RESOLVER" created \
  --release-id 102 --tag v1.0.1 --version 1.0.1 \
  --source-sha "$SOURCE" --release-file "$EMPTY" \
  --repo-dir "$REPO" --dev-ref HEAD --refs-file "$REFS")
expect_invalid_shape missing "$(sed '/^prerelease=/d' <<<"$BASE_DESCRIPTOR")"
expect_invalid_shape extra "$(printf '%s\nunknown=field' "$BASE_DESCRIPTOR")"
expect_invalid_shape duplicate "$(printf '%s\n' "$BASE_DESCRIPTOR" \
  "$(sed -n '1p' <<<"$BASE_DESCRIPTOR")")"
expect_invalid_shape reordered "$(printf '%s\n' \
  "$(sed -n '2p' <<<"$BASE_DESCRIPTOR")" \
  "$(sed -n '1p' <<<"$BASE_DESCRIPTOR")" \
  "$(sed -n '3,$p' <<<"$BASE_DESCRIPTOR")")"
expect_invalid_shape divergent "$(sed 's/^tag=.*/tag=v9.9.9/' \
  <<<"$BASE_DESCRIPTOR")"
expect_invalid_shape partial "$(sed 's/^.*$//' <<<"$BASE_DESCRIPTOR")"

echo "$(jq '[to_entries[] | select(.value | type == "object" and has("mode"))] | length' \
  "$SCENARIOS") active descriptor schema contracts passed"
