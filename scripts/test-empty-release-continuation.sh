#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
ADMIT=$ROOT_DIR/scripts/admit-empty-release-continuation.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT
REPO=$ROOT_DIR
SOURCE=a7abfe04f6852f479291a4710ebdee23e9ae8a34
SOURCE_151=51bac7c8ab8284dfbef7d72d1e6d61e5d61539ce

jq -n --arg source "$SOURCE" '[{
  id:377201468,name:"v1.3.0",tag_name:"v1.3.0",target_commitish:$source,immutable:false,draft:true,
  prerelease:false,published_at:null,assets:[]
}]' >"$TMP/releases.json"
jq -n '{refs:{},tags:{}}' >"$TMP/refs.json"
COMMON_OBJECTS=$(git -C "$REPO" rev-parse --path-format=absolute --git-path objects)
AUTH_REPO=$TMP/authority-repo
AUTH_GIT=$AUTH_REPO/.git
env -u GIT_DIR -u GIT_WORK_TREE git init -q "$AUTH_REPO"
mkdir -p "$AUTH_GIT/objects/info"
printf '%s\n' "$COMMON_OBJECTS" >"$AUTH_GIT/objects/info/alternates"

authority_commit() {
  local git_dir=$1 version=$2 parent=${3-} manifest_blob version_blob tree
  jq -n --arg version "$version" '{".":$version}' >"$TMP/authority-manifest.json"
  jq -n --arg version "$version" '{version:$version}' >"$TMP/authority-version.json"
  manifest_blob=$(env -u GIT_DIR -u GIT_WORK_TREE git --git-dir="$git_dir" \
    hash-object -w "$TMP/authority-manifest.json")
  version_blob=$(env -u GIT_DIR -u GIT_WORK_TREE git --git-dir="$git_dir" \
    hash-object -w "$TMP/authority-version.json")
  tree=$(
    printf '100644 blob %s\t.release-please-manifest.json\n100644 blob %s\tversion.json\n' \
      "$manifest_blob" "$version_blob" |
      env -u GIT_DIR -u GIT_WORK_TREE git --git-dir="$git_dir" mktree
  )
  if [ -n "$parent" ]; then
    env -u GIT_DIR -u GIT_WORK_TREE \
      GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
      GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
      git --git-dir="$git_dir" \
      commit-tree "$tree" -p "$parent" -m "authority fixture $version"
  else
    env -u GIT_DIR -u GIT_WORK_TREE \
      GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
      GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
      git --git-dir="$git_dir" \
      commit-tree "$tree" -m "authority fixture $version"
  fi
}

DEV_151_DESCENDANT=$(authority_commit "$AUTH_GIT" 1.5.1 "$SOURCE_151")
SOURCE_151_PARENT=$(git -C "$REPO" rev-parse "${SOURCE_151}^")
DEV_151_NON_ANCESTOR=$(authority_commit "$AUTH_GIT" 1.5.1 "$SOURCE_151_PARENT")
DEV_151_VERSION_DRIFT=$(authority_commit "$AUTH_GIT" 1.5.2 "$SOURCE_151")
printf '%s\n' \
  'v1.3.0 absent' \
  '1.3.0 absent' \
  "sha-$SOURCE absent" \
  'latest=absent' \
  'state=empty' >"$TMP/registry.txt"

run_admission() {
  "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref "$SOURCE" \
    --release-id 377201468 --tag v1.3.0 --version 1.3.0 \
    --source-sha "$SOURCE" --releases-file "$TMP/releases.json" \
    --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs.json"
}

run_admission | grep -Fx 'route=materialize'

cp "$TMP/registry.txt" "$TMP/registry-ok.txt"
awk '$0 == "v1.3.0 absent" { print "v1.3.0 sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; next } { print }' "$TMP/registry-ok.txt" >"$TMP/registry.txt"
if run_admission >/dev/null 2>&1; then
  echo "non-empty candidate registry was admitted" >&2
  exit 1
fi
mv "$TMP/registry-ok.txt" "$TMP/registry.txt"

jq '.refs["v1.3.0"]={type:"commit",sha:"'"$SOURCE"'"}' \
  "$TMP/refs.json" >"$TMP/refs-present.json"
if "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref "$SOURCE" \
  --release-id 377201468 --tag v1.3.0 --version 1.3.0 \
  --source-sha "$SOURCE" --releases-file "$TMP/releases.json" \
  --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs-present.json" \
  >/dev/null 2>&1; then
  echo "existing release tag was admitted" >&2
  exit 1
fi

jq '.[0].assets=[{name:"partial"}]' "$TMP/releases.json" >"$TMP/partial.json"
if "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref "$SOURCE" \
  --release-id 377201468 --tag v1.3.0 --version 1.3.0 \
  --source-sha "$SOURCE" --releases-file "$TMP/partial.json" \
  --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs.json" \
  >/dev/null 2>&1; then
  echo "partial release assets were admitted" >&2
  exit 1
fi

expect_rejection() {
  if "$@" >/dev/null 2>&1; then
    echo "invalid continuation state was admitted" >&2
    exit 1
  fi
}
expect_rejection_message() {
  local expected=$1
  shift
  if "$@" >"$TMP/rejection.stdout" 2>"$TMP/rejection.stderr"; then
    echo "invalid continuation state was admitted; expected rejection: $expected" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" "$TMP/rejection.stderr"; then
    echo "rejection did not identify '$expected':" >&2
    sed -n '1,12p' "$TMP/rejection.stderr" >&2
    exit 1
  fi
}

# Fixture refs must not widen the one-time continuation allowlist.
expect_rejection "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref "$SOURCE" \
  --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
  --source-sha 9b6d2b06c0336ab8d153564dcf6328e81c4d7b36 \
  --releases-file "$TMP/releases.json" --registry-state-file "$TMP/registry.txt" \
  --refs-file "$TMP/refs.json"

reject_mutation() {
  local label=$1 filter=$2
  jq "$filter" "$TMP/releases.json" >"$TMP/$label.json"
  local -a args=(
    --repository owner/repo
    --repo-dir "$REPO"
    --dev-ref "$SOURCE"
    --release-id 377201468
    --tag v1.3.0
    --version 1.3.0
    --source-sha "$SOURCE"
    --releases-file "$TMP/$label.json"
    --registry-state-file "$TMP/registry.txt"
    --refs-file "$TMP/refs.json"
  )
  if "$ADMIT" "${args[@]}" >/dev/null 2>&1; then
    echo "$label mutation was admitted" >&2
    exit 1
  fi
}
reject_mutation wrong-id ".[0].id=1"
reject_mutation wrong-tag ".[0].tag_name |= ascii_upcase"
reject_mutation wrong-source ".[0].target_commitish |= ascii_upcase"
reject_mutation wrong-name ".[0].name |= ascii_upcase"
reject_mutation draft-false ".[0].draft=false"
reject_mutation immutable-true ".[0].immutable=true"
reject_mutation prerelease-true ".[0].prerelease=true"
reject_mutation published ".[0].published_at |= tostring"
reject_mutation partial-assets ".[0].assets = .[0].assets + [{}]"
reject_mutation duplicate-release ". + [.[0]]"
reject_mutation missing-release ". = []"

printf '%s\n' '{not-json' >"$TMP/malformed.json"
expect_rejection "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE" --release-id 377201468 --tag v1.3.0 \
  --version 1.3.0 --source-sha "$SOURCE" \
  --releases-file "$TMP/malformed.json" \
  --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs.json"

jq '. + [{
  id:377201469,
  name:"other",
  tag_name:"v1.3.0",
  target_commitish:"0123456789abcdef0123456789abcdef01234567",
  immutable:false,
  draft:true,
  prerelease:false,
  published_at:null,
  assets:[]
}]' "$TMP/releases.json" >"$TMP/ambiguous-tag.json"
expect_rejection "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE" --release-id 377201468 --tag v1.3.0 \
  --version 1.3.0 --source-sha "$SOURCE" \
  --releases-file "$TMP/ambiguous-tag.json" \
  --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs.json"

jq '. + [{
  id:377201469,
  name:"other",
  tag_name:"v9.9.9",
  target_commitish:"'"$SOURCE"'",
  immutable:false,
  draft:true,
  prerelease:false,
  published_at:null,
  assets:[]
}]' "$TMP/releases.json" >"$TMP/ambiguous-source.json"
expect_rejection "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE" --release-id 377201468 --tag v1.3.0 \
  --version 1.3.0 --source-sha "$SOURCE" \
  --releases-file "$TMP/ambiguous-source.json" \
  --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs.json"

# The second explicitly authorized tuple admits only its exact empty draft.
jq -n --arg source "$SOURCE_151" '[{
  id:421705542,name:"v1.5.1",tag_name:"v1.5.1",target_commitish:$source,immutable:false,draft:true,
  prerelease:false,published_at:null,assets:[]
}]' >"$TMP/releases-151.json"
printf '%s\n' \
  'v1.5.1 absent' \
  '1.5.1 absent' \
  "sha-$SOURCE_151 absent" \
  'latest=absent' \
  'state=empty' >"$TMP/registry-151.txt"
run_admission_151() {
  env -u GIT_DIR -u GIT_WORK_TREE "$ADMIT" --repository owner/repo \
    --repo-dir "$AUTH_REPO" --dev-ref "$DEV_151_DESCENDANT" \
    --release-id 421705542 --tag v1.5.1 --version 1.5.1 \
    --source-sha "$SOURCE_151" --releases-file "$TMP/releases-151.json" \
    --registry-state-file "$TMP/registry-151.txt" --refs-file "$TMP/refs.json"
}
run_admission_151 | grep -Fx 'route=materialize'

run_authority_admission() {
  local dev_ref=$1 registry_file=$2 refs_file=$3 id=${4:-421705542}
  local tag=${5:-v1.5.1} version=${6:-1.5.1} source=${7:-$SOURCE_151}
  env -u GIT_DIR -u GIT_WORK_TREE "$ADMIT" --repository owner/repo \
    --repo-dir "$AUTH_REPO" --dev-ref "$dev_ref" \
    --release-id "$id" --tag "$tag" --version "$version" \
    --source-sha "$source" --releases-file "$TMP/releases-151.json" \
    --registry-state-file "$registry_file" --refs-file "$refs_file"
}

expect_rejection_message 'release source is not an ancestor of current dev' \
  run_authority_admission "$DEV_151_NON_ANCESTOR" \
  "$TMP/registry-151.txt" "$TMP/refs.json"
expect_rejection_message 'release and current dev version authority must both remain exact' \
  run_authority_admission "$DEV_151_VERSION_DRIFT" \
  "$TMP/registry-151.txt" "$TMP/refs.json"

latest_present_registry="$TMP/registry-151-latest-present.txt"
sed 's/^latest=absent$/latest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$TMP/registry-151.txt" >"$latest_present_registry"
expect_rejection_message 'candidate registry is not exactly empty' \
  run_authority_admission "$DEV_151_DESCENDANT" \
  "$latest_present_registry" "$TMP/refs.json"

UNAVAILABLE_REPO=$TMP/source-unavailable-repo
env -u GIT_DIR -u GIT_WORK_TREE git init -q "$UNAVAILABLE_REPO"
DEV_WITHOUT_SOURCE=$(authority_commit "$UNAVAILABLE_REPO/.git" 1.5.1)
expect_rejection_message 'release source commit is unavailable' \
  env -u GIT_DIR -u GIT_WORK_TREE "$ADMIT" \
  --repository owner/repo --repo-dir "$UNAVAILABLE_REPO" \
  --dev-ref "$DEV_WITHOUT_SOURCE" --release-id 421705542 \
  --tag v1.5.1 --version 1.5.1 --source-sha "$SOURCE_151" \
  --releases-file "$TMP/releases-151.json" \
  --registry-state-file "$TMP/registry-151.txt" --refs-file "$TMP/refs.json"

awk '$0 == "v1.5.1 absent" { print "v1.5.1 sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; next } { print }' \
  "$TMP/registry-151.txt" >"$TMP/registry-151-present.txt"
expect_rejection_message 'candidate registry is not exactly empty' \
  "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE_151" --release-id 421705542 --tag v1.5.1 \
  --version 1.5.1 --source-sha "$SOURCE_151" \
  --releases-file "$TMP/releases-151.json" \
  --registry-state-file "$TMP/registry-151-present.txt" --refs-file "$TMP/refs.json"
jq '.refs["v1.5.1"]={type:"commit",sha:"'"$SOURCE_151"'"}' \
  "$TMP/refs.json" >"$TMP/refs-151-present.json"
expect_rejection_message 'release tag ref unexpectedly exists' \
  "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE_151" --release-id 421705542 --tag v1.5.1 \
  --version 1.5.1 --source-sha "$SOURCE_151" \
  --releases-file "$TMP/releases-151.json" \
  --registry-state-file "$TMP/registry-151.txt" --refs-file "$TMP/refs-151-present.json"

reject_151_tuple() {
  local label=$1 id=$2 tag=$3 version=$4 source=$5
  if "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref "$SOURCE_151" \
    --release-id "$id" --tag "$tag" --version "$version" \
    --source-sha "$source" --releases-file "$TMP/releases-151.json" \
    --registry-state-file "$TMP/registry-151.txt" --refs-file "$TMP/refs.json" \
    >/dev/null 2>&1; then
    echo "v1.5.1 $label tuple mutation was admitted" >&2
    exit 1
  fi
}
reject_151_tuple wrong-id 421705543 v1.5.1 1.5.1 "$SOURCE_151"
reject_151_tuple wrong-tag 421705542 v1.5.2 1.5.2 "$SOURCE_151"
reject_151_tuple wrong-version 421705542 v1.5.1 1.5.2 "$SOURCE_151"
reject_151_tuple wrong-source 421705542 v1.5.1 1.5.1 "$SOURCE"

# Permanent v1.1.0 protections remain independent of the continuation list.
expect_rejection "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE_151" --release-id 368531227 --tag v1.3.0 \
  --version 1.3.0 --source-sha "$SOURCE_151" \
  --releases-file "$TMP/releases-151.json" \
  --registry-state-file "$TMP/registry-151.txt" --refs-file "$TMP/refs.json"
expect_rejection "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE_151" --release-id 421705542 --tag v1.1.0 \
  --version 1.1.0 --source-sha "$SOURCE_151" \
  --releases-file "$TMP/releases-151.json" \
  --registry-state-file "$TMP/registry-151.txt" --refs-file "$TMP/refs.json"
expect_rejection "$ADMIT" --repository owner/repo --repo-dir "$REPO" \
  --dev-ref "$SOURCE_151" --release-id 421705542 --tag v1.3.0 \
  --version 1.3.0 --source-sha 36ffd11ea4d35147f1df9c1cafa6a330300c1339 \
  --releases-file "$TMP/releases-151.json" \
  --registry-state-file "$TMP/registry-151.txt" --refs-file "$TMP/refs.json"

# Execute the selector loop extracted from the workflow against local snapshots.
workflow=$ROOT_DIR/.github/workflows/release-please.yml
selector_script="$TMP/workflow-selector.sh"
{
  printf '%s\n' 'set -euo pipefail' 'releases_before=$1'
  sed -n '/^          continuation_state=absent$/,/^          CONTINUATIONS$/p' \
    "$workflow" | sed 's/^          //'
  printf '%s\n' \
    'printf "%s/%s/%s/%s\n" "$continuation_state" "${continuation_id-}" "${continuation_tag-}" "${continuation_source-}"'
} >"$selector_script"
expect_selector() {
  local expected=$1 snapshot=$2 actual
  actual=$(bash "$selector_script" "$snapshot")
  [ "$actual" = "$expected" ] || {
    echo "workflow selector expected '$expected', got '$actual'" >&2
    exit 1
  }
}
printf '%s\n' '[]' >"$TMP/absent.json"
expect_selector absent/// "$TMP/absent.json"
expect_selector "pending/377201468/v1.3.0/$SOURCE" "$TMP/releases.json"
expect_selector "pending/421705542/v1.5.1/$SOURCE_151" "$TMP/releases-151.json"

jq -n --arg source "$SOURCE_151" '[
  {
    id:421705542,name:"v1.5.1",tag_name:"v1.5.1",target_commitish:$source,
    immutable:true,draft:false,prerelease:false,published_at:"2026-10-23T00:00:00Z",
    assets:[
      {id:1,name:"SHA256SUMS",state:"uploaded",size:1,digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      {id:2,name:"image-index.json",state:"uploaded",size:1,digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      {id:3,name:"image-inspect.txt",state:"uploaded",size:1,digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      {id:4,name:"release-manifest.json",state:"uploaded",size:1,digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    ]
  }
]' >"$TMP/published-151.json"
expect_selector absent/// "$TMP/published-151.json"
jq -n --arg source "$SOURCE_151" '[{
  id:421705542,name:"v1.5.1",tag_name:"v1.5.1",target_commitish:$source,
  immutable:false,draft:"yes",prerelease:false,published_at:null,assets:[]
}]' >"$TMP/invalid-state.json"
if bash "$selector_script" "$TMP/invalid-state.json" >/dev/null 2>&1; then
  echo "workflow selector accepted an invalid authorized continuation state" >&2
  exit 1
fi
jq -n --arg source13 "$SOURCE" --arg source151 "$SOURCE_151" '[
  {id:377201468,name:"v1.3.0",tag_name:"v1.3.0",target_commitish:$source13,
   immutable:false,draft:true,prerelease:false,published_at:null,assets:[]},
  {id:421705542,name:"v1.5.1",tag_name:"v1.5.1",target_commitish:$source151,
   immutable:false,draft:true,prerelease:false,published_at:null,assets:[]}
]' >"$TMP/multiple-pending.json"
if bash "$selector_script" "$TMP/multiple-pending.json" >/dev/null 2>&1; then
  echo "workflow selector accepted multiple pending authorized continuations" >&2
  exit 1
fi

admission_source=$(sed -n '1,$p' "$ADMIT")
line_of() {
  local pattern=$1
  grep -n -m1 -F -- "$pattern" <<<"$admission_source" | cut -d: -f1
}
classifier_line=$(line_of 'classify-release-continuation.sh')
for later_check in \
  'git -C "$repo_dir" rev-parse' \
  'verify-release-tag-ref.sh' \
  'cmp --silent "$expected_registry"'; do
  later_line=$(line_of "$later_check")
  [ -n "$classifier_line" ] && [ -n "$later_line" ] &&
    [ "$classifier_line" -lt "$later_line" ] || {
      echo "continuation classifier does not precede $later_check" >&2
      exit 1
    }
done

echo "empty release continuation fixtures passed"
