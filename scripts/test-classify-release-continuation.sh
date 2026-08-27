#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLASSIFIER=$ROOT_DIR/scripts/classify-release-continuation.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

RELEASE_ID=377201468
TAG=v1.3.0
SOURCE=a7abfe04f6852f479291a4710ebdee23e9ae8a34
DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

jq -n --arg tag "$TAG" --arg source "$SOURCE" '[{
  id:377201468,
  name:$tag,
  tag_name:$tag,
  target_commitish:$source,
  draft:true,
  immutable:false,
  prerelease:false,
  published_at:null,
  assets:[]
}]' >"$TMP/pending.json"

jq -n '[{
  id:377201469,
  name:"v1.2.9",
  tag_name:"v1.2.9",
  target_commitish:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  draft:true,
  immutable:false,
  prerelease:false,
  published_at:null,
  assets:[]
}]' >"$TMP/absent.json"

jq --arg digest "$DIGEST" '
  .[0] |= (
    .draft = false |
    .immutable = true |
    .published_at = "2026-08-26T12:00:00Z" |
    .assets = [
      {id:501,name:"release-manifest.json",state:"uploaded",size:101,digest:$digest},
      {id:502,name:"image-index.json",state:"uploaded",size:102,digest:$digest},
      {id:503,name:"image-inspect.txt",state:"uploaded",size:103,digest:$digest},
      {id:504,name:"SHA256SUMS",state:"uploaded",size:104,digest:$digest}
    ]
  )
' "$TMP/pending.json" >"$TMP/published.json"

run_classifier() {
  "$CLASSIFIER" \
    --release-id "$RELEASE_ID" \
    --tag "$TAG" \
    --source-sha "$SOURCE" \
    --releases-file "$1"
}

assert_exact_output() {
  local expected=$1 fixture=$2
  printf '%s\n' "$expected" >"$TMP/expected"
  run_classifier "$fixture" >"$TMP/stdout" 2>"$TMP/stderr"
  cmp -s "$TMP/expected" "$TMP/stdout" || {
    echo "$fixture did not emit exactly '$expected'" >&2
    exit 1
  }
  [ ! -s "$TMP/stderr" ] || {
    echo "$fixture emitted stderr on success" >&2
    exit 1
  }
}

assert_rejected() {
  set +e
  "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  local status=$?
  set -e
  [ "$status" -ne 0 ] || {
    echo "invalid continuation state was accepted: $*" >&2
    exit 1
  }
  [ ! -s "$TMP/stdout" ] || {
    echo "rejected continuation state emitted stdout: $*" >&2
    exit 1
  }
}

reject_mutation() {
  local label=$1 filter=$2
  jq "$filter" "$TMP/published.json" >"$TMP/$label.json"
  assert_rejected run_classifier "$TMP/$label.json"
}

assert_exact_output absent "$TMP/absent.json"
assert_exact_output pending "$TMP/pending.json"
assert_exact_output published "$TMP/published.json"

reject_mutation missing-published-at 'del(.[0].published_at)'
reject_mutation false-published-at '.[0].published_at = false'
reject_mutation wrong-name '.[0].name = "v1.3.0-wrong"'
reject_mutation string-release-id '.[0].id = "377201468"'
reject_mutation zero-asset-id '.[0].assets[0].id = 0'
reject_mutation string-asset-id '.[0].assets[0].id = "501"'
reject_mutation fractional-asset-id '.[0].assets[0].id = 501.5'
reject_mutation zero-asset-size '.[0].assets[0].size = 0'
reject_mutation string-asset-size '.[0].assets[0].size = "101"'
reject_mutation fractional-asset-size '.[0].assets[0].size = 101.5'
reject_mutation wrong-asset-state '.[0].assets[0].state = "new"'
reject_mutation missing-asset-state 'del(.[0].assets[0].state)'
reject_mutation malformed-asset-digest '.[0].assets[0].digest = "sha256:not-a-digest"'
reject_mutation uppercase-asset-digest '.[0].assets[0].digest = "sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"'
reject_mutation missing-asset-digest 'del(.[0].assets[0].digest)'
reject_mutation duplicate-asset-ids '.[0].assets[1].id = .[0].assets[0].id'
reject_mutation duplicate-asset-names '.[0].assets[1].name = .[0].assets[0].name'
reject_mutation wrong-asset-name '.[0].assets[0].name = "unexpected.txt"'
reject_mutation missing-asset '.[0].assets = .[0].assets[0:3]'

jq --arg tag "$TAG" '
  . + [{
    id:377201469,
    name:$tag,
    tag_name:$tag,
    target_commitish:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    draft:true,
    immutable:false,
    prerelease:false,
    published_at:null,
    assets:[]
  }]
' "$TMP/published.json" >"$TMP/second-tag.json"
assert_rejected run_classifier "$TMP/second-tag.json"

jq --arg source "$SOURCE" '
  . + [{
    id:377201469,
    name:"v9.9.9",
    tag_name:"v9.9.9",
    target_commitish:$source,
    draft:true,
    immutable:false,
    prerelease:false,
    published_at:null,
    assets:[]
  }]
' "$TMP/published.json" >"$TMP/second-source.json"
assert_rejected run_classifier "$TMP/second-source.json"

jq '. + [.[0]]' "$TMP/published.json" >"$TMP/duplicate-release-id.json"
assert_rejected run_classifier "$TMP/duplicate-release-id.json"

printf '%s\n' '{"not":"an array"}' >"$TMP/object.json"
printf '%s\n' '[null]' >"$TMP/non-object-entry.json"
printf '%s\n' '[{"unterminated":]' >"$TMP/malformed.json"
assert_rejected run_classifier "$TMP/object.json"
assert_rejected run_classifier "$TMP/non-object-entry.json"
assert_rejected run_classifier "$TMP/malformed.json"

for invalid_id in 0 01 +1 1.0; do
  assert_rejected "$CLASSIFIER" \
    --release-id "$invalid_id" --tag "$TAG" --source-sha "$SOURCE" \
    --releases-file "$TMP/pending.json"
done
for invalid_tag in 1.3.0 v01.3.0 v1.3; do
  assert_rejected "$CLASSIFIER" \
    --release-id "$RELEASE_ID" --tag "$invalid_tag" --source-sha "$SOURCE" \
    --releases-file "$TMP/pending.json"
done
for invalid_source in \
  A7ABFE04F6852F479291A4710EBDEE23E9AE8A34 \
  a7abfe04f6852f479291a4710ebdee23e9ae8a3; do
  assert_rejected "$CLASSIFIER" \
    --release-id "$RELEASE_ID" --tag "$TAG" --source-sha "$invalid_source" \
    --releases-file "$TMP/pending.json"
done

echo "release continuation classifier fixtures passed"
