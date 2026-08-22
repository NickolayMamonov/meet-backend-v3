#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  build-bootstrap-default-proof.sh --source PATH --jar PATH
    --image-digest sha256:... --image-id sha256:... --platform linux/amd64
    --source-sha SHA --tree-id TREE --version X.Y.Z
    --phase predecessor|candidate|rollback|final --output PATH
    [--introduction-sha SHA --strict-ancestor true]

  build-bootstrap-default-proof.sh --source-checkout PATH --source-sha SHA
    --image-ref IMAGE --phase predecessor|candidate|rollback|final
    --output PATH [--introduction-sha SHA]
    [--git-command PATH] [--docker-command PATH] [--java-command PATH]

  build-bootstrap-default-proof.sh --fixture PATH --output PATH
EOF
  exit 2
}

fail() { echo "bootstrap proof failed: $1" >&2; exit 1; }
sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
digest() { [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]]; }
semver() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
bool() { [ "$1" = true ] || [ "$1" = false ]; }
regular() { [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ]; }
safe_output() {
  [ -n "$1" ] || usage
  [ ! -L "$1" ] || fail "output path is unsafe"
  if [ -e "$1" ]; then [ -f "$1" ] || fail "output path is unsafe"; fi
  [ -d "$(dirname -- "$1")" ] || fail "output directory is unavailable"
}

SOURCE=
CHECKOUT=
JAR=
IMAGE=
IMAGE_DIGEST=
IMAGE_ID=
PLATFORM=
SOURCE_SHA=
TREE_ID=
VERSION=
PHASE=
OUTPUT=
INTRO=
ANCESTOR=
FIXTURE=
IMAGE_INSPECT=
GIT=git
DOCKER=docker
JAVA=java

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] && [ -z "$SOURCE" ] || usage; SOURCE=$2; shift 2 ;;
    --source-checkout) [ "$#" -ge 2 ] && [ -z "$CHECKOUT" ] || usage; CHECKOUT=$2; shift 2 ;;
    --jar) [ "$#" -ge 2 ] && [ -z "$JAR" ] || usage; JAR=$2; shift 2 ;;
    --image|--image-ref) [ "$#" -ge 2 ] && [ -z "$IMAGE" ] || usage; IMAGE=$2; shift 2 ;;
    --image-digest|--image-root-digest) [ "$#" -ge 2 ] && [ -z "$IMAGE_DIGEST" ] || usage; IMAGE_DIGEST=$2; shift 2 ;;
    --image-id) [ "$#" -ge 2 ] && [ -z "$IMAGE_ID" ] || usage; IMAGE_ID=$2; shift 2 ;;
    --platform) [ "$#" -ge 2 ] && [ -z "$PLATFORM" ] || usage; PLATFORM=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] && [ -z "$SOURCE_SHA" ] || usage; SOURCE_SHA=$2; shift 2 ;;
    --tree-id) [ "$#" -ge 2 ] && [ -z "$TREE_ID" ] || usage; TREE_ID=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] && [ -z "$VERSION" ] || usage; VERSION=$2; shift 2 ;;
    --phase) [ "$#" -ge 2 ] && [ -z "$PHASE" ] || usage; PHASE=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] && [ -z "$OUTPUT" ] || usage; OUTPUT=$2; shift 2 ;;
    --introduction-sha) [ "$#" -ge 2 ] && [ -z "$INTRO" ] || usage; INTRO=$2; shift 2 ;;
    --strict-ancestor) [ "$#" -ge 2 ] && [ -z "$ANCESTOR" ] || usage; ANCESTOR=$2; shift 2 ;;
    --fixture) [ "$#" -ge 2 ] && [ -z "$FIXTURE" ] || usage; FIXTURE=$2; shift 2 ;;
    --image-inspect) [ "$#" -ge 2 ] && [ -z "$IMAGE_INSPECT" ] || usage; IMAGE_INSPECT=$2; shift 2 ;;
    --git-command) [ "$#" -ge 2 ] && [ "$GIT" = git ] || usage; GIT=$2; shift 2 ;;
    --docker-command) [ "$#" -ge 2 ] && [ "$DOCKER" = docker ] || usage; DOCKER=$2; shift 2 ;;
    --java-command) [ "$#" -ge 2 ] && [ "$JAVA" = java ] || usage; JAVA=$2; shift 2 ;;
    --help|-h) usage ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v unzip >/dev/null 2>&1 || fail "unzip is required"
command -v zipinfo >/dev/null 2>&1 || fail "zipinfo is required"
safe_output "$OUTPUT"

if [ -n "$FIXTURE" ]; then
  regular "$FIXTURE" || fail "fixture input is unavailable"
  jq -e '
    type == "object" and
    (keys | sort) == ["imageDigest","imageId","introductionSha","jar","phase",
      "platform","source","sourceSha","strictAncestor","treeId","version"]
  ' "$FIXTURE" >/dev/null 2>&1 || fail "fixture input is not closed JSON"
  BASE=$(cd -- "$(dirname -- "$FIXTURE")" && pwd)
  SOURCE=$(jq -r '.source' "$FIXTURE")
  JAR=$(jq -r '.jar' "$FIXTURE")
  IMAGE_DIGEST=$(jq -r '.imageDigest' "$FIXTURE")
  IMAGE_ID=$(jq -r '.imageId' "$FIXTURE")
  PLATFORM=$(jq -r '.platform' "$FIXTURE")
  SOURCE_SHA=$(jq -r '.sourceSha' "$FIXTURE")
  TREE_ID=$(jq -r '.treeId' "$FIXTURE")
  VERSION=$(jq -r '.version' "$FIXTURE")
  PHASE=$(jq -r '.phase' "$FIXTURE")
  INTRO=$(jq -r '.introductionSha' "$FIXTURE")
  ANCESTOR=$(jq -r '.strictAncestor' "$FIXTURE")
  case "$SOURCE" in /*) ;; *) SOURCE=$BASE/$SOURCE ;; esac
  case "$JAR" in /*) ;; *) JAR=$BASE/$JAR ;; esac
fi
[ -z "$SOURCE" ] || [ -z "$CHECKOUT" ] || usage
[ -n "$SOURCE" ] || [ -n "$CHECKOUT" ] || usage

TMP=$(mktemp -d)
CONTAINER=
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$CONTAINER" ] || "$DOCKER" rm "$CONTAINER" >/dev/null 2>&1 || true
  rm -r -- "$TMP"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
src_file() { printf '%s/%s\n' "$TMP" "$1"; }

if [ -n "$CHECKOUT" ]; then
  [ -d "$CHECKOUT" ] || fail "source checkout is unavailable"
  command -v "$GIT" >/dev/null 2>&1 || fail "git command is unavailable"
  sha "$SOURCE_SHA" || fail "source SHA is malformed"
  [ "$("$GIT" -C "$CHECKOUT" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" = "$SOURCE_SHA" ] ||
    fail "source checkout does not match source SHA"
  [ -z "$("$GIT" -C "$CHECKOUT" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ] ||
    fail "source checkout is dirty"
  [ -z "$("$GIT" -C "$CHECKOUT" symbolic-ref -q HEAD 2>/dev/null)" ] ||
    fail "source checkout is attached"
  TREE_ID=$("$GIT" -C "$CHECKOUT" rev-parse --verify "$SOURCE_SHA^{tree}" 2>/dev/null) ||
    fail "source tree is unavailable"
  VERSION_JSON=$("$GIT" -C "$CHECKOUT" show "$SOURCE_SHA:version.json" 2>/dev/null) ||
    fail "source version is unavailable"
  VERSION=$(jq -er '
    if type == "object" and (keys == ["version"]) and
       (.version | type == "string" and
        test("^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$"))
    then .version else error("invalid version") end
  ' <<<"$VERSION_JSON" 2>/dev/null) || fail "source version is not canonical"
  for name in application.yml application-prod.yml; do
    "$GIT" -C "$CHECKOUT" show "$SOURCE_SHA:src/main/resources/$name" \
      >"$(src_file "$name")" 2>/dev/null || fail "source bootstrap file is unavailable"
  done
  if [ -n "$INTRO" ]; then
    sha "$INTRO" || fail "introduction SHA is malformed"
    [ "$INTRO" != "$SOURCE_SHA" ] || fail "source is not a strict ancestor"
    "$GIT" -C "$CHECKOUT" rev-parse --verify "$INTRO^{commit}" >/dev/null 2>&1 ||
      fail "introduction commit is unavailable"
  fi
else
  [ -d "$SOURCE" ] || fail "source directory is unavailable"
  for name in application.yml application-prod.yml; do
    regular "$SOURCE/$name" || fail "source bootstrap file is unavailable"
    cp -- "$SOURCE/$name" "$(src_file "$name")"
  done
fi

if [ -z "$JAR" ]; then
  [ -n "$IMAGE" ] || usage
  command -v "$DOCKER" >/dev/null 2>&1 || fail "docker command is unavailable"
  command -v "$JAVA" >/dev/null 2>&1 || fail "java command is unavailable"
  "$JAVA" -version >/dev/null 2>&1 || fail "java command is unavailable"
  INSPECT=$("$DOCKER" image inspect --format '{{json .}}' "$IMAGE" 2>/dev/null) ||
    fail "image inspection failed"
  JAR=$TMP/app.jar
  CONTAINER=$("$DOCKER" create "$IMAGE" 2>/dev/null) || fail "image container creation failed"
  [ -n "$CONTAINER" ] || fail "image container ID is unavailable"
  "$DOCKER" cp "$CONTAINER:/app/app.jar" "$JAR" >/dev/null 2>&1 ||
    fail "application JAR extraction failed"
elif [ -n "$IMAGE_INSPECT" ]; then
  regular "$IMAGE_INSPECT" || fail "image inspection fixture is unavailable"
  INSPECT=$(<"$IMAGE_INSPECT")
fi
[ -z "$IMAGE_DIGEST" ] && [ -n "$IMAGE" ] && [[ "$IMAGE" == *@sha256:* ]] &&
  IMAGE_DIGEST=${IMAGE##*@}
[ -f "$JAR" ] && [ ! -L "$JAR" ] && [ -r "$JAR" ] || fail "application JAR is unavailable"

if [ -n "${INSPECT:-}" ]; then
  IMAGE_OBJECT=$(jq -ce 'if type == "array" and length == 1 then .[0] else . end |
    if type == "object" then . else error("not image object") end' <<<"$INSPECT" 2>/dev/null) ||
    fail "image inspection is malformed"
  inspected_id=$(jq -er 'if (.Id|type)=="string" then .Id elif (.imageId|type)=="string" then .imageId else error end' <<<"$IMAGE_OBJECT" 2>/dev/null) ||
    fail "local image ID is unavailable"
  inspected_platform=$(jq -er '
    if (.platform|type)=="string" then .platform
    elif (.Os|type)=="string" and (.Architecture|type)=="string"
      then .Os + "/" + .Architecture
    else error end
  ' <<<"$IMAGE_OBJECT" 2>/dev/null) || fail "image platform is unavailable"
  inspected_digest=$(jq -er --arg expected "$IMAGE_DIGEST" '
    if (.rootDigest|type)=="string" then .rootDigest
    elif (.imageDigest|type)=="string" then .imageDigest
    elif (.RepoDigests|type)=="array" then
      ([.RepoDigests[] | select(type=="string" and test("@sha256:[0-9a-f]{64}$")) |
        split("@")[1]] | unique |
        if length == 1 then .[0]
        elif length == 0 and $expected != "" then $expected
        else error end)
    elif $expected != "" then $expected
    else error end
  ' <<<"$IMAGE_OBJECT" 2>/dev/null) || fail "image root digest is unavailable"
  [ -z "$IMAGE_ID" ] || [ "$IMAGE_ID" = "$inspected_id" ] ||
    fail "local image ID does not match inspection"
  [ -z "$PLATFORM" ] || [ "$PLATFORM" = "$inspected_platform" ] ||
    fail "image platform does not match inspection"
  [ -z "$IMAGE_DIGEST" ] || [ "$IMAGE_DIGEST" = "$inspected_digest" ] ||
    fail "image root digest does not match inspection"
  if [ -n "$IMAGE" ] && [[ "$IMAGE" == *@sha256:* ]]; then
    pinned_digest=${IMAGE##*@}
    digest "$pinned_digest" || fail "image reference digest is malformed"
    [ "$pinned_digest" = "$inspected_digest" ] ||
      fail "digest-pinned image reference does not match inspection"
  fi
  IMAGE_ID=$inspected_id
  PLATFORM=$inspected_platform
  IMAGE_DIGEST=$inspected_digest
fi

digest "$IMAGE_DIGEST" || fail "image root digest is malformed"
digest "$IMAGE_ID" || fail "local image ID is malformed"
[ "$PLATFORM" = linux/amd64 ] || fail "image platform is not linux/amd64"
sha "$SOURCE_SHA" || fail "source SHA is malformed"
sha "$TREE_ID" || fail "source tree ID is malformed"
semver "$VERSION" || fail "source version is malformed"
case "$PHASE" in predecessor|candidate|rollback|final) ;; *) usage ;; esac
[ -z "$INTRO" ] || sha "$INTRO" || fail "introduction SHA is malformed"
[ -z "$ANCESTOR" ] || bool "$ANCESTOR" || fail "strict ancestry value is malformed"
[ "$ANCESTOR" != true ] || [ -n "$INTRO" ] || fail "strict ancestry is unbound"

if [ -n "$INTRO" ] && [ -n "$CHECKOUT" ]; then
  if [ "$INTRO" = "$SOURCE_SHA" ]; then ANCESTOR=false
  elif "$GIT" -C "$CHECKOUT" merge-base --is-ancestor "$SOURCE_SHA" "$INTRO" >/dev/null 2>&1; then
    ANCESTOR=true
  else ANCESTOR=false
  fi
fi

if [ -n "$INTRO" ] && [ -z "$CHECKOUT" ] && [ -z "$ANCESTOR" ]; then
  fail "legacy ancestry is unbound"
fi

for name in application.yml application-prod.yml; do
  entry=BOOT-INF/classes/$name
  entries=$(zipinfo -1 "$JAR" 2>/dev/null) || fail "application JAR is malformed"
  entry_count=$(printf '%s\n' "$entries" | grep -Fxc "$entry" || true)
  [ "${entry_count:-0}" -eq 1 ] ||
    fail "application JAR entry is missing or duplicated"
  unzip -p "$JAR" "$entry" >"$TMP/jar-$name" 2>/dev/null ||
    fail "application JAR entry extraction failed"
  cmp -s "$(src_file "$name")" "$TMP/jar-$name" || fail "source and JAR bootstrap files differ"
done

classify() {
  local file=$1 env props exact nested_exact dotted_exact demo
  env=$(grep -Fo DEMO_CATALOG_BOOTSTRAP_ENABLED "$file" | wc -l | tr -d ' ')
  props=$(grep -Ec '^[[:space:]]*["'"'"']?(bootstrap-enabled|app[.]demo-catalog[.]bootstrap-enabled|demo-catalog[.]bootstrap-enabled)["'"'"']?[[:space:]]*:' "$file" || true)
  nested_exact=$(grep -Ec '^[[:space:]]*bootstrap-enabled[[:space:]]*:[[:space:]]*\$\{DEMO_CATALOG_BOOTSTRAP_ENABLED:false\}[[:space:]]*$' "$file" || true)
  dotted_exact=$(grep -Ec '^[[:space:]]*["'"'"']?(app[.]demo-catalog[.]bootstrap-enabled|demo-catalog[.]bootstrap-enabled)["'"'"']?[[:space:]]*:[[:space:]]*\$\{DEMO_CATALOG_BOOTSTRAP_ENABLED:false\}[[:space:]]*$' "$file" || true)
  demo=$(grep -Ec '^[[:space:]]*demo-catalog[[:space:]]*:' "$file" || true)
  exact=$((nested_exact + dotted_exact))
  if [ "$env" -eq 0 ] && [ "$props" -eq 0 ]; then
    printf legacy
  elif [ "$env" -eq 1 ] && [ "$props" -eq 1 ] && [ "$exact" -eq 1 ] &&
    { [ "$dotted_exact" -eq 1 ] ||
      { [ "$nested_exact" -eq 1 ] && [ "$demo" -eq 1 ]; }; }; then
    printf declared
  else
    fail "bootstrap default is malformed, duplicated, true, or unbound"
  fi
}

FIRST=$(classify "$(src_file application.yml)")
SECOND=$(classify "$(src_file application-prod.yml)")
[ "$FIRST" = "$SECOND" ] || fail "bootstrap mode is mixed"
case "$FIRST" in
  declared) MODE=declared-false ;;
  legacy)
    [ "$PHASE" = predecessor ] || fail "legacy mode is predecessor-only"
    sha "$INTRO" || fail "legacy introduction SHA is unavailable"
    [ "$INTRO" != "$SOURCE_SHA" ] || fail "legacy source is not a strict ancestor"
    [ "$ANCESTOR" = true ] || fail "legacy source is not a strict ancestor"
    if [ -n "$CHECKOUT" ]; then
      for name in application.yml application-prod.yml; do
        "$GIT" -C "$CHECKOUT" show "$INTRO:src/main/resources/$name" \
          >"$(src_file "introduction-$name")" 2>/dev/null ||
          fail "introduction source bootstrap file is unavailable"
        [ "$(classify "$(src_file "introduction-$name")")" = declared ] ||
          fail "introduction SHA does not declare bootstrap control"
      done
    fi
    MODE=legacy-not-applicable
    ;;
  *) fail "bootstrap mode is unavailable" ;;
esac

SOURCE_PROPERTIES=$(sha256sum "$(src_file application.yml)" | awk '{print $1}')
SOURCE_PRODUCTION=$(sha256sum "$(src_file application-prod.yml)" | awk '{print $1}')
JAR_PROPERTIES=$(sha256sum "$TMP/jar-application.yml" | awk '{print $1}')
JAR_PRODUCTION=$(sha256sum "$TMP/jar-application-prod.yml" | awk '{print $1}')
[ "$SOURCE_PROPERTIES" = "$JAR_PROPERTIES" ] && [ "$SOURCE_PRODUCTION" = "$JAR_PRODUCTION" ] ||
  fail "source and JAR hashes differ"

TEMPORARY=$OUTPUT.tmp.$$
trap 'rm -f -- "$TEMPORARY"' EXIT HUP INT TERM
jq -cnS \
  --arg schema meet-backend/test-promotion-bootstrap-proof/v1 \
  --arg mode "$MODE" --arg phase "$PHASE" --arg imageDigest "$IMAGE_DIGEST" \
  --arg imageId "$IMAGE_ID" --arg platform "$PLATFORM" --arg sourceSha "$SOURCE_SHA" \
  --arg treeId "$TREE_ID" --arg version "$VERSION" --arg introductionSha "$INTRO" \
  --arg strictAncestor "${ANCESTOR:-false}" \
  --arg sourcePropertiesSha256 "$SOURCE_PROPERTIES" --arg sourceProductionSha256 "$SOURCE_PRODUCTION" \
  --arg jarPropertiesSha256 "$JAR_PROPERTIES" --arg jarProductionSha256 "$JAR_PRODUCTION" '
  {
    bootstrapControlPresent: ($mode == "declared-false"),
    effectiveDefault: false,
    imageDigest: $imageDigest,
    imageId: $imageId,
    introductionSha: $introductionSha,
    jarPropertiesSha256: $jarPropertiesSha256,
    jarProductionSha256: $jarProductionSha256,
    bootstrapMode: $mode,
    phase: $phase,
    platform: $platform,
    schema: $schema,
    sourcePropertiesSha256: $sourcePropertiesSha256,
    sourceProductionSha256: $sourceProductionSha256,
    sourceSha: $sourceSha,
    strictAncestor: ($strictAncestor == "true"),
    treeId: $treeId,
    version: $version
  }' >"$TEMPORARY" || fail "proof construction failed"
chmod 600 "$TEMPORARY" 2>/dev/null || true
mv -f -- "$TEMPORARY" "$OUTPUT" || fail "proof publication failed"
trap - EXIT HUP INT TERM
