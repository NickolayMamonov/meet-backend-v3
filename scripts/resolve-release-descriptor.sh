#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ASSET_INVENTORY_HELPER=$SCRIPT_DIR/release-asset-inventory.sh

fail() {
  echo "release descriptor resolution failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  resolve-release-descriptor.sh created --release-id ID --tag TAG --version VERSION --source-sha SHA [options]
  resolve-release-descriptor.sh post-action --tag TAG --version VERSION --source-sha SHA [options]
  resolve-release-descriptor.sh recover [options]
  resolve-release-descriptor.sh pre-action [options]
  resolve-release-descriptor.sh verify --release-id ID --tag TAG --version VERSION --source-sha SHA --asset-inventory-fingerprint SHA256 [options]

options:
  --repo-dir PATH       source Git repository (default: .)
  --dev-ref REF         exact authoritative dev ref (default: origin/dev)
  --repository OWNER/REPO
  --repository-file PATH  injected authenticated repository authority object
  --release-file PATH   injected single GitHub release object
  --releases-file PATH  injected GitHub release array
  --refs-file PATH      injected tag/ref object; omitted means live GitHub API
  --require-action-authority
                         action-admission proof (pre-action only)
  --expected-route ROUTE
                         verify the resolver-owned publication route
  --expected-admission-fingerprint SHA256
                         verify the stable write-entry admission fingerprint
EOF
  exit 2
}

command -v git >/dev/null 2>&1 || fail "git is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"

[ "$#" -ge 1 ] || usage
MODE=$1
shift
case "$MODE" in
  created|post-action|recover|pre-action|verify) ;;
  *) usage ;;
esac

REPO_DIR=.
DEV_REF=origin/dev
REPOSITORY=${GITHUB_REPOSITORY:-}
REPOSITORY_FILE=
RELEASE_FILE=
RELEASES_FILE=
REFS_FILE=
REQUIRE_ACTION_AUTHORITY=false
EXPECTED_ID=
EXPECTED_TAG=
EXPECTED_VERSION=
EXPECTED_SOURCE=
EXPECTED_FINGERPRINT=
EXPECTED_ROUTE=
EXPECTED_ADMISSION_FINGERPRINT=
RELEASE_ID_OPTION=false
RELEASE_FILE_OPTION=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir) [ "$#" -ge 2 ] || usage; REPO_DIR=$2; shift 2 ;;
    --dev-ref) [ "$#" -ge 2 ] || usage; DEV_REF=$2; shift 2 ;;
    --repository) [ "$#" -ge 2 ] || usage; REPOSITORY=$2; shift 2 ;;
    --repository-file) [ "$#" -ge 2 ] || usage; REPOSITORY_FILE=$2; shift 2 ;;
    --release-file)
      [ "$#" -ge 2 ] || usage
      RELEASE_FILE=$2
      RELEASE_FILE_OPTION=true
      shift 2
      ;;
    --releases-file) [ "$#" -ge 2 ] || usage; RELEASES_FILE=$2; shift 2 ;;
    --refs-file) [ "$#" -ge 2 ] || usage; REFS_FILE=$2; shift 2 ;;
    --require-action-authority) REQUIRE_ACTION_AUTHORITY=true; shift ;;
    --release-id)
      [ "$#" -ge 2 ] || usage
      EXPECTED_ID=$2
      RELEASE_ID_OPTION=true
      shift 2
      ;;
    --tag) [ "$#" -ge 2 ] || usage; EXPECTED_TAG=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; EXPECTED_VERSION=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; EXPECTED_SOURCE=$2; shift 2 ;;
    --asset-inventory-fingerprint)
      [ "$#" -ge 2 ] || usage
      EXPECTED_FINGERPRINT=$2
      shift 2
      ;;
    --expected-route)
      [ "$#" -ge 2 ] || usage
      EXPECTED_ROUTE=$2
      shift 2
      ;;
    --expected-admission-fingerprint)
      [ "$#" -ge 2 ] || usage
      EXPECTED_ADMISSION_FINGERPRINT=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[ "$MODE" = pre-action ] || [ "$REQUIRE_ACTION_AUTHORITY" = false ] ||
  usage
[ "$MODE" = pre-action ] || [ -z "$REPOSITORY_FILE" ] ||
  usage
[ "$MODE" != post-action ] ||
  { [ "$RELEASE_ID_OPTION" = false ] && [ "$RELEASE_FILE_OPTION" = false ]; } ||
  usage

git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "repo-dir is not a Git work tree"
DEV_SHA=$(git -C "$REPO_DIR" rev-parse --verify "${DEV_REF}^{commit}" 2>/dev/null) ||
  fail "authoritative dev ref is missing"
[[ "$DEV_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "authoritative dev ref is not a full commit"

canonical_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

read_pair() {
  local commit=$1 manifest version
  manifest=$(git -C "$REPO_DIR" show "$commit:.release-please-manifest.json" 2>/dev/null) ||
    return 1
  version=$(git -C "$REPO_DIR" show "$commit:version.json" 2>/dev/null) ||
    return 1
  jq -e 'type == "object" and length == 1 and
    (.["."] | type == "string")' >/dev/null <<<"$manifest" || return 1
  jq -e 'type == "object" and length == 1 and
    (.version | type == "string")' >/dev/null <<<"$version" || return 1
  printf '%s\t%s\n' \
    "$(jq -r '.["."]' <<<"$manifest")" \
    "$(jq -r '.version' <<<"$version")"
}

TIP_PAIR=$(read_pair "$DEV_SHA") ||
  fail "authority files are missing or malformed at the exact dev ref"
IFS=$'\t' read -r AUTHORITY_VERSION VERSION_FILE_VERSION <<<"$TIP_PAIR"
canonical_version "$AUTHORITY_VERSION" ||
  fail "manifest authority version is not canonical SemVer"
[ "$AUTHORITY_VERSION" = "$VERSION_FILE_VERSION" ] ||
  fail "manifest and version.json disagree at the exact dev ref"
AUTHORITY_TAG=v$AUTHORITY_VERSION

mapfile -t FIRST_PARENT < <(git -C "$REPO_DIR" rev-list --first-parent "$DEV_SHA")
[ "${#FIRST_PARENT[@]}" -gt 0 ] || fail "authoritative first-parent history is empty"
BOUNDARIES=()
for commit in "${FIRST_PARENT[@]}"; do
  pair=$(read_pair "$commit" 2>/dev/null || true)
  [ "$pair" = "$AUTHORITY_VERSION"$'\t'"$AUTHORITY_VERSION" ] || continue
  parent=$(git -C "$REPO_DIR" rev-parse "${commit}^1" 2>/dev/null || true)
  parent_pair=
  [ -z "$parent" ] || parent_pair=$(read_pair "$parent" 2>/dev/null || true)
  if [ "$parent_pair" != "$AUTHORITY_VERSION"$'\t'"$AUTHORITY_VERSION" ]; then
    BOUNDARIES+=("$commit")
  fi
done
[ "${#BOUNDARIES[@]}" -eq 1 ] ||
  fail "authority has a missing or ambiguous first-parent boundary"
AUTHORITY_SOURCE=${BOUNDARIES[0]}

BOUNDARY_PARENT=$(git -C "$REPO_DIR" rev-parse "${AUTHORITY_SOURCE}^1" \
  2>/dev/null || true)
if [ -n "$BOUNDARY_PARENT" ]; then
  changed=$(git -C "$REPO_DIR" diff --name-only \
    "$BOUNDARY_PARENT" "$AUTHORITY_SOURCE")
else
  changed=$(git -C "$REPO_DIR" diff-tree --root --no-commit-id --name-only -r \
    "$AUTHORITY_SOURCE")
fi
grep -Fx '.release-please-manifest.json' <<<"$changed" >/dev/null ||
  fail "authority boundary did not change the manifest"
grep -Fx 'version.json' <<<"$changed" >/dev/null ||
  fail "authority boundary did not change version.json"

for commit in "${FIRST_PARENT[@]}"; do
  pair=$(read_pair "$commit" 2>/dev/null || true)
  [ "$pair" = "$AUTHORITY_VERSION"$'\t'"$AUTHORITY_VERSION" ] ||
    fail "authority drift exists after the release boundary"
  [ "$commit" = "$AUTHORITY_SOURCE" ] && break
done

semver_compare() {
  local left=$1 right=$2 left_part right_part index
  local -a left_parts right_parts
  IFS=. read -r -a left_parts <<<"$left"
  IFS=. read -r -a right_parts <<<"$right"
  for index in 0 1 2; do
    left_part=${left_parts[$index]}
    right_part=${right_parts[$index]}
    if [ "${#left_part}" -lt "${#right_part}" ]; then echo -1; return; fi
    if [ "${#left_part}" -gt "${#right_part}" ]; then echo 1; return; fi
    if [[ "$left_part" < "$right_part" ]]; then echo -1; return; fi
    if [[ "$left_part" > "$right_part" ]]; then echo 1; return; fi
  done
  echo 0
}

load_release_by_id() {
  local id=$1
  if [ -n "$RELEASE_FILE" ]; then
    jq -e --argjson id "$id" '.id == $id' "$RELEASE_FILE" >/dev/null ||
      fail "injected release does not match the requested numeric ID"
    jq -c . "$RELEASE_FILE"
    return
  fi
  [ -n "$REPOSITORY" ] || fail "repository is required for live API reads"
  command -v gh >/dev/null 2>&1 || fail "gh is required for live API reads"
  gh api "repos/$REPOSITORY/releases/$id"
}

prove_action_authority() {
  local authority
  [ "$REQUIRE_ACTION_AUTHORITY" = true ] || return 0
  [ -n "${GH_TOKEN:-}" ] ||
    fail "action authority credential is missing or empty"
  case "${GH_TOKEN:-}" in
    *[[:space:]]*) fail "action authority credential contains whitespace" ;;
  esac

  if [ -n "$REPOSITORY_FILE" ]; then
    jq -e 'type == "object"' "$REPOSITORY_FILE" >/dev/null ||
      fail "injected repository authority is not an object"
    authority=$(jq -c . "$REPOSITORY_FILE")
  else
    [ -n "$REPOSITORY" ] || fail "repository is required for action authority"
    command -v gh >/dev/null 2>&1 || fail "gh is required for action authority"
    authority=$(gh api "repos/$REPOSITORY") ||
      fail "authenticated repository authority read failed"
  fi

  jq -e --arg repository "$REPOSITORY" '
    type == "object" and
    (.full_name | type == "string" and . == $repository) and
    (.permissions | type == "object") and
    (.permissions.push | type == "boolean" and . == true)
  ' <<<"$authority" >/dev/null ||
    fail "repository identity or push permission is not positively proven"
}

load_releases() {
  if [ -n "$RELEASES_FILE" ]; then
    jq -e -s '
      length == 1 and
      (.[0] | type == "array" and all(.[]; type == "object"))
    ' "$RELEASES_FILE" >/dev/null ||
      fail "injected releases contain a malformed result or release item"
    jq -c -s '.[0]' "$RELEASES_FILE"
    return
  fi
  [ -n "$REPOSITORY" ] || fail "repository is required for live API reads"
  command -v gh >/dev/null 2>&1 || fail "gh is required for live API reads"
  local pages releases
  pages=$(gh api --paginate --slurp "repos/$REPOSITORY/releases?per_page=100") ||
    fail "paginated release enumeration failed"
  jq -e -s '
    length == 1 and
    (.[0] |
      type == "array" and
      all(.[]; type == "array" and all(.[]; type == "object")))
  ' <<<"$pages" >/dev/null ||
    fail "paginated releases contain a malformed page, result, or release item"
  releases=$(jq -c -s '.[0] | add // []' <<<"$pages") ||
    fail "paginated release reduction failed"
  jq -e -s '
    length == 1 and
    (.[0] | type == "array" and all(.[]; type == "object"))
  ' <<<"$releases" >/dev/null ||
    fail "paginated release reduction produced a malformed result"
  printf '%s\n' "$releases"
}

resolve_tag() {
  local tag=$1 object type sha next depth=0 err
  if [ -n "$REFS_FILE" ]; then
    object=$(jq -c --arg tag "$tag" '.refs[$tag] // null' "$REFS_FILE")
    [ "$object" != null ] || { echo absent; return; }
    while :; do
      type=$(jq -r '.type // empty' <<<"$object")
      sha=$(jq -r '.sha // empty' <<<"$object")
      [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "tag ref contains a malformed object"
      case "$type" in
        commit) echo "$sha"; return ;;
        tag)
          depth=$((depth + 1))
          [ "$depth" -le 16 ] || fail "tag ref cannot be peeled safely"
          next=$(jq -c --arg sha "$sha" '.tags[$sha] // null' "$REFS_FILE")
          [ "$next" != null ] || fail "annotated tag object is missing"
          object=$next
          ;;
        *) fail "tag ref has an unsupported object type" ;;
      esac
    done
  fi

  [ -n "$REPOSITORY" ] || fail "repository is required for live tag reads"
  err=$(mktemp)
  if ! object=$(gh api "repos/$REPOSITORY/git/ref/tags/$tag" 2>"$err"); then
    if grep -q 'HTTP 404' "$err"; then
      rm -f "$err"
      echo absent
      return
    fi
    rm -f "$err"
    fail "GitHub tag API read failed"
  fi
  rm -f "$err"
  object=$(jq -c '.object' <<<"$object")
  while :; do
    type=$(jq -r '.type // empty' <<<"$object")
    sha=$(jq -r '.sha // empty' <<<"$object")
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "tag API returned a malformed object"
    case "$type" in
      commit) echo "$sha"; return ;;
      tag)
        depth=$((depth + 1))
        [ "$depth" -le 16 ] || fail "tag ref cannot be peeled safely"
        object=$(gh api "repos/$REPOSITORY/git/tags/$sha" | jq -c '.object')
        ;;
      *) fail "tag API returned an unsupported object type" ;;
    esac
  done
}

normalize_assets() {
  local release=$1 normalized count kind fingerprint
  normalized=$(
    "$ASSET_INVENTORY_HELPER" canonical-json --allow-empty <<<"$release"
  ) || fail "release asset inventory validation failed"
  count=$(jq 'length' <<<"$normalized") ||
    fail "release asset inventory canonicalization failed"
  if [ "$count" -eq 0 ]; then
    kind=empty
  else
    kind=complete_unverified
  fi
  fingerprint=$(
    "$ASSET_INVENTORY_HELPER" fingerprint --allow-empty <<<"$release"
  ) || fail "release asset inventory fingerprinting failed"
  printf '%s\t%s\t%s\n' "$kind" "$fingerprint" "$normalized"
}

publication_route() {
  local state=$1 kind=$2
  case "$state:$kind" in
    canonical:empty)
      echo materialize
      ;;
    canonical:complete_unverified|generated_placeholder:complete_unverified)
      echo deep-recover
      ;;
    *)
      fail "observed state and asset inventory do not form an admissible publication route"
      ;;
  esac
}

admission_fingerprint() {
  local route=$1 state=$2 observed_tag=$3 id=$4 tag=$5 version=$6
  local source=$7 target=$8 draft=$9 prerelease=${10} published=${11}
  local kind=${12} inventory_fingerprint=${13}
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

validate_release() {
  local release=$1 id tag target draft prerelease published source_pair tag_target
  local asset_data kind
  jq -e '
    type == "object" and
    (has("id") and has("tag_name") and has("target_commitish") and
      has("draft") and has("prerelease") and has("published_at") and
      has("assets")) and
    (.id | type == "number" and floor == . and . > 0) and
    (.tag_name | type == "string") and
    (.target_commitish | type == "string") and
    (.draft | type == "boolean") and
    (.prerelease | type == "boolean") and
    (.published_at | type == "null")
  ' <<<"$release" >/dev/null ||
    fail "release has malformed current-draft field types"
  id=$(jq -r '.id // empty' <<<"$release")
  tag=$(jq -r '.tag_name // empty' <<<"$release")
  target=$(jq -r '.target_commitish // empty' <<<"$release")
  draft=$(jq -r 'if has("draft") then (.draft | tostring) else "missing" end' \
    <<<"$release")
  prerelease=$(jq -r 'if has("prerelease") then .prerelease else "missing" end' \
    <<<"$release")
  published=$(jq -r 'if has("published_at") and .published_at == null then "null"
    else (.published_at // "missing") end' <<<"$release")

  [[ "$id" =~ ^[1-9][0-9]*$ ]] || fail "release ID is not a positive integer"
  [ "$tag" = "$AUTHORITY_TAG" ] || fail "release tag does not match current authority"
  [ "$target" = "$AUTHORITY_SOURCE" ] ||
    fail "release target does not match the current authority boundary"
  [ "$draft" = true ] || fail "release is not draft"
  [ "$prerelease" = false ] || fail "release is not a canonical non-prerelease"
  [ "$published" = null ] || fail "release is already published"
  git -C "$REPO_DIR" cat-file -e "${target}^{commit}" 2>/dev/null ||
    fail "release target commit is unavailable"
  git -C "$REPO_DIR" merge-base --is-ancestor "$target" "$DEV_SHA" ||
    fail "release target is not reachable from the exact dev ref"
  source_pair=$(read_pair "$target") ||
    fail "release target authority files are missing or malformed"
  [ "$source_pair" = "$AUTHORITY_VERSION"$'\t'"$AUTHORITY_VERSION" ] ||
    fail "release target files do not match current authority"
  tag_target=$(resolve_tag "$tag") || return 1
  [ "$tag_target" = absent ] || [ "$tag_target" = "$target" ] ||
    fail "existing tag does not resolve to the release source"
  asset_data=$(normalize_assets "$release") || return 1
  printf '%s\t%s\t%s\t%s\tcanonical\n' "$id" "$tag" "$target" "$asset_data"
}

validate_completed_release() {
  local release=$1 id tag target draft prerelease published source_pair tag_target asset_data kind
  jq -e '
    type == "object" and
    (has("id") and has("tag_name") and has("target_commitish") and
      has("draft") and has("prerelease") and has("published_at") and
      has("assets")) and
    (.id | type == "number" and floor == . and . > 0) and
    (.tag_name | type == "string") and
    (.target_commitish | type == "string") and
    (.draft | type == "boolean" and . == false) and
    (.prerelease | type == "boolean" and . == false) and
    (.published_at | type == "string" and length > 0)
  ' <<<"$release" >/dev/null ||
    fail "published release has malformed field types"
  id=$(jq -r '.id // empty' <<<"$release")
  tag=$(jq -r '.tag_name // empty' <<<"$release")
  target=$(jq -r '.target_commitish // empty' <<<"$release")
  draft=$(jq -r 'if has("draft") then (.draft | tostring) else "missing" end' \
    <<<"$release")
  prerelease=$(jq -r 'if has("prerelease") then .prerelease else "missing" end' \
    <<<"$release")
  published=$(jq -r '.published_at // empty' <<<"$release")

  [[ "$id" =~ ^[1-9][0-9]*$ ]] || fail "published release ID is not a positive integer"
  [ "$tag" = "$AUTHORITY_TAG" ] ||
    fail "published release tag does not match current authority"
  [ "$target" = "$AUTHORITY_SOURCE" ] ||
    fail "published release target does not match current authority"
  [ "$draft" = false ] || fail "completed release still reports draft state"
  [ "$prerelease" = false ] || fail "completed release is a prerelease"
  [ -n "$published" ] || fail "completed release has no publication timestamp"
  source_pair=$(read_pair "$target") ||
    fail "published release target authority files are missing or malformed"
  [ "$source_pair" = "$AUTHORITY_VERSION"$'\t'"$AUTHORITY_VERSION" ] ||
    fail "published release source files do not match current authority"
  tag_target=$(resolve_tag "$tag") || return 1
  [ "$tag_target" = "$target" ] ||
    fail "published release tag does not resolve to its authority source"
  asset_data=$(normalize_assets "$release") || return 1
  [ "${asset_data%%$'\t'*}" = complete_unverified ] ||
    fail "published authority release lacks the complete evidence inventory"
  printf '%s\n' "$id"
}

validate_pre_action_candidate() {
  local release=$1 id tag target draft prerelease published source_pair tag_target asset_data
  id=$(jq -r '.id // empty' <<<"$release")
  tag=$(jq -r '.tag_name // empty' <<<"$release")
  target=$(jq -r '.target_commitish // empty' <<<"$release")
  draft=$(jq -r 'if has("draft") then (.draft | tostring) else "missing" end' \
    <<<"$release")
  jq -e '
    type == "object" and
    has("prerelease") and
    (.prerelease | type == "boolean" and . == false)
  ' <<<"$release" >/dev/null ||
    fail "pre-action candidate has malformed prerelease state"
  prerelease=$(jq -r '.prerelease' <<<"$release")
  published=$(jq -r 'if has("published_at") and .published_at == null then "null"
    else (.published_at // "missing") end' <<<"$release")

  [[ "$id" =~ ^[1-9][0-9]*$ ]] ||
    fail "pre-action candidate has an invalid release ID"
  [ "$target" = "$AUTHORITY_SOURCE" ] ||
    fail "pre-action candidate target does not match current authority"
  [ "$draft" = true ] || fail "pre-action candidate is not a draft"
  [ "$prerelease" = false ] ||
    fail "pre-action candidate is a prerelease or has malformed state"
  [ "$published" = null ] ||
    fail "pre-action candidate is already published"
  git -C "$REPO_DIR" cat-file -e "${target}^{commit}" 2>/dev/null ||
    fail "pre-action candidate target is unavailable"
  source_pair=$(read_pair "$target") ||
    fail "pre-action candidate target authority files are unavailable"
  [ "$source_pair" = "$AUTHORITY_VERSION"$'\t'"$AUTHORITY_VERSION" ] ||
    fail "pre-action candidate target is not current authority"

  case "$tag" in
    "$AUTHORITY_TAG")
      OBSERVED_STATE=canonical
      tag_target=$(resolve_tag "$tag") || return 1
      [ "$tag_target" = absent ] || [ "$tag_target" = "$target" ] ||
        fail "canonical pre-action candidate tag diverges from source"
      ;;
    untagged-*)
      [[ "$tag" =~ ^untagged-[0-9a-f]{20}$ ]] ||
        fail "generated placeholder tag shape is invalid"
      OBSERVED_STATE=generated_placeholder
      tag_target=$(resolve_tag "$AUTHORITY_TAG") || return 1
      [ "$tag_target" = absent ] ||
        fail "generated placeholder candidate has a materialized canonical ref"
      ;;
    *)
      fail "pre-action candidate tag is neither canonical nor generated placeholder"
      ;;
  esac

  asset_data=$(normalize_assets "$release") || return 1
  kind=${asset_data%%$'\t'*}
  publication_route "$OBSERVED_STATE" "$kind" >/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$tag" "$target" "$asset_data" "$OBSERVED_STATE"
}

emit_pre_action_action() {
  local origin=${1:-pre_action} observed_state=${2:-none} completed_id=${3:-}
  {
    echo "route=action"
    echo "active=false"
    echo "origin=$origin"
    echo "observed_state=$observed_state"
    [ -z "$completed_id" ] || echo "release_id=$completed_id"
    echo "authority_version=$AUTHORITY_VERSION"
    echo "authority_tag=$AUTHORITY_TAG"
    echo "authority_source_sha=$AUTHORITY_SOURCE"
  }
}

emit_pre_action_recovery() {
  local validated=$1 id observed_tag source kind fingerprint inventory state route
  IFS=$'\t' read -r id observed_tag source kind fingerprint inventory state <<<"$validated"
  route=$(publication_route "$state" "$kind")
  {
    echo "route=$route"
    echo "active=true"
    echo "origin=pre_action"
    echo "observed_state=$state"
    echo "observed_tag=$observed_tag"
    echo "release_id=$id"
    echo "tag=$AUTHORITY_TAG"
    echo "version=$AUTHORITY_VERSION"
    echo "source_sha=$source"
    echo "target_commitish=$source"
    echo "draft=true"
    echo "prerelease=false"
    echo "published_at=null"
    echo "authority_version=$AUTHORITY_VERSION"
    echo "authority_tag=$AUTHORITY_TAG"
    echo "authority_source_sha=$AUTHORITY_SOURCE"
    echo "asset_inventory_kind=$kind"
    echo "asset_inventory_fingerprint=$fingerprint"
    echo "asset_inventory_json=$inventory"
    echo "admission_fingerprint=$(admission_fingerprint \
      "$route" "$state" "$observed_tag" "$id" "$AUTHORITY_TAG" \
      "$AUTHORITY_VERSION" "$source" "$source" true false null "$kind" \
      "$fingerprint")"
  }
}

emit_active() {
  local origin=$1 validated=$2 id tag source kind fingerprint inventory state route
  IFS=$'\t' read -r id tag source kind fingerprint inventory state <<<"$validated"
  route=$(publication_route "$state" "$kind")
  {
    echo "active=true"
    echo "origin=$origin"
    echo "route=$route"
    echo "observed_state=$state"
    echo "observed_tag=$tag"
    echo "release_id=$id"
    echo "tag=$tag"
    echo "version=$AUTHORITY_VERSION"
    echo "source_sha=$source"
    echo "target_commitish=$source"
    echo "draft=true"
    echo "published_at=null"
    echo "authority_version=$AUTHORITY_VERSION"
    echo "authority_tag=$AUTHORITY_TAG"
    echo "authority_source_sha=$AUTHORITY_SOURCE"
    echo "asset_inventory_kind=$kind"
    echo "asset_inventory_fingerprint=$fingerprint"
    echo "asset_inventory_json=$inventory"
    echo "admission_fingerprint=$(admission_fingerprint \
      "$route" "$state" "$tag" "$id" "$tag" "$AUTHORITY_VERSION" \
      "$source" "$source" true false null "$kind" "$fingerprint")"
  }
}

require_expected_authority_tuple() {
  canonical_version "$EXPECTED_VERSION" || usage
  [ "$EXPECTED_TAG" = "v$EXPECTED_VERSION" ] || usage
  [[ "$EXPECTED_SOURCE" =~ ^[0-9a-f]{40}$ ]] || usage
  [ "$EXPECTED_VERSION" = "$AUTHORITY_VERSION" ] ||
    fail "requested version does not match current authority"
  [ "$EXPECTED_TAG" = "$AUTHORITY_TAG" ] ||
    fail "requested tag does not match current authority"
  [ "$EXPECTED_SOURCE" = "$AUTHORITY_SOURCE" ] ||
    fail "requested source does not match current authority boundary"
}

require_expected_tuple() {
  [[ "$EXPECTED_ID" =~ ^[1-9][0-9]*$ ]] || usage
  require_expected_authority_tuple
}

is_relevant_release() {
  local release=$1 tag target
  jq -e 'type == "object"' <<<"$release" >/dev/null ||
    fail "release enumeration contains a malformed release item"
  tag=$(jq -r \
    'if (.tag_name | type) == "string" then .tag_name else "" end' \
    <<<"$release")
  target=$(jq -r \
    'if (.target_commitish | type) == "string" then .target_commitish else "" end' \
    <<<"$release")
  [ "$tag" = "$AUTHORITY_TAG" ] || [ "$target" = "$AUTHORITY_SOURCE" ] ||
    {
      [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] &&
        [ "$(semver_compare "${tag#v}" "$AUTHORITY_VERSION")" -gt 0 ]
    }
}

case "$MODE" in
  created)
    require_expected_tuple
    RELEASE=$(load_release_by_id "$EXPECTED_ID")
    VALIDATED=$(validate_release "$RELEASE") ||
      fail "created release failed descriptor validation"
    [ "${VALIDATED%%$'\t'*}" = "$EXPECTED_ID" ] ||
      fail "created release ID drifted"
    emit_active created "$VALIDATED"
    ;;
  post-action)
    require_expected_authority_tuple
    RELEASES=$(load_releases)
    ELIGIBLE=()
    while IFS= read -r release; do
      is_relevant_release "$release" || continue
      validated=$(validate_release "$release") ||
        fail "post-action relevant release failed descriptor validation"
      ELIGIBLE+=("$validated")
    done < <(jq -c '.[]' <<<"$RELEASES")
    [ "${#ELIGIBLE[@]}" -eq 1 ] ||
      fail "post-action requires exactly one current-authority draft"
    IFS=$'\t' read -r actual_id actual_tag actual_source _ <<<"${ELIGIBLE[0]}"
    [[ "$actual_id" =~ ^[1-9][0-9]*$ ]] ||
      fail "post-action returned a non-positive release ID"
    [ "$actual_tag" = "$EXPECTED_TAG" ] ||
      fail "post-action tag does not match the action output"
    [ "$actual_source" = "$EXPECTED_SOURCE" ] ||
      fail "post-action source SHA does not match the action output"
    emit_active post_action "${ELIGIBLE[0]}"
    ;;
  recover)
    RELEASES=$(load_releases)
    ELIGIBLE=()
    COMPLETED=()
    while IFS= read -r release; do
      is_relevant_release "$release" || continue
      if jq -e '.draft == false and .published_at != null' \
          >/dev/null <<<"$release"; then
        completed=$(validate_completed_release "$release") ||
          fail "relevant published release conflicts with current authority"
        COMPLETED+=("$completed")
        continue
      fi
      validated=$(validate_pre_action_candidate "$release") ||
        fail "relevant release failed descriptor validation"
      ELIGIBLE+=("$validated")
    done < <(jq -c '.[]' <<<"$RELEASES")

    if [ "$(( ${#ELIGIBLE[@]} + ${#COMPLETED[@]} ))" -eq 0 ]; then
      {
        echo "route=none"
        echo "active=false"
        echo "origin=none"
        echo "authority_version=$AUTHORITY_VERSION"
        echo "authority_tag=$AUTHORITY_TAG"
        echo "authority_source_sha=$AUTHORITY_SOURCE"
      }
    elif [ "${#ELIGIBLE[@]}" -eq 1 ] && [ "${#COMPLETED[@]}" -eq 0 ]; then
      emit_active recovered "${ELIGIBLE[0]}"
    elif [ "${#ELIGIBLE[@]}" -eq 0 ] && [ "${#COMPLETED[@]}" -eq 1 ]; then
      {
        echo "route=none"
        echo "active=false"
        echo "origin=completed"
        echo "authority_version=$AUTHORITY_VERSION"
        echo "authority_tag=$AUTHORITY_TAG"
        echo "authority_source_sha=$AUTHORITY_SOURCE"
      }
    else
      fail "multiple current-authority release objects are relevant"
    fi
    ;;
  pre-action)
    prove_action_authority
    RELEASES=$(load_releases)
    ELIGIBLE=()
    COMPLETED=()
    while IFS= read -r release; do
      tag=$(jq -r '.tag_name // empty' <<<"$release")
      target=$(jq -r '.target_commitish // empty' <<<"$release")
      relevant=false
      if [ "$tag" = "$AUTHORITY_TAG" ] ||
         [ "$target" = "$AUTHORITY_SOURCE" ] ||
         [[ "$tag" =~ ^untagged- ]]; then
        relevant=true
      elif [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] &&
           [ "$(semver_compare "${tag#v}" "$AUTHORITY_VERSION")" -gt 0 ]; then
        relevant=true
      fi
      [ "$relevant" = true ] || continue
      if jq -e '
        type == "object" and
        (.draft | type == "boolean" and . == false) and
        (.published_at | type == "string" and length > 0)
      ' >/dev/null <<<"$release"; then
        completed=$(validate_completed_release "$release") ||
          fail "relevant published release conflicts with current authority"
        COMPLETED+=("$completed")
        continue
      fi
      validated=$(validate_pre_action_candidate "$release") ||
        fail "current-authority pre-action candidate is invalid"
      ELIGIBLE+=("$validated")
    done < <(jq -c '.[]' <<<"$RELEASES")

    if [ "${#ELIGIBLE[@]}" -eq 0 ] &&
       [ "${#COMPLETED[@]}" -eq 1 ]; then
      if [ "$REQUIRE_ACTION_AUTHORITY" = true ]; then
        emit_pre_action_action completed completed "${COMPLETED[0]}"
      else
        fail "published predecessor requires action authority"
      fi
    elif [ "${#ELIGIBLE[@]}" -eq 0 ] &&
         [ "${#COMPLETED[@]}" -eq 0 ]; then
      canonical_target=$(resolve_tag "$AUTHORITY_TAG") || return 1
      [ "$canonical_target" = absent ] ||
        fail "current canonical tag exists without a release candidate"
      if [ "$REQUIRE_ACTION_AUTHORITY" = true ]; then
        emit_pre_action_action
      else
        fail "no visible recovery candidate; action admission is disabled"
      fi
    elif [ "${#ELIGIBLE[@]}" -eq 1 ] &&
         [ "${#COMPLETED[@]}" -eq 0 ]; then
      emit_pre_action_recovery "${ELIGIBLE[0]}"
    else
      fail "multiple current-authority pre-action states are ambiguous"
    fi
    ;;
  verify)
    require_expected_tuple
    [[ "$EXPECTED_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || usage
    if [ -n "$EXPECTED_ROUTE" ]; then
      case "$EXPECTED_ROUTE" in materialize|deep-recover) ;; *) usage ;; esac
    fi
    if [ -n "$EXPECTED_ADMISSION_FINGERPRINT" ]; then
      [[ "$EXPECTED_ADMISSION_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || usage
    fi
    RELEASE=$(load_release_by_id "$EXPECTED_ID")
    VALIDATED=$(validate_release "$RELEASE") ||
      fail "release failed descriptor revalidation"
    IFS=$'\t' read -r actual_id _ _ _ actual_fingerprint _ <<<"$VALIDATED"
    [ "$actual_id" = "$EXPECTED_ID" ] || fail "release ID drifted"
    [ "$actual_fingerprint" = "$EXPECTED_FINGERPRINT" ] ||
      fail "release asset descriptor drifted"
    OUTPUT=$(emit_active verified "$VALIDATED")
    if [ -n "$EXPECTED_ROUTE" ] &&
       ! grep -Fx "route=$EXPECTED_ROUTE" <<<"$OUTPUT" >/dev/null; then
      fail "release publication route drifted"
    fi
    if [ -n "$EXPECTED_ADMISSION_FINGERPRINT" ] &&
       ! grep -Fx "admission_fingerprint=$EXPECTED_ADMISSION_FINGERPRINT" \
         <<<"$OUTPUT" >/dev/null; then
      fail "release admission fingerprint drifted"
    fi
    printf '%s\n' "$OUTPUT"
    ;;
esac
