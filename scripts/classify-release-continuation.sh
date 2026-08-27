#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: classify-release-continuation.sh
  --release-id ID --tag vX.Y.Z --source-sha SHA --releases-file PATH
EOF
  exit 2
}

fail() {
  echo "release continuation classification failed: $1" >&2
  exit 1
}

release_id=
tag=
source_sha=
releases_file=
release_id_seen=false
tag_seen=false
source_sha_seen=false
releases_file_seen=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-id)
      [ "$release_id_seen" = false ] && [ "$#" -ge 2 ] || usage
      release_id=$2
      release_id_seen=true
      shift 2
      ;;
    --tag)
      [ "$tag_seen" = false ] && [ "$#" -ge 2 ] || usage
      tag=$2
      tag_seen=true
      shift 2
      ;;
    --source-sha)
      [ "$source_sha_seen" = false ] && [ "$#" -ge 2 ] || usage
      source_sha=$2
      source_sha_seen=true
      shift 2
      ;;
    --releases-file)
      [ "$releases_file_seen" = false ] && [ "$#" -ge 2 ] || usage
      releases_file=$2
      releases_file_seen=true
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[ "$release_id_seen" = true ] &&
  [ "$tag_seen" = true ] &&
  [ "$source_sha_seen" = true ] &&
  [ "$releases_file_seen" = true ] ||
  usage

[[ "$release_id" =~ ^[1-9][0-9]*$ ]] ||
  fail "release ID must be a positive canonical integer"
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "tag must be a canonical vX.Y.Z tag"
[[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] ||
  fail "source SHA must contain exactly 40 lowercase hexadecimal characters"

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$releases_file" ] && [ -r "$releases_file" ] ||
  fail "releases file is missing, non-regular, or unreadable"

expected_assets='[
  "SHA256SUMS",
  "image-index.json",
  "image-inspect.txt",
  "release-manifest.json"
]'

state=$(
  jq -e -r \
    --arg id "$release_id" \
    --arg tag "$tag" \
    --arg source "$source_sha" \
    --argjson expected_assets "$expected_assets" '
      def positive_integer:
        type == "number" and . > 0 and floor == .;
      def claims_target_id($id):
        has("id") and (.id | tostring) == $id;
      def target_shape($tag; $source):
        has("id") and (.id | positive_integer) and
        has("name") and (.name | type == "string") and .name == $tag and
        has("tag_name") and (.tag_name | type == "string") and
          .tag_name == $tag and
        has("target_commitish") and
          (.target_commitish | type == "string") and
          .target_commitish == $source and
        has("draft") and (.draft | type == "boolean") and
        has("immutable") and (.immutable | type == "boolean") and
        has("prerelease") and (.prerelease | type == "boolean") and
        has("published_at") and
          ((.published_at == null) or
           (.published_at | type == "string" and length > 0)) and
        has("assets") and (.assets | type == "array");
      def valid_asset:
        type == "object" and
        has("id") and (.id | positive_integer) and
        has("name") and (.name | type == "string") and
        has("state") and .state == "uploaded" and
        has("size") and (.size | positive_integer) and
        has("digest") and
          (.digest |
            type == "string" and test("^sha256:[0-9a-f]{64}$"));
      def pending:
        .draft == true and
        .immutable == false and
        .prerelease == false and
        .published_at == null and
        (.assets | length) == 0;
      def published($expected_assets):
        .draft == false and
        .immutable == true and
        .prerelease == false and
        (.published_at | type == "string" and length > 0) and
        (.assets | length) == 4 and
        all(.assets[]; valid_asset) and
        ([.assets[].name] | sort) == $expected_assets and
        ([.assets[].name] | unique | length) == 4 and
        ([.assets[].id] | unique | length) == 4;

      if type != "array" then
        empty
      else
        . as $releases |
        if all($releases[]; type == "object") | not then
          empty
        else
          [$releases[] | select(claims_target_id($id))] as $matches |
          if ($matches | length) > 1 or
             ([$releases[] |
                select((.tag_name == $tag or .target_commitish == $source) and
                       (claims_target_id($id) | not))] | length) != 0
          then
            empty
          elif ($matches | length) == 0 then
            "absent"
          else
            $matches[0] |
            if target_shape($tag; $source) | not then
              empty
            elif pending then
              "pending"
            elif published($expected_assets) then
              "published"
            else
              empty
            end
          end
        end
      end
    ' "$releases_file" 2>/dev/null
) || fail "snapshot is malformed, ambiguous, or has an invalid release state"

case "$state" in
  absent|pending|published)
    printf '%s\n' "$state"
    ;;
  *)
    fail "snapshot is malformed, ambiguous, or has an invalid release state"
    ;;
esac
