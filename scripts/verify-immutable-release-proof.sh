#!/usr/bin/env bash
set -euo pipefail

WORK_DIR=

usage() {
  echo "usage: $0 --repository owner/repo --tag v1.2.0 --release-id ID --source-sha SHA --assets-dir PATH [--gh-command COMMAND]" >&2
  exit 2
}

fail() {
  echo "immutable release proof verification failed: $1" >&2
  exit 1
}

api_request() {
  local method=$1
  local endpoint=$2
  local output=$3

  case "$method" in
    GET) ;;
    PUT|PATCH|DELETE)
      fail "release mutation methods are forbidden"
      ;;
    *)
      fail "unsupported API method"
      ;;
  esac

  "$GH_COMMAND" api --method GET "$endpoint" >"$output" ||
    fail "GitHub release API read failed"
  jq -e . "$output" >/dev/null 2>&1 ||
    fail "GitHub release API returned malformed JSON"
}

sha256_file() {
  local file=$1
  local digest
  digest=$(sha256sum "$file" 2>/dev/null | awk '{print $1}') ||
    fail "asset SHA-256 calculation failed"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] ||
    fail "asset SHA-256 calculation failed"
  printf '%s' "$digest"
}

sha256_json() {
  local filter=$1
  local file=$2
  local digest
  digest=$(
    jq -cS -j "$filter" "$file" 2>/dev/null |
      sha256sum 2>/dev/null |
      awk '{print $1}'
  ) || fail "attestation proof digest calculation failed"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] ||
    fail "attestation proof digest calculation failed"
  printf '%s' "$digest"
}

main() {
  local repository=
  local tag=
  local release_id=
  local source_sha=
  local assets_dir=
  GH_COMMAND=gh
  local release tag_release attestation statement_file
  local bundle_sha claim_sha payload asset path api_digest download_sha
  local attestation_release_id
  local -a assets=(
    release-manifest.json
    image-index.json
    image-inspect.txt
    SHA256SUMS
  )

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repository)
        [ "$#" -ge 2 ] || usage
        [ -z "$repository" ] || usage
        repository=$2
        shift 2
        ;;
      --tag)
        [ "$#" -ge 2 ] || usage
        [ -z "$tag" ] || usage
        tag=$2
        shift 2
        ;;
      --release-id)
        [ "$#" -ge 2 ] || usage
        [ -z "$release_id" ] || usage
        release_id=$2
        shift 2
        ;;
      --source-sha)
        [ "$#" -ge 2 ] || usage
        [ -z "$source_sha" ] || usage
        source_sha=$2
        shift 2
        ;;
      --assets-dir)
        [ "$#" -ge 2 ] || usage
        [ -z "$assets_dir" ] || usage
        assets_dir=$2
        shift 2
        ;;
      --gh-command)
        [ "$#" -ge 2 ] || usage
        [ "$GH_COMMAND" = gh ] || usage
        GH_COMMAND=$2
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done

  command -v jq >/dev/null 2>&1 || fail "jq is required"
  command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
  command -v base64 >/dev/null 2>&1 || fail "base64 is required"
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
  [ "$tag" = v1.2.0 ] || usage
  [[ "$release_id" =~ ^[1-9][0-9]*$ ]] || usage
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || usage
  [ -d "$assets_dir" ] || fail "assets directory is unavailable"
  case "$GH_COMMAND" in
    ""|*[[:space:]]*) usage ;;
  esac
  command -v "$GH_COMMAND" >/dev/null 2>&1 ||
    fail "GitHub CLI command is unavailable"

  for asset in "${assets[@]}"; do
    path=$assets_dir/$asset
    [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] ||
      fail "an expected release asset is missing or unsafe"
  done

  WORK_DIR=$(mktemp -d 2>/dev/null) ||
    fail "temporary workspace is unavailable"
  trap 'rm -r -- "$WORK_DIR"' EXIT HUP INT TERM
  release=$WORK_DIR/release.json
  tag_release=$WORK_DIR/tag-release.json
  attestation=$WORK_DIR/attestation.json
  statement_file=$WORK_DIR/statement.json

  api_request GET "repos/$repository/releases/$release_id" "$release"
  api_request GET "repos/$repository/releases/tags/$tag" "$tag_release"

  jq -e \
    --argjson release_id "$release_id" \
    --arg tag "$tag" \
    --arg source_sha "$source_sha" '
      type == "object" and
      .id == $release_id and
      .immutable == true and
      .draft == false and
      .tag_name == $tag and
      .target_commitish == $source_sha and
      (.assets | type == "array" and length == 4) and
      ([.assets[].name] | sort) ==
        ["SHA256SUMS","image-index.json","image-inspect.txt","release-manifest.json"] and
      ([.assets[].name] | unique | length) == 4 and
      ([.assets[].id] | unique | length) == 4 and
      all(.assets[];
        type == "object" and
        (.id | type == "number" and floor == . and . > 0) and
        (.name | type == "string") and
        .state == "uploaded" and
        (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$"))
      )
    ' "$release" >/dev/null 2>&1 ||
    fail "numeric release is not the expected immutable published release"

  jq -e \
    --argjson release_id "$release_id" \
    --arg tag "$tag" \
    --arg source_sha "$source_sha" '
      type == "object" and
      .id == $release_id and
      .immutable == true and
      .draft == false and
      .tag_name == $tag and
      .target_commitish == $source_sha
    ' "$tag_release" >/dev/null 2>&1 ||
    fail "explicit tag does not resolve to the same immutable release"

  "$GH_COMMAND" release verify "$tag" --repo "$repository" --format json \
    >"$attestation" ||
    fail "release attestation verification failed"
  jq -e '
    type == "object" and
    (.attestation | type == "object") and
    (.attestation.bundle | type == "object") and
    (.attestation.bundle.dsseEnvelope.payload |
      type == "string" and length > 0) and
    (.verificationResult | type == "object" and .verified == true)
  ' "$attestation" >/dev/null 2>&1 ||
    fail "release attestation result is missing verified bundle data"

  payload=$(jq -r '.attestation.bundle.dsseEnvelope.payload' "$attestation")
  printf '%s' "$payload" | base64 --decode >"$statement_file" 2>/dev/null ||
    fail "release attestation claim is not valid base64"
  jq -e . "$statement_file" >/dev/null 2>&1 ||
    fail "release attestation claim is malformed"

  attestation_release_id=$(jq -r '.predicate.releaseId | tostring' "$statement_file")
  [ "$attestation_release_id" = "$release_id" ] ||
    fail "release attestation identifies another numeric release"
  jq -e \
    --arg repository "$repository" \
    --arg tag "$tag" \
    --arg source_sha "$source_sha" \
    --argjson release_id "$release_id" '
      type == "object" and
      .predicateType ==
        "https://in-toto.io/attestation/release/v0.1" and
      (.predicate | type == "object") and
      .predicate.repository == $repository and
      (.predicate.releaseId | tostring) == ($release_id | tostring) and
      .predicate.tag == $tag and
      (.subject | type == "array") and
      (
        [.subject[] |
          select(
            (.uri? == ("pkg:github/" + $repository + "@" + $tag)) and
            (.digest.sha1? == $source_sha)
          )
        ] | length
      ) == 1
    ' "$statement_file" >/dev/null 2>&1 ||
    fail "release attestation is not bound to the expected repository, tag, and source"

  for asset in "${assets[@]}"; do
    api_digest=$(
      jq -r --arg asset "$asset" '
        [.assets[] | select(.name == $asset)] |
        if length == 1 then .[0].digest else empty end
      ' "$release"
    )
    download_sha=$(sha256_file "$assets_dir/$asset")
    [ "$api_digest" = "sha256:$download_sha" ] ||
      fail "downloaded asset SHA-256 does not match the immutable release API"
    jq -e \
      --arg asset "$asset" \
      --arg download_sha "$download_sha" '
        [
          .subject[] |
          select(
            (.name? == $asset) and
            (.digest.sha256? == $download_sha)
          )
        ] | length == 1
      ' "$statement_file" >/dev/null 2>&1 ||
      fail "release attestation does not bind an expected asset digest"
  done

  bundle_sha=$(sha256_json '.attestation.bundle' "$attestation")
  claim_sha=$(sha256_json '.' "$statement_file")

  : >"$WORK_DIR/assets.jsonl"
  for asset in "${assets[@]}"; do
    path=$assets_dir/$asset
    "$GH_COMMAND" release verify-asset "$tag" "$path" \
      --repo "$repository" >/dev/null ||
      fail "immutable release asset verification failed"
    api_digest=$(
      jq -r --arg asset "$asset" \
        '.assets[] | select(.name == $asset) | .digest' "$release"
    )
    download_sha=$(sha256_file "$path")
    jq -cn \
      --arg repository "$repository" \
      --arg tag "$tag" \
      --argjson release_id "$release_id" \
      --arg bundle_sha "$bundle_sha" \
      --arg asset "$asset" \
      --arg api_digest "$api_digest" \
      --arg download_sha "$download_sha" '
        {
          repository:$repository,
          tag:$tag,
          releaseId:$release_id,
          attestationBundleSha256:$bundle_sha,
          name:$asset,
          apiDigest:$api_digest,
          downloadSha256:$download_sha,
          verified:true
        }
      ' >>"$WORK_DIR/assets.jsonl"
  done

  jq -cS -n \
    --arg repository "$repository" \
    --arg tag "$tag" \
    --argjson release_id "$release_id" \
    --arg source_sha "$source_sha" \
    --arg bundle_sha "$bundle_sha" \
    --arg claim_sha "$claim_sha" \
    --slurpfile assets "$WORK_DIR/assets.jsonl" '
      {
        repository:$repository,
        tag:$tag,
        releaseId:$release_id,
        sourceSha:$source_sha,
        immutable:true,
        draft:false,
        attestation:{
          verified:true,
          predicateType:"https://in-toto.io/attestation/release/v0.1",
          bundleSha256:$bundle_sha,
          claimSha256:$claim_sha
        },
        assets:$assets
      }
    '
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
