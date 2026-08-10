#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "release descriptor resolution failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  resolve-release-descriptor.sh created --release-id ID --tag TAG --version VERSION --source-sha SHA [options]
  resolve-release-descriptor.sh recover [options]
  resolve-release-descriptor.sh pre-action [options]
  resolve-release-descriptor.sh verify --release-id ID --tag TAG --version VERSION --source-sha SHA --asset-inventory-fingerprint SHA256 [options]

options:
  --repo-dir PATH       source Git repository (default: .)
  --dev-ref REF         exact authoritative dev ref (default: origin/dev)
  --repository OWNER/REPO
  --release-file PATH   injected single GitHub release object
  --releases-file PATH  injected GitHub release array
  --refs-file PATH      injected tag/ref object; omitted means live GitHub API
EOF
  exit 2
}

command -v git >/dev/null 2>&1 || fail "git is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

[ "$#" -ge 1 ] || usage
MODE=$1
shift
case "$MODE" in
  created|recover|pre-action|verify) ;;
  *) usage ;;
esac

REPO_DIR=.
DEV_REF=origin/dev
REPOSITORY=${GITHUB_REPOSITORY:-}
RELEASE_FILE=
RELEASES_FILE=
REFS_FILE=
EXPECTED_ID=
EXPECTED_TAG=
EXPECTED_VERSION=
EXPECTED_SOURCE=
EXPECTED_FINGERPRINT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir) [ "$#" -ge 2 ] || usage; REPO_DIR=$2; shift 2 ;;
    --dev-ref) [ "$#" -ge 2 ] || usage; DEV_REF=$2; shift 2 ;;
    --repository) [ "$#" -ge 2 ] || usage; REPOSITORY=$2; shift 2 ;;
    --release-file) [ "$#" -ge 2 ] || usage; RELEASE_FILE=$2; shift 2 ;;
    --releases-file) [ "$#" -ge 2 ] || usage; RELEASES_FILE=$2; shift 2 ;;
    --refs-file) [ "$#" -ge 2 ] || usage; REFS_FILE=$2; shift 2 ;;
    --release-id) [ "$#" -ge 2 ] || usage; EXPECTED_ID=$2; shift 2 ;;
    --tag) [ "$#" -ge 2 ] || usage; EXPECTED_TAG=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; EXPECTED_VERSION=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; EXPECTED_SOURCE=$2; shift 2 ;;
    --asset-inventory-fingerprint)
      [ "$#" -ge 2 ] || usage
      EXPECTED_FINGERPRINT=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

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

load_releases() {
  if [ -n "$RELEASES_FILE" ]; then
    jq -e 'type == "array"' "$RELEASES_FILE" >/dev/null ||
      fail "injected releases must be a JSON array"
    jq -c . "$RELEASES_FILE"
    return
  fi
  [ -n "$REPOSITORY" ] || fail "repository is required for live API reads"
  command -v gh >/dev/null 2>&1 || fail "gh is required for live API reads"
  gh api --paginate --slurp "repos/$REPOSITORY/releases?per_page=100" |
    jq -c 'add // []'
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
  local release=$1 assets count normalized kind fingerprint
  assets=$(jq -c '.assets' <<<"$release")
  jq -e 'type == "array"' >/dev/null <<<"$assets" ||
    fail "release assets are not an array"
  count=$(jq 'length' <<<"$assets")
  if [ "$count" -eq 0 ]; then
    normalized='[]'
    kind=empty
  else
    jq -e '
      length == 4 and
      all(.[];
        type == "object" and
        (.name | type == "string") and
        (.id | type == "number" and floor == . and . > 0) and
        (.size | type == "number" and floor == . and . > 0) and
        (.created_at | type == "string" and length > 0) and
        (.updated_at | type == "string" and length > 0) and
        (.url | type == "string" and length > 0) and
        .state == "uploaded"
      ) and
      ([.[].name] | sort) == [
        "SHA256SUMS",
        "image-index.json",
        "image-inspect.txt",
        "release-manifest.json"
      ] and
      ([.[].name] | unique | length) == 4 and
      ([.[].id] | unique | length) == 4
    ' >/dev/null <<<"$assets" ||
      fail "release asset metadata is partial, duplicate, foreign, or malformed"
    normalized=$(jq -c '[.[] | {
      name, id, size, state, created_at, updated_at, url
    }] | sort_by(.name)' <<<"$assets")
    kind=complete_unverified
  fi
  fingerprint=$(printf '%s' "$normalized" | sha256sum | awk '{print $1}')
  printf '%s\t%s\t%s\n' "$kind" "$fingerprint" "$normalized"
}

validate_release() {
  local release=$1 id tag target draft prerelease published source_pair tag_target asset_data
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
  printf '%s\t%s\t%s\t%s\n' "$id" "$tag" "$target" "$asset_data"
}

validate_completed_release() {
  local release=$1 id tag target draft prerelease published source_pair tag_target asset_data
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
  prerelease=$(jq -r 'if has("prerelease") then (.prerelease | tostring) else "missing" end' \
    <<<"$release")
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
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$tag" "$target" "$asset_data" "$OBSERVED_STATE"
}

emit_pre_action_action() {
  {
    echo "route=action"
    echo "active=false"
    echo "origin=pre_action"
    echo "observed_state=none"
    echo "authority_version=$AUTHORITY_VERSION"
    echo "authority_tag=$AUTHORITY_TAG"
    echo "authority_source_sha=$AUTHORITY_SOURCE"
  }
}

emit_pre_action_recovery() {
  local validated=$1 id observed_tag source kind fingerprint inventory state
  IFS=$'\t' read -r id observed_tag source kind fingerprint inventory state <<<"$validated"
  {
    echo "route=recovery"
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
    echo "published_at=null"
    echo "authority_version=$AUTHORITY_VERSION"
    echo "authority_tag=$AUTHORITY_TAG"
    echo "authority_source_sha=$AUTHORITY_SOURCE"
    echo "asset_inventory_kind=$kind"
    echo "asset_inventory_fingerprint=$fingerprint"
    echo "asset_inventory_json=$inventory"
  }
}

emit_active() {
  local origin=$1 validated=$2 id tag source kind fingerprint inventory
  IFS=$'\t' read -r id tag source kind fingerprint inventory <<<"$validated"
  {
    echo "active=true"
    echo "origin=$origin"
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
  }
}

require_expected_tuple() {
  [[ "$EXPECTED_ID" =~ ^[1-9][0-9]*$ ]] || usage
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
  recover)
    RELEASES=$(load_releases)
    ELIGIBLE=()
    COMPLETED=()
    while IFS= read -r release; do
      tag=$(jq -r '.tag_name // empty' <<<"$release")
      target=$(jq -r '.target_commitish // empty' <<<"$release")
      relevant=false
      if [ "$tag" = "$AUTHORITY_TAG" ] || [ "$target" = "$AUTHORITY_SOURCE" ]; then
        relevant=true
      elif [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] &&
           [ "$(semver_compare "${tag#v}" "$AUTHORITY_VERSION")" -gt 0 ]; then
        relevant=true
      fi
      [ "$relevant" = true ] || continue
      if jq -e '.draft == false and .published_at != null' \
          >/dev/null <<<"$release"; then
        completed=$(validate_completed_release "$release") ||
          fail "relevant published release conflicts with current authority"
        COMPLETED+=("$completed")
        continue
      fi
      validated=$(validate_release "$release") ||
        fail "relevant release failed descriptor validation"
      ELIGIBLE+=("$validated")
    done < <(jq -c '.[]' <<<"$RELEASES")

    if [ "$(( ${#ELIGIBLE[@]} + ${#COMPLETED[@]} ))" -eq 0 ]; then
      {
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
    RELEASES=$(load_releases)
    ELIGIBLE=()
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
      if jq -e '.draft == false and .published_at != null' >/dev/null <<<"$release"; then
        continue
      fi
      validated=$(validate_pre_action_candidate "$release") ||
        fail "current-authority pre-action candidate is invalid"
      ELIGIBLE+=("$validated")
    done < <(jq -c '.[]' <<<"$RELEASES")

    if [ "${#ELIGIBLE[@]}" -eq 0 ]; then
      emit_pre_action_action
    elif [ "${#ELIGIBLE[@]}" -eq 1 ]; then
      emit_pre_action_recovery "${ELIGIBLE[0]}"
    else
      fail "multiple current-authority pre-action candidates are ambiguous"
    fi
    ;;
  verify)
    require_expected_tuple
    [[ "$EXPECTED_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || usage
    RELEASE=$(load_release_by_id "$EXPECTED_ID")
    VALIDATED=$(validate_release "$RELEASE") ||
      fail "release failed descriptor revalidation"
    IFS=$'\t' read -r actual_id _ _ _ actual_fingerprint _ <<<"$VALIDATED"
    [ "$actual_id" = "$EXPECTED_ID" ] || fail "release ID drifted"
    [ "$actual_fingerprint" = "$EXPECTED_FINGERPRINT" ] ||
      fail "release asset descriptor drifted"
    emit_active verified "$VALIDATED"
    ;;
esac
