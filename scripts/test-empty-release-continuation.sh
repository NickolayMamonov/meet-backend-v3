#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ADMIT=$ROOT_DIR/scripts/admit-empty-release-continuation.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT
REPO=$ROOT_DIR
SOURCE=a7abfe04f6852f479291a4710ebdee23e9ae8a34

jq -n --arg source "$SOURCE" '[{
  id:377201468,name:"v1.3.0",tag_name:"v1.3.0",target_commitish:$source,immutable:false,draft:true,
  prerelease:false,published_at:null,assets:[]
}]' >"$TMP/releases.json"
jq -n '{refs:{},tags:{}}' >"$TMP/refs.json"
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
