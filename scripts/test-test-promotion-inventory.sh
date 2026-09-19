#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
READER=$ROOT_DIR/scripts/read-test-promotion-inventory.sh
NORMALIZE=$ROOT_DIR/scripts/normalize-ghcr-package-inventory.sh
TMP=$(mktemp -d)
if [ "${KEEP_TEST_TMP:-false}" = true ]; then
  trap 'printf "test temporary directory: %s\n" "$TMP" >&2' EXIT HUP INT TERM
else
  trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
fi

command -v jq >/dev/null 2>&1
command -v sha256sum >/dev/null 2>&1
command -v timeout >/dev/null 2>&1
[ -x "$READER" ] && [ -x "$NORMALIZE" ]

SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
ALIAS=test-sha-$SOURCE_SHA
IMAGE=ghcr.io/example/meet-backend
PROTECTED_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ROOT_WORK=$TMP/root.json
PLATFORM_WORK=$TMP/platform.json
WRAPPER_WORK=$TMP/wrapper.json
INDEX_WORK=$TMP/index.json
BEFORE=$TMP/before.json
PROTECTED=$TMP/protected.json

jq -nS \
  '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
    config:{mediaType:"application/vnd.oci.image.config.v1+json",
      digest:"sha256:1111111111111111111111111111111111111111111111111111111111111111",size:1},
    layers:[]}' >"$PLATFORM_WORK"
PLATFORM_DIGEST=sha256:$(sha256sum "$PLATFORM_WORK" | awk '{print $1}')
jq -nS --arg digest "$PLATFORM_DIGEST" \
  '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
    config:{mediaType:"application/vnd.oci.image.config.v1+json",
      digest:"sha256:2222222222222222222222222222222222222222222222222222222222222222",size:1},
    layers:[],subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",
      digest:$digest,size:1},
    artifactType:"application/vnd.dev.sigstore.bundle.v0.3+json"}' >"$WRAPPER_WORK"
WRAPPER_DIGEST=sha256:$(sha256sum "$WRAPPER_WORK" | awk '{print $1}')
jq -nS --arg platform "$PLATFORM_DIGEST" --arg wrapper "$WRAPPER_DIGEST" \
  '{schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",
    manifests:[
      {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,size:1,
       platform:{os:"linux",architecture:"amd64"}},
      {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$wrapper,size:1,
       annotations:{"vnd.docker.reference.type":"attestation-manifest",
         "vnd.docker.reference.artifact.type":"application/vnd.dev.sigstore.bundle.v0.3+json",
         "vnd.docker.reference.digest":$platform}}
    ]}' >"$ROOT_WORK"
ROOT_DIGEST=sha256:$(sha256sum "$ROOT_WORK" | awk '{print $1}')
cp -- "$ROOT_WORK" "$INDEX_WORK"

jq -nS --arg digest "$ROOT_DIGEST" --arg platform "$PLATFORM_DIGEST" \
  --arg wrapper "$WRAPPER_DIGEST" --arg alias "$ALIAS" \
  --arg protected "$PROTECTED_DIGEST" '
  [[
    {id:1,name:$protected,metadata:{container:{tags:["v1.0.0"]}}},
    {id:2,name:$digest,metadata:{container:{tags:[$alias]}}},
    {id:3,name:$platform,metadata:{container:{tags:[]}}},
    {id:4,name:$wrapper,metadata:{container:{tags:[]}}}
  ]]
' >"$BEFORE"
jq -nS --arg protected "$PROTECTED_DIGEST" \
  '{schema:"meet-backend/test-promotion-protected-state/v1",
    protected:{subjectDigests:[$protected]}}' >"$PROTECTED"

GH=$TMP/gh
SLEEP=$TMP/sleep
cat >"$GH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] && [ "$2" = --paginate ] && [ "$3" = --slurp ]
if [ -n "${GH_SEQUENCE_DIR:-}" ]; then
  count=$(tr -d '[:space:]' <"${GH_COUNT_FILE:?}")
  count=$((count + 1))
  printf '%s\n' "$count" >"${GH_COUNT_FILE:?}"
  response=$GH_SEQUENCE_DIR/$count.json
else
  response=${GH_RESPONSE:?}
fi
cat -- "$response"
EOF
cat >"$SLEEP" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${1:?}" >>"${SLEEP_LOG:?}"
EOF
chmod 755 "$GH" "$SLEEP"
if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* ]]; then
  cat >"$TMP/timeout" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == --* ]]; do shift; done
shift
exec "$@"
EOF
  chmod 755 "$TMP/timeout"
fi

make_response() {
  local output=$1 root_tags=$2 platform_tags=$3 wrapper_tags=$4
  jq -nS --arg root "$ROOT_DIGEST" --arg platform "$PLATFORM_DIGEST" \
    --arg wrapper "$WRAPPER_DIGEST" --arg protected "$PROTECTED_DIGEST" \
    --arg alias "$ALIAS" --argjson rootTags "$root_tags" \
    --argjson platformTags "$platform_tags" --argjson wrapperTags "$wrapper_tags" '
    [[
      {id:1,name:$protected,metadata:{container:{tags:["v1.0.0"]}}},
      {id:2,name:$root,metadata:{container:{tags:$rootTags}}},
      {id:3,name:$platform,metadata:{container:{tags:$platformTags}}},
      {id:4,name:$wrapper,metadata:{container:{tags:$wrapperTags}}}
    ]]
  ' >"$output"
}

RESPONSE=$TMP/response.json
make_response "$RESPONSE" "[\"$ALIAS\"]" '[]' '[]'
PATH="$TMP:$PATH" GH_RESPONSE=$RESPONSE \
  SLEEP_LOG=$TMP/sleeps \
  "$READER" --image "$IMAGE" --alias "$ALIAS" \
  --subject-digest "$ROOT_DIGEST" --platform-subject "$PLATFORM_DIGEST" \
  --index-file "$INDEX_WORK" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --require-signature true \
  --output-dir "$TMP" >/dev/null

PHASE=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'test-promotion-inventory.*' | head -1)
[ -n "$PHASE" ]
cmp "$RESPONSE" "$PHASE/package-versions.json"
jq -e --arg root "$ROOT_DIGEST" --arg alias "$ALIAS" '
  .digest == $root and .aliases == {($alias):$root} and .latest == null and
  ([.versions[] | select(.digest == $root)][0].tags == [$alias])
' "$PHASE/registry-inventory.json" >/dev/null
[ ! -s "$TMP/sleeps" ]

# A complete empty snapshot is valid, but missing candidate visibility is the
# sole retryable result.
EMPTY=$TMP/empty.json
jq -n '[[]]' >"$EMPTY"

# The fifth complete read is allowed to converge, with exactly four bounded
# delays and no page mixing across attempts.
SEQUENCE=$TMP/sequence
mkdir -p "$SEQUENCE"
for attempt in 1 2 3 4; do
  cp -- "$EMPTY" "$SEQUENCE/$attempt.json"
done
cp -- "$RESPONSE" "$SEQUENCE/5.json"
printf '0\n' >"$TMP/gh-count"
rm -f "$TMP/sleeps"
SEQUENCE_OUTPUT=$TMP/fifth-attempt
mkdir -p "$SEQUENCE_OUTPUT"
PATH="$TMP:$PATH" GH_SEQUENCE_DIR=$SEQUENCE GH_COUNT_FILE=$TMP/gh-count \
  SLEEP_LOG=$TMP/sleeps \
  "$READER" --image "$IMAGE" --alias "$ALIAS" \
  --subject-digest "$ROOT_DIGEST" --platform-subject "$PLATFORM_DIGEST" \
  --index-file "$INDEX_WORK" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --require-signature false \
  --output-dir "$SEQUENCE_OUTPUT" >/dev/null
[ "$(tr -d '[:space:]' <"$TMP/gh-count")" -eq 5 ]
[ "$(wc -l <"$TMP/sleeps" | tr -d '[:space:]')" -eq 4 ]

# Five attempts produce four sleeps and no final file.
rm -f "$TMP/sleeps"
set +e
PATH="$TMP:$PATH" GH_RESPONSE=$EMPTY \
  SLEEP_LOG=$TMP/sleeps \
  "$READER" --image "$IMAGE" --alias "$ALIAS" \
  --subject-digest "$ROOT_DIGEST" --platform-subject "$PLATFORM_DIGEST" \
  --index-file "$INDEX_WORK" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --require-signature false \
  --output-dir "$TMP" >/dev/null 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 75 ]
[ "$(wc -l <"$TMP/sleeps" | tr -d '[:space:]')" -eq 4 ]
[ "$(find "$TMP" -mindepth 1 -maxdepth 1 -type d -name 'test-promotion-inventory.*' | wc -l | tr -d '[:space:]')" -eq 1 ]

# An API error and malformed page stream are terminal and must not consume a
# retry or sleep.
cat >"$GH" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod 755 "$GH"
rm -f "$TMP/sleeps"
set +e
PATH="$TMP:$PATH" GH_RESPONSE=$RESPONSE \
  SLEEP_LOG=$TMP/sleeps \
  "$READER" --image "$IMAGE" --alias "$ALIAS" \
  --subject-digest "$ROOT_DIGEST" --platform-subject "$PLATFORM_DIGEST" \
  --index-file "$INDEX_WORK" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --require-signature false \
  --output-dir "$TMP" >/dev/null 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 1 ]
[ ! -e "$TMP/sleeps" ]

cat >"$GH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] && [ "$2" = --paginate ] && [ "$3" = --slurp ]
cat -- "${GH_RESPONSE:?}"
EOF
chmod 755 "$GH"
printf '[]\n' >"$TMP/malformed.json"
rm -f "$TMP/sleeps"
set +e
PATH="$TMP:$PATH" GH_RESPONSE=$TMP/malformed.json \
  SLEEP_LOG=$TMP/sleeps \
  "$READER" --image "$IMAGE" --alias "$ALIAS" \
  --subject-digest "$ROOT_DIGEST" --platform-subject "$PLATFORM_DIGEST" \
  --index-file "$INDEX_WORK" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --require-signature false \
  --output-dir "$TMP" >/dev/null 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 1 ]
[ ! -e "$TMP/sleeps" ]

if [ "$(uname -s)" = Linux ]; then
  HANG_GH=$TMP/gh-hang
  HANG_CHILD=$TMP/hang-child.pid
  HANG_GRANDCHILD=$TMP/hang-grandchild.pid
  cat >"$HANG_GH" <<'EOF'
#!/usr/bin/env bash
set -eu
( trap '' TERM INT HUP; while :; do sleep 1; done ) &
grandchild=$!
printf '%s\n' "$BASHPID" >"${HANG_CHILD:?}"
printf '%s\n' "$grandchild" >"${HANG_GRANDCHILD:?}"
trap '' TERM INT HUP
while :; do sleep 1; done
EOF
  chmod 755 "$HANG_GH"
  run_hang() {
    local signal=$1
    cp -- "$HANG_GH" "$GH"
    chmod 755 "$GH"
    rm -f "$HANG_CHILD" "$HANG_GRANDCHILD"
    set +e
    PATH="$TMP:$PATH" \
      HANG_GRANDCHILD="$HANG_GRANDCHILD" \
      HANG_CHILD="$HANG_CHILD" \
      TEST_PROMOTION_INVENTORY_ATTEMPT_BUDGET_SECONDS=5 \
      "$READER" --image "$IMAGE" --alias "$ALIAS" \
      --subject-digest "$ROOT_DIGEST" --platform-subject "$PLATFORM_DIGEST" \
      --index-file "$INDEX_WORK" --before-inventory "$BEFORE" \
      --protected-state "$PROTECTED" --require-signature false \
      --output-dir "$TMP" >/dev/null 2>&1 &
    reader_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ -s "$HANG_GRANDCHILD" ] && break
      sleep 0.1
    done
    kill -"$signal" "$reader_pid" 2>/dev/null || true
    wait "$reader_pid"
    status=$?
    set -e
    [ "$status" -ne 0 ]
    for pid_file in "$HANG_CHILD" "$HANG_GRANDCHILD"; do
      if [ -s "$pid_file" ]; then
        pid=$(tr -d '[:space:]' <"$pid_file")
        ! kill -0 "$pid" 2>/dev/null
      fi
    done
  }
  run_hang TERM
  run_hang INT
  run_hang HUP
fi

echo "test-test-promotion-inventory passed: exact raw preservation, signature visibility, bounded exhaustion, and terminal API failure"
