#!/usr/bin/env bash
set -euo pipefail

fail() { echo "release descriptor resolution failed: $*" >&2; exit 1; }
usage() {
  cat >&2 <<'EOF'
usage:
  resolve-release-descriptor.sh pre-action [options]
  resolve-release-descriptor.sh post-action --tag TAG --version VERSION --source-sha SHA [options]
  resolve-release-descriptor.sh verify --phase empty|complete --release-id ID
    --tag TAG --version VERSION --source-sha SHA [options]
EOF
  exit 2
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
path_arg() {
  case "$1" in
    [A-Za-z]:/*)
      command -v cygpath >/dev/null 2>&1 && cygpath -u "$1" || printf '%s' "$1"
      ;;
    *) printf '%s' "$1" ;;
  esac
}
mode=${1:-}
case "$mode" in pre-action|post-action|verify) ;; *) usage ;; esac
shift
repo_dir=.
dev_ref=origin/dev
repository=${GITHUB_REPOSITORY:-}
releases_file=
release_file=
refs_file=
expected_id=
expected_tag=
expected_version=
expected_source=
phase=
allow_completed=false
before_file=
after_file=
release_created=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir) repo_dir=$(path_arg "${2:?}"); shift 2 ;;
    --dev-ref) dev_ref=${2:?}; shift 2 ;;
    --repository) repository=${2:?}; shift 2 ;;
    --releases-file) releases_file=$(path_arg "${2:?}"); shift 2 ;;
    --release-file) release_file=$(path_arg "${2:?}"); shift 2 ;;
    --refs-file) refs_file=$(path_arg "${2:?}"); shift 2 ;;
    --release-id) expected_id=${2:?}; shift 2 ;;
    --tag) expected_tag=${2:?}; shift 2 ;;
    --version) expected_version=${2:?}; shift 2 ;;
    --source-sha) expected_source=${2:?}; shift 2 ;;
    --phase) phase=${2:?}; shift 2 ;;
    --allow-completed) allow_completed=true; shift ;;
    --before-releases-file) before_file=$(path_arg "${2:?}"); shift 2 ;;
    --after-releases-file) after_file=$(path_arg "${2:?}"); shift 2 ;;
    --release-created)
      release_created=${2:?}
      [ "$release_created" = true ] || [ "$release_created" = false ] || usage
      shift 2
      ;;
    *) usage ;;
  esac
done

canonical_version() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}
authority_version=
if git -C "$repo_dir" rev-parse --verify "${dev_ref}^{commit}" >/dev/null 2>&1; then
  authority_version=$(git -C "$repo_dir" show "$dev_ref:.release-please-manifest.json" |
    jq -r '."."' 2>/dev/null || true)
  version_file=$(git -C "$repo_dir" show "$dev_ref:version.json" |
    jq -r '.version' 2>/dev/null || true)
  [ "$authority_version" = "$version_file" ] || fail "manifest/version authority disagrees"
else
  authority_version=${expected_version:-}
fi
canonical_version "$authority_version" || fail "authority version is not canonical"
authority_tag="v$authority_version"
authority_source=
if git -C "$repo_dir" rev-parse --verify "${dev_ref}^{commit}" >/dev/null 2>&1; then
  authority_source=$(git -C "$repo_dir" rev-parse "${dev_ref}^{commit}")
else
  authority_source=${expected_source:-}
fi
[[ "$authority_source" =~ ^[0-9a-f]{40}$ ]] || fail "authority source is not a full SHA"

load_releases() {
  if [ -n "$after_file" ]; then
    jq -e 'type == "array" and all(.[]; type == "object")' "$after_file" >/dev/null ||
      fail "post-action release snapshot is malformed"
    jq -c . "$after_file"
    return
  fi
  if [ -n "$release_file" ]; then jq -c '[.]' "$release_file"; return; fi
  if [ -n "$releases_file" ]; then
    jq -e 'type == "array" and all(.[]; type == "object")' "$releases_file" >/dev/null ||
      fail "release fixture is malformed"
    jq -c . "$releases_file"
    return
  fi
  [ -n "$repository" ] || fail "repository is required for live reads"
  command -v gh >/dev/null 2>&1 || fail "gh is required for live reads"
  gh api --paginate --slurp "repos/$repository/releases?per_page=100" |
    jq -c 'add // []'
}

relevant_ids() {
  local file=$1
  jq -e 'type == "array" and all(.[]; type == "object")' "$file" >/dev/null ||
    fail "release-ID visibility snapshot is malformed"
  jq -r --arg tag "$authority_tag" --arg source "$authority_source" '
    .[] |
    select(
      (.tag_name == $tag or .target_commitish == $source) and
      (.id != 368531227) and
      ((.tag_name == "v1.1.0" and
        .target_commitish == "36ffd11ea4d35147f1df9c1cafa6a330300c1339") | not)
    ) |
    .id | select(type == "number" and floor == . and . > 0)
  ' "$file" | sort -n
}

resolve_ref() {
  local tag=$1 object type sha next
  if [ -n "$refs_file" ]; then
    object=$(jq -c --arg tag "$tag" '.refs[$tag] // null' "$refs_file")
    [ "$object" != null ] || { echo absent; return; }
    while :; do
      type=$(jq -r '.type // empty' <<<"$object")
      sha=$(jq -r '.sha // empty' <<<"$object")
      [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "ref SHA is malformed"
      case "$type" in
        commit) echo "$sha"; return ;;
        tag)
          next=$(jq -c --arg sha "$sha" '.tags[$sha] // null' "$refs_file")
          [ "$next" != null ] || fail "annotated tag object is missing"
          object=$next
          ;;
        *) fail "unsupported ref object type" ;;
      esac
    done
  fi
  [ -n "$repository" ] || { echo absent; return; }
  command -v gh >/dev/null 2>&1 || fail "gh is required for live ref reads"
  local error
  error=$(mktemp)
  if ! object=$(gh api "repos/$repository/git/ref/tags/$tag" 2>"$error"); then
    if grep -q 'HTTP 404' "$error"; then rm -f "$error"; echo absent; return; fi
    rm -f "$error"; fail "tag ref read failed"
  fi
  rm -f "$error"
  object=$(jq -c '.object' <<<"$object")
  type=$(jq -r '.type' <<<"$object")
  sha=$(jq -r '.sha' <<<"$object")
  if [ "$type" = tag ]; then
    object=$(gh api "repos/$repository/git/tags/$sha")
    type=$(jq -r '.object.type' <<<"$object")
    sha=$(jq -r '.object.sha' <<<"$object")
  fi
  [ "$type" = commit ] || fail "tag does not peel to commit"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "peeled ref SHA is malformed"
  echo "$sha"
}

validate_common() {
  local release=$1 id tag target draft prerelease published
  jq -e '
    type == "object" and
    (.id | type == "number" and floor == . and . > 0) and
    (.tag_name | type == "string") and (.target_commitish | type == "string") and
    (.draft | type == "boolean") and (.prerelease | type == "boolean") and
    (.assets | type == "array")
  ' <<<"$release" >/dev/null || fail "release object is malformed"
  id=$(jq -r '.id' <<<"$release")
  tag=$(jq -r '.tag_name' <<<"$release")
  target=$(jq -r '.target_commitish' <<<"$release")
  draft=$(jq -r '.draft' <<<"$release")
  prerelease=$(jq -r '.prerelease' <<<"$release")
  published=$(jq -r '.published_at // "null"' <<<"$release")
  [ "$id" != 368531227 ] || fail "permanently denied release ID"
  [ "$tag" != v1.1.0 ] || fail "permanently denied tag"
  [ "$target" != 36ffd11ea4d35147f1df9c1cafa6a330300c1339 ] ||
    fail "permanently denied source"
  [ "$tag" = "$authority_tag" ] || fail "release tag is not current authority"
  if [ "$published" = null ]; then
    [ "$draft" = true ] || fail "unpublished release has invalid publication state"
    [ "$target" = "$authority_source" ] ||
      fail "unpublished release source is not current authority"
  else
    [[ "$target" =~ ^[0-9a-f]{40}$ ]] ||
      fail "published release target is not a full SHA"
  fi
  [ "$prerelease" = false ] || fail "release is a prerelease"
}

emit() {
  local route=$1 release=$2 origin=$3 id tag target kind
  id=$(jq -r '.id' <<<"$release")
  tag=$(jq -r '.tag_name' <<<"$release")
  target=$(jq -r '.target_commitish' <<<"$release")
  if [ "$(jq '.assets | length' <<<"$release")" -eq 0 ]; then kind=empty; else kind=complete; fi
  printf 'route=%s\nactive=%s\norigin=%s\nrelease_id=%s\ntag=%s\nversion=%s\nsource_sha=%s\ntarget_commitish=%s\ndraft=%s\nprerelease=%s\npublished_at=%s\nasset_inventory_kind=%s\n' \
    "$route" "$([ "$route" = completed ] && echo false || echo true)" "$origin" \
    "$id" "$tag" "$authority_version" "$authority_source" "$target" \
    "$(jq -r '.draft' <<<"$release")" "$(jq -r '.prerelease' <<<"$release")" \
    "$(jq -c '.published_at // null' <<<"$release")" "$kind"
}

releases=$(load_releases)
if [ -n "$before_file" ] || [ -n "$after_file" ]; then
  [ -n "$before_file" ] && [ -n "$after_file" ] ||
    fail "current-action set difference requires both visibility snapshots"
  before_ids=$(relevant_ids "$before_file")
  after_ids=$(relevant_ids "$after_file")
  removed_ids=$(comm -23 \
    <(printf '%s\n' "$before_ids" | sed '/^$/d') \
    <(printf '%s\n' "$after_ids" | sed '/^$/d'))
  new_ids=$(comm -13 \
    <(printf '%s\n' "$before_ids" | sed '/^$/d') \
    <(printf '%s\n' "$after_ids" | sed '/^$/d'))
  [ -z "$removed_ids" ] || fail "current-action relevant release disappeared"
  new_count=$(sed '/^$/d' <<<"$new_ids" | wc -l | tr -d ' ')
  case "$release_created" in
    true) [ "$new_count" -eq 1 ] || fail "release_created=true requires exactly one new release ID" ;;
    false) [ "$new_count" -eq 0 ] || fail "release_created=false forbids a new release ID" ;;
    *) [ "$new_count" -eq 1 ] || fail "current-action set difference is not exactly one new release ID" ;;
  esac
fi
mapfile -t candidates < <(jq -c --arg tag "$authority_tag" --arg source "$authority_source" '
  .[] | select(
    (.tag_name == $tag or .target_commitish == $source) and
    (.id != 368531227) and
    ((.tag_name == "v1.1.0" and
      .target_commitish == "36ffd11ea4d35147f1df9c1cafa6a330300c1339") | not)
  )
' <<<"$releases")
for candidate in "${candidates[@]}"; do validate_common "$candidate"; done

before_has_published=false
if [ -n "$before_file" ]; then
  mapfile -t before_candidates < <(jq -c --arg tag "$authority_tag" --arg source "$authority_source" '
    .[] | select(
      (.tag_name == $tag or .target_commitish == $source) and
      (.id != 368531227) and
      ((.tag_name == "v1.1.0" and
        .target_commitish == "36ffd11ea4d35147f1df9c1cafa6a330300c1339") | not)
    )
  ' "$before_file")
  for candidate in "${before_candidates[@]}"; do
    validate_common "$candidate"
    if [ "$(jq -r '.published_at // "null"' <<<"$candidate")" != null ]; then
      before_has_published=true
    fi
  done
fi

case "$mode" in
  pre-action)
    if [ "${#candidates[@]}" -eq 0 ]; then
      printf 'route=action\nactive=false\norigin=pre_action\nrelease_id=\ntag=%s\nversion=%s\nsource_sha=%s\n' \
        "$authority_tag" "$authority_version" "$authority_source"
      exit 0
    fi
    [ "${#candidates[@]}" -eq 1 ] || fail "ambiguous current-action release set"
    candidate=${candidates[0]}
    if [ -n "${new_ids:-}" ]; then
      [ "$(jq -r '.id' <<<"$candidate")" = "$(sed '/^$/d' <<<"$new_ids")" ] ||
        fail "post-action release is not the one new current-action release ID"
    fi
    if [ "$(jq -r '.draft' <<<"$candidate")" = true ] &&
       [ "$(jq -r '.published_at // "null"' <<<"$candidate")" = null ]; then
      fail "pre-existing current draft is stale; only a current-action fresh draft may materialize"
    else
      printf 'route=action\nactive=false\norigin=pre_action_published\nrelease_id=\ntag=%s\nversion=%s\nsource_sha=%s\n' \
        "$authority_tag" "$authority_version" "$authority_source"
    fi
    ;;
  post-action)
    [ "$expected_tag" = "$authority_tag" ] || fail "action returned wrong tag"
    [ "$expected_version" = "$authority_version" ] || fail "action returned wrong version"
    [ "$expected_source" = "$authority_source" ] || fail "action returned wrong source"
    if [ "$release_created" = false ]; then
      [ "${#candidates[@]}" -eq 0 ] || [ "${#candidates[@]}" -eq 1 ] ||
        fail "release_created=false produced ambiguous current release set"
      if [ "${#candidates[@]}" -eq 1 ] &&
         [ "$(jq -r '.published_at // "null"' <<<"${candidates[0]}")" = null ]; then
        fail "release_created=false cannot adopt an unpublished current draft"
      fi
    fi
    [ "${#candidates[@]}" -eq 1 ] || {
      if [ "$allow_completed" = true ] &&
         { [ "$before_has_published" = true ] ||
           { [ -z "$before_file" ] && [ "${#candidates[@]}" -eq 0 ]; }; }; then
        printf 'route=completed\nactive=false\norigin=completed\nrelease_id=\ntag=%s\nversion=%s\nsource_sha=%s\n' \
          "$authority_tag" "$authority_version" "$authority_source"
        exit 0
      fi
      if [ "$release_created" = false ] && [ "${#candidates[@]}" -eq 0 ]; then
        printf 'route=action\nactive=false\norigin=post_action_noop\nrelease_id=\ntag=%s\nversion=%s\nsource_sha=%s\n' \
          "$authority_tag" "$authority_version" "$authority_source"
        exit 0
      fi
      fail "post-action did not produce exactly one current release"
    }
    candidate=${candidates[0]}
    if [ "$release_created" = false ]; then
      [ "$(jq -r '.published_at // "null"' <<<"$candidate")" != null ] ||
        fail "release_created=false left an unpublished current release"
      [ "$allow_completed" = true ] || fail "published result requires completed admission"
      emit completed "$candidate" post_action
    elif [ "$(jq -r '.published_at // "null"' <<<"$candidate")" != null ]; then
      [ "$allow_completed" = true ] || fail "published result requires completed admission"
      emit completed "$candidate" post_action
    else
      emit materialize "$candidate" post_action
    fi
    ;;
  verify)
    [ "$phase" = empty ] || [ "$phase" = complete ] || usage
    [[ "$expected_id" =~ ^[1-9][0-9]*$ ]] || fail "numeric release ID is required"
    [ "$expected_tag" = "$authority_tag" ] || fail "wrong explicit tag"
    [ "$expected_version" = "$authority_version" ] || fail "wrong version"
    [ "$expected_source" = "$authority_source" ] || fail "wrong source"
    candidate=$(jq -c --argjson id "$expected_id" '.[] | select(.id == $id)' <<<"$releases")
    [ -n "$candidate" ] || fail "numeric release was not found"
    validate_common "$candidate"
    asset_count=$(jq '.assets | length' <<<"$candidate")
    case "$phase" in
      empty) [ "$asset_count" -eq 0 ] || fail "asset phase does not match" ;;
      complete) [ "$asset_count" -eq 4 ] || fail "asset phase does not match" ;;
    esac
    emit materialize "$candidate" verified
    ;;
esac
