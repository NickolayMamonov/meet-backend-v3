#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --image IMAGE --alias ALIAS --subject-digest sha256:... --platform-subject sha256:... --index-file PATH --before-inventory PATH --protected-state PATH --require-signature true|false --output-dir PATH" >&2
  exit 2
}

fail() {
  echo "test-promotion inventory read failed: $*" >&2
  exit 1
}

is_digest() {
  [[ ${1:-} =~ ^sha256:[0-9a-f]{64}$ ]]
}

safe_regular_file() {
  local path=$1
  [ -n "$path" ] && [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ]
}

safe_directory() {
  local path=$1
  [ -n "$path" ] && [ -d "$path" ] && [ ! -L "$path" ]
}

IMAGE=
ALIAS=
SUBJECT_DIGEST=
PLATFORM_SUBJECT=
INDEX_FILE=
BEFORE_INVENTORY=
PROTECTED_STATE=
REQUIRE_SIGNATURE=
OUTPUT_DIR=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      [ "$#" -ge 2 ] && [ -z "$IMAGE" ] || usage
      IMAGE=$2
      shift 2
      ;;
    --alias)
      [ "$#" -ge 2 ] && [ -z "$ALIAS" ] || usage
      ALIAS=$2
      shift 2
      ;;
    --subject-digest)
      [ "$#" -ge 2 ] && [ -z "$SUBJECT_DIGEST" ] || usage
      SUBJECT_DIGEST=$2
      shift 2
      ;;
    --platform-subject)
      [ "$#" -ge 2 ] && [ -z "$PLATFORM_SUBJECT" ] || usage
      PLATFORM_SUBJECT=$2
      shift 2
      ;;
    --index-file)
      [ "$#" -ge 2 ] && [ -z "$INDEX_FILE" ] || usage
      INDEX_FILE=$2
      shift 2
      ;;
    --before-inventory)
      [ "$#" -ge 2 ] && [ -z "$BEFORE_INVENTORY" ] || usage
      BEFORE_INVENTORY=$2
      shift 2
      ;;
    --protected-state)
      [ "$#" -ge 2 ] && [ -z "$PROTECTED_STATE" ] || usage
      PROTECTED_STATE=$2
      shift 2
      ;;
    --require-signature)
      [ "$#" -ge 2 ] && [ -z "$REQUIRE_SIGNATURE" ] || usage
      REQUIRE_SIGNATURE=$2
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] && [ -z "$OUTPUT_DIR" ] || usage
      OUTPUT_DIR=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v gh >/dev/null 2>&1 || fail "gh is required"
command -v timeout >/dev/null 2>&1 || fail "GNU timeout is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

[[ "$IMAGE" =~ ^ghcr\.io/[a-z0-9][a-z0-9.-]*/[a-z0-9][a-z0-9._-]*$ ]] || usage
[[ "$ALIAS" =~ ^test-sha-[0-9a-f]{40}$ ]] || usage
is_digest "$SUBJECT_DIGEST" || usage
is_digest "$PLATFORM_SUBJECT" || usage
[ "$REQUIRE_SIGNATURE" = true ] || [ "$REQUIRE_SIGNATURE" = false ] || usage
safe_regular_file "$INDEX_FILE" || usage
safe_regular_file "$BEFORE_INVENTORY" || usage
safe_regular_file "$PROTECTED_STATE" || usage
safe_directory "$OUTPUT_DIR" || usage
[ "$SUBJECT_DIGEST" != "$PLATFORM_SUBJECT" ] || usage

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NORMALIZE="$SCRIPT_DIR/normalize-ghcr-package-inventory.sh"
[ -x "$NORMALIZE" ] || fail "package inventory normalizer is unavailable"

INDEX_SIZE=$(wc -c <"$INDEX_FILE" | tr -d '[:space:]')
[[ "$INDEX_SIZE" =~ ^[1-9][0-9]*$ ]] || fail "OCI index is empty"
[ "$INDEX_SIZE" -le 8388608 ] || fail "OCI index exceeds the bounded input size"
INDEX_HASH="sha256:$(sha256sum -- "$INDEX_FILE" | awk '{print $1}')"
[ "$INDEX_HASH" = "$SUBJECT_DIGEST" ] ||
  fail "OCI index bytes do not match the subject digest"

validate_index() {
  jq -e \
    --arg subject "$SUBJECT_DIGEST" \
    --arg platform "$PLATFORM_SUBJECT" '
    def digest:
      type == "string" and test("^sha256:[0-9a-f]{64}$");
    def descriptor:
      type == "object" and
      (.digest | digest) and
      (.mediaType | type == "string" and length > 0) and
      (.size | type == "number" and floor == . and . > 0);
    type == "object" and
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.index.v1+json" and
    (.manifests | type == "array" and length > 0 and all(.[]; descriptor)) and
    ([.manifests[] | .digest] | unique | length) == (.manifests | length) and
    ([.manifests[] |
      select(.mediaType == "application/vnd.oci.image.manifest.v1+json" and
        (.platform.os? // "") == "linux" and
        (.platform.architecture? // "") == "amd64" and
        (.platform.variant? // "") == "")] | length) == 1 and
    (any(.manifests[];
      .digest == $platform and
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      (.platform.os? // "") == "linux" and
      (.platform.architecture? // "") == "amd64" and
      (.platform.variant? // "") == "")) and
    all(.manifests[];
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      (
        .digest == $platform or
        (
          .annotations["vnd.docker.reference.type"]? == "attestation-manifest" and
          (.annotations["vnd.docker.reference.digest"]? == $subject or
           .annotations["vnd.docker.reference.digest"]? == $platform)
        )
      ))
  ' "$INDEX_FILE" >/dev/null ||
    fail "OCI index is not a byte-verified candidate index"
}

validate_index

INDEX_DIGESTS=$(jq -c \
  --arg subject "$SUBJECT_DIGEST" \
  --arg platform "$PLATFORM_SUBJECT" '
  ([$subject, $platform] +
   [.manifests[] |
    select(.digest != $platform and
      .annotations["vnd.docker.reference.type"]? == "attestation-manifest") |
    .digest]) | unique
' "$INDEX_FILE" | tr -d '\r') || fail "candidate descriptor extraction failed"

WRAPPER_COUNT=$(jq -r \
  --arg platform "$PLATFORM_SUBJECT" '
  [.manifests[] |
    select(.digest != $platform and
      .annotations["vnd.docker.reference.type"]? == "attestation-manifest")] | length
' "$INDEX_FILE" | tr -d '\r') || fail "candidate wrapper extraction failed"

# The raw before snapshot is deliberately validated independently.  It is
# never assembled with pages from a fresh attempt.
validate_snapshot() {
  local file=$1 label=$2
  jq -e '
    type == "array" and
    length > 0 and
    all(.[]; type == "array") and
    all(.[][];
      type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.name | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.metadata | type == "object") and
      (.metadata.container | type == "object") and
      (.metadata.container.tags | type == "array") and
      all(.metadata.container.tags[]; type == "string" and length > 0)
    ) and
    ([.[][] | .id] | unique | length) == ([.[][]] | length) and
    ([.[][] | .name] | unique | length) == ([.[][]] | length) and
    ([
      .[][] | .metadata.container.tags[]
    ] | unique | length) == ([
      .[][] | .metadata.container.tags[]
    ] | length)
  ' "$file" >/dev/null ||
    fail "$label package response is malformed, duplicated, or incomplete"
}

validate_snapshot "$BEFORE_INVENTORY" "before-inventory"

PROTECTED_DIGESTS=$(jq -c '
  if type != "object" or
     (.schema != "meet-backend/test-promotion-protected-state/v1") or
     (.protected | type != "object")
  then error("protected state schema")
  else
    [
      (.protected.rootDigests[]?),
      (.protected.platformDigests[]?),
      (.protected.subjectDigests[]?),
      (.protected.versions[]?.digest?),
      (.protected.subjects[]?.digest?),
      (.protected.manifests[]?.digest?),
      (.registry.versions[]?.digest?),
      (.registry.subjects[]?.digest?),
      (.registry.manifests[]?.digest?)
    ] |
    map(select(. != null)) |
    if all(.[]; type == "string" and test("^sha256:[0-9a-f]{64}$")) then unique
    else error("protected digest") end
  end
' "$PROTECTED_STATE") || fail "protected state is malformed"

if jq -e --argjson candidate "$INDEX_DIGESTS" \
    --argjson protected "$PROTECTED_DIGESTS" '
    any($candidate[];
      . as $candidate_digest |
      any($protected[]; . == $candidate_digest))
  ' <<<"null" >/dev/null; then
  fail "candidate digest intersects protected state"
fi

PACKAGE=
OWNER=
NAME=
PACKAGE=${IMAGE#ghcr.io/}
OWNER=${PACKAGE%%/*}
NAME=${PACKAGE#*/}
ENDPOINT="users/$OWNER/packages/container/$NAME/versions?per_page=100"

PHASE_DIR=
GH_PID=
KEEP_PHASE=false
# shellcheck disable=SC2329
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ -n "$GH_PID" ] && kill -0 "$GH_PID" 2>/dev/null; then
    kill -TERM "$GH_PID" 2>/dev/null || true
    wait "$GH_PID" 2>/dev/null || true
  fi
  GH_PID=
  if [ "$KEEP_PHASE" != true ] && [ -n "$PHASE_DIR" ] &&
     [ -d "$PHASE_DIR" ] && [ ! -L "$PHASE_DIR" ]; then
    rm -r -- "$PHASE_DIR" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

PHASE_DIR=$(mktemp -d -- "$OUTPUT_DIR/test-promotion-inventory.XXXXXX") ||
  fail "could not create a unique output phase directory"
PACKAGE_OUTPUT="$PHASE_DIR/package-versions.json"
REGISTRY_OUTPUT="$PHASE_DIR/registry-inventory.json"
[ ! -e "$PACKAGE_OUTPUT" ] && [ ! -e "$REGISTRY_OUTPUT" ] ||
  fail "final inventory output already exists"

baseline_rows=$(jq -c '
  [.[][] | {id, digest:.name, tags:.metadata.container.tags} as $row |
    select(($candidate | index($row.digest)) == null and
      (any($row.tags[]; . == $marker) | not)) | $row] |
  sort_by(.id,.digest)
' --arg marker "sha256-${SUBJECT_DIGEST#sha256:}" \
  --argjson candidate "$INDEX_DIGESTS" "$BEFORE_INVENTORY" | tr -d '\r') ||
  fail "before-inventory projection failed"

read_attempt() {
  local destination=$1 budget=$2 status
  local stderr_file=$destination.stderr
  : >"$stderr_file"
  timeout --signal=TERM --kill-after=2s "${budget}s" \
    gh api --paginate --slurp "$ENDPOINT" >"$destination" 2>"$stderr_file" &
  GH_PID=$!
  set +e
  wait "$GH_PID"
  status=$?
  set -e
  GH_PID=
  rm -f -- "$stderr_file"
  [ "$status" -eq 0 ] ||
    fail "GitHub package inventory request failed"
  [ -s "$destination" ] ||
    fail "GitHub package inventory response is empty"
}

evaluate_snapshot() {
  local current=$1 candidate_rows candidate_with_marker current_non_candidate
  local root_count root_tags alias_count alias_digest marker_count digest count
  local current_count

  validate_snapshot "$current" "fresh"

  # A package version outside the candidate is immutable for this phase.  The
  # full before snapshot is compared, so a writer or page-mixing mutation is
  # terminal rather than a reason to retry.
  current_non_candidate=$(jq -c --argjson candidate "$INDEX_DIGESTS" '
    [.[][] | {id, digest:.name, tags:.metadata.container.tags} as $row |
      select(($candidate | index($row.digest)) == null and
        (any($row.tags[]; . == $marker) | not)) | $row] |
      sort_by(.id,.digest)
  ' --arg marker "sha256-${SUBJECT_DIGEST#sha256:}" "$current" | tr -d '\r') ||
    fail "fresh inventory projection failed"
  current_count=$(jq -r '[.[][]] | length' "$current" | tr -d '\r') ||
    fail "fresh inventory cardinality failed"
  if [ "$current_count" -gt 0 ] && [ "$current_non_candidate" != "$baseline_rows" ]; then
    fail "protected or historical package inventory changed during observation"
  fi

  alias_count=$(jq -r --arg alias "$ALIAS" '
    [.[][] | select(any(.metadata.container.tags[]; . == $alias))] | length
  ' "$current" | tr -d '\r') || fail "candidate alias lookup failed"
  if [ "$alias_count" -gt 1 ]; then
    fail "candidate alias is bound to multiple package versions"
  fi
  if [ "$alias_count" -eq 1 ]; then
    alias_digest=$(jq -r --arg alias "$ALIAS" '
      [.[][] | select(any(.metadata.container.tags[]; . == $alias)) | .name] | unique[0]
    ' "$current" | tr -d '\r')
    [ "$alias_digest" = "$SUBJECT_DIGEST" ] ||
      fail "candidate alias is bound to a foreign digest"
  fi

  candidate_rows=$(jq -c --argjson candidate "$INDEX_DIGESTS" '
    [.[][] | {id, digest:.name, tags:.metadata.container.tags} as $row |
      select(($candidate | index($row.digest)) != null) | $row]
  ' "$current") || fail "candidate package projection failed"
  while IFS= read -r digest; do
    digest=${digest%$'\r'}
    count=$(jq -r --arg digest "$digest" \
      '[.[][] | select(.name == $digest)] | length' "$current")
    [ "$count" -le 1 ] ||
      fail "candidate digest appears in multiple package rows"
    [ "$count" -eq 1 ] || return 75
  done < <(jq -r '.[]' <<<"$INDEX_DIGESTS" | tr -d '\r')

  root_count=$(jq -r --arg digest "$SUBJECT_DIGEST" \
    '[.[][] | select(.name == $digest)] | length' "$current" | tr -d '\r')
  [ "$root_count" -eq 1 ] || return 75
  root_tags=$(jq -c --arg digest "$SUBJECT_DIGEST" \
    '[.[][] | select(.name == $digest)][0].metadata.container.tags' "$current" |
      tr -d '\r')
  jq -n -e --arg alias "$ALIAS" --argjson tags "$root_tags" \
    '($tags | length == 1) and ($tags[0] == $alias)' >/dev/null ||
    fail "candidate root has an unexpected alias set"

  marker_count=$(jq -r --arg marker "sha256-${SUBJECT_DIGEST#sha256:}" '
    [.[][] | select(any(.metadata.container.tags[]; . == $marker))] | length
  ' "$current" | tr -d '\r')
  [ "$marker_count" -le 1 ] ||
    fail "subject marker is bound to multiple package versions"
  if [ "$marker_count" -eq 1 ]; then
    marker_digest=$(jq -r --arg marker "sha256-${SUBJECT_DIGEST#sha256:}" '
      [.[][] | select(any(.metadata.container.tags[]; . == $marker))][0].name
    ' "$current" | tr -d '\r')
    is_digest "$marker_digest" || fail "subject marker digest is malformed"
  fi

  # Child package rows may carry only the OCI subject marker.  Ordinary
  # release aliases on a child are an unexpected mutation.
  jq -e \
    --arg subject "$SUBJECT_DIGEST" \
    --arg alias "$ALIAS" \
    --arg marker "sha256-${SUBJECT_DIGEST#sha256:}" \
    --argjson candidate "$INDEX_DIGESTS" '
    all(.[][];
      . as $row |
      ($row.name == $subject or
       (($candidate | index($row.name)) == null) or
       all($row.metadata.container.tags[]; . == $marker))
    ) and
    all(.[][] | select(any(.metadata.container.tags[]; . == $alias));
      .name == $subject
    )
  ' "$current" >/dev/null ||
    fail "candidate child carries an unexpected alias"

  if [ "$REQUIRE_SIGNATURE" = true ] && [ "$WRAPPER_COUNT" -eq 0 ]; then
    return 75
  fi

  # Package rows for a marker are part of the candidate projection even when
  # the marker index itself is not a child of the selected root index.
  candidate_with_marker=$(jq -c \
    --argjson candidate "$INDEX_DIGESTS" \
    --arg marker "sha256-${SUBJECT_DIGEST#sha256:}" '
    [.[][] | {id, digest:.name, tags:.metadata.container.tags} as $row |
      select(($candidate | index($row.digest)) != null or
        any($row.tags[]; . == $marker)) | $row]
  ' "$current") || fail "candidate marker projection failed"
  printf '%s\n' "$candidate_with_marker"
  return 0
}

attempt=1
overall_deadline=$(( $(date +%s) + 178 ))
while [ "$attempt" -le 5 ]; do
  now=$(date +%s)
  remaining=$((overall_deadline - now))
  [ "$remaining" -gt 0 ] || break
  budget=28
  [ "$remaining" -lt "$budget" ] && budget=$remaining
  temporary=$(mktemp -- "$PHASE_DIR/.package-versions.XXXXXX") ||
    fail "could not create package response temporary"
  chmod 600 "$temporary" 2>/dev/null || true
  read_attempt "$temporary" "$budget"

  candidate_rows=
  if candidate_rows=$(evaluate_snapshot "$temporary"); then
    cp -- "$temporary" "$PACKAGE_OUTPUT" ||
      fail "complete raw package snapshot could not be preserved"
    normalized=$PHASE_DIR/.normalized.json
    "$NORMALIZE" \
      --package-versions-file "$PACKAGE_OUTPUT" \
      --digest "$SUBJECT_DIGEST" \
      --output "$normalized"
    marker="sha256-${SUBJECT_DIGEST#sha256:}"
    jq -cS \
      --arg digest "$SUBJECT_DIGEST" \
      --arg alias "$ALIAS" \
      --arg marker "$marker" \
      --argjson candidate "$candidate_rows" '
      . as $normalized |
      {
        digest: $digest,
        aliases: {($alias): $digest},
        latest: null,
        versions: (
          ($normalized.versions |
            map(. as $version |
              select(any($candidate[]; .digest == $version.digest))) |
            map(
              if .digest == $digest then
                .tags = [$alias]
              elif ((.tags | index($marker)) != null) then
                .tags = [$marker]
              else
                .tags = []
              end
            ) | sort_by(.digest,.id)
          )
        )
      }
    ' "$normalized" >"$REGISTRY_OUTPUT.tmp" ||
      fail "candidate inventory projection failed"
    [ -s "$REGISTRY_OUTPUT.tmp" ] || fail "candidate inventory projection is empty"
    mv -- "$REGISTRY_OUTPUT.tmp" "$REGISTRY_OUTPUT" ||
      fail "candidate inventory output publication failed"
    KEEP_PHASE=true
    rm -f -- "$temporary" "$normalized"
    printf 'phase_dir=%s\npackage_versions_file=%s\nregistry_inventory_file=%s\n' \
      "$PHASE_DIR" "$PACKAGE_OUTPUT" "$REGISTRY_OUTPUT"
    exit 0
  else
    status=$?
    rm -f -- "$temporary"
    if [ "$status" -ne 75 ]; then
      exit "$status"
    fi
  fi

  if [ "$attempt" -lt 5 ]; then
    now=$(date +%s)
    remaining=$((overall_deadline - now))
    [ "$remaining" -gt 5 ] || break
    sleep 5 || fail "inventory readiness delay failed"
  fi
  attempt=$((attempt + 1))
done

echo "test-promotion inventory remained incomplete after five bounded reads" >&2
exit 75
