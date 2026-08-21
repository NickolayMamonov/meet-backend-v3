#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD=$ROOT/scripts/build-bootstrap-default-proof.sh
IMAGE_FIXTURE=$ROOT/scripts/fixtures/bootstrap-default-proof/image-inspect.json
TMP=$(mktemp -d)
cleanup() { local s=$?; trap - EXIT HUP INT TERM; rm -r -- "$TMP"; exit "$s"; }
trap cleanup EXIT HUP INT TERM

for command_name in jq git jar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "bootstrap proof fixtures require $command_name" >&2
    exit 1
  }
done

git_config() {
  git -C "$1" config user.name fixture
  git -C "$1" config user.email fixture@example.invalid
}

expect_failure() {
  local name=$1; shift
  if "$@" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
    echo "expected rejection: $name" >&2; exit 1
  fi
  [ ! -s "$TMP/$name.out" ] || { echo "rejection emitted stdout: $name" >&2; exit 1; }
  [ -s "$TMP/$name.err" ] || { echo "rejection omitted stderr: $name" >&2; exit 1; }
  ! grep -Eiq 'fixture-secret|password|token|private key' "$TMP/$name.err" ||
    { echo "rejection exposed sensitive material: $name" >&2; exit 1; }
}

make_jar() {
  local repo=$1 commit=$2 output=$3 work
  work=$TMP/classes-$(basename "$output")
  mkdir -p "$work/BOOT-INF/classes"
  git -C "$repo" show "$commit:src/main/resources/application.yml" \
    >"$work/BOOT-INF/classes/application.yml"
  git -C "$repo" show "$commit:src/main/resources/application-prod.yml" \
    >"$work/BOOT-INF/classes/application-prod.yml"
  jar --create --file "$output" -C "$work" BOOT-INF/classes/application.yml \
    -C "$work" BOOT-INF/classes/application-prod.yml
}

REPO=$TMP/repo
git init -q --initial-branch=fixture "$REPO"
git_config "$REPO"
mkdir -p "$REPO/src/main/resources"
printf '{\n  "version": "1.2.0"\n}\n' >"$REPO/version.json"
printf '%s\n' spring: >"$REPO/src/main/resources/application.yml"
cp -- "$REPO/src/main/resources/application.yml" \
  "$REPO/src/main/resources/application-prod.yml"
git -C "$REPO" add .
git -C "$REPO" commit -qm predecessor
PREDECESSOR=$(git -C "$REPO" rev-parse HEAD)

for file in application.yml application-prod.yml; do
  cat >>"$REPO/src/main/resources/$file" <<'EOF'
app:
  demo-catalog:
    bootstrap-enabled: ${DEMO_CATALOG_BOOTSTRAP_ENABLED:false}
EOF
done
git -C "$REPO" add .
git -C "$REPO" commit -qm introduction
INTRO=$(git -C "$REPO" rev-parse HEAD)
TREE=$(git -C "$REPO" rev-parse "$INTRO^{tree}")
git clone -q "$REPO" "$TMP/checkout"
git -C "$TMP/checkout" checkout -q --detach "$INTRO"
CHECKOUT=$TMP/checkout
make_jar "$REPO" "$INTRO" "$TMP/candidate.jar"
make_jar "$REPO" "$PREDECESSOR" "$TMP/predecessor.jar"

proof() {
  local phase=$1 commit=$2 jar_file=$3 output=$4
  shift 4
  git -C "$CHECKOUT" checkout -q --detach "$commit"
  "$BUILD" --source-checkout "$CHECKOUT" --source-sha "$commit" --jar "$jar_file" \
    --image-inspect "$IMAGE_FIXTURE" --phase "$phase" --output "$output" "$@"
}

proof candidate "$INTRO" "$TMP/candidate.jar" "$TMP/candidate.json"
proof final "$INTRO" "$TMP/candidate.jar" "$TMP/final.json"
proof rollback "$INTRO" "$TMP/candidate.jar" "$TMP/rollback.json"
proof predecessor "$PREDECESSOR" "$TMP/predecessor.jar" "$TMP/predecessor.json" \
  --introduction-sha "$INTRO"

jq -e --arg source "$INTRO" --arg tree "$TREE" '
  (keys | sort) == [
    "bootstrapControlPresent","bootstrapMode","effectiveDefault",
    "imageDigest","imageId","introductionSha","jarProductionSha256",
    "jarPropertiesSha256","phase","platform","schema",
    "sourceProductionSha256","sourcePropertiesSha256","sourceSha",
    "strictAncestor","treeId","version"
  ] and .schema == "meet-backend/test-promotion-bootstrap-proof/v1" and
  .bootstrapMode == "declared-false" and .phase == "candidate" and
  .bootstrapControlPresent == true and .effectiveDefault == false and
  .introductionSha == "" and .strictAncestor == false and
  .platform == "linux/amd64" and .sourceSha == $source and .treeId == $tree and
  .version == "1.2.0" and
  .sourcePropertiesSha256 == .jarPropertiesSha256 and
  .sourceProductionSha256 == .jarProductionSha256 and
  (.imageDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.imageId | test("^sha256:[0-9a-f]{64}$"))
' "$TMP/candidate.json" >/dev/null
jq -e '.bootstrapMode == "declared-false" and .phase == "final"' "$TMP/final.json" >/dev/null
jq -e '.bootstrapMode == "declared-false" and .phase == "rollback"' "$TMP/rollback.json" >/dev/null
jq -e '.bootstrapMode == "legacy-not-applicable" and .phase == "predecessor" and
  .bootstrapControlPresent == false and .introductionSha == $intro and
  .strictAncestor == true' --arg intro "$INTRO" "$TMP/predecessor.json" >/dev/null
proof candidate "$INTRO" "$TMP/candidate.jar" "$TMP/repeat.json"
cmp -- "$TMP/candidate.json" "$TMP/repeat.json"
[ "$(wc -l <"$TMP/candidate.json" | tr -d ' ')" -eq 1 ]
jq -cS . "$TMP/candidate.json" >"$TMP/canonical.json"
cmp -- "$TMP/candidate.json" "$TMP/canonical.json"

git -C "$CHECKOUT" checkout -q --detach "$INTRO"
BOOTSTRAP_REAL_GIT=$(command -v git)
export BOOTSTRAP_REAL_GIT
export BOOTSTRAP_IMAGE_INSPECT=$IMAGE_FIXTURE
export BOOTSTRAP_FIXTURE_JAR=$TMP/candidate.jar
proof_production() {
  "$BUILD" --source-checkout "$CHECKOUT" --source-sha "$INTRO" \
    --image-ref fixture/image:offline --phase candidate --output "$1" \
    --git-command "$ROOT/scripts/fixtures/bootstrap-default-proof/git-shim.sh" \
    --docker-command "$ROOT/scripts/fixtures/bootstrap-default-proof/docker-shim.sh" \
    --java-command "$ROOT/scripts/fixtures/bootstrap-default-proof/java-shim.sh"
}
proof_production "$TMP/production.json"
cmp -- "$TMP/candidate.json" "$TMP/production.json"
export BOOTSTRAP_DOCKER_FAIL=true
expect_failure production-docker-failure proof_production "$TMP/reject.json"
unset BOOTSTRAP_DOCKER_FAIL

for phase in candidate final rollback; do
  expect_failure "legacy-$phase" "$BUILD" --source-checkout "$CHECKOUT" \
    --source-sha "$PREDECESSOR" --jar "$TMP/predecessor.jar" \
    --image-inspect "$IMAGE_FIXTURE" --phase "$phase" --output "$TMP/reject.json" \
    --introduction-sha "$INTRO"
done
expect_failure legacy-unbound "$BUILD" --source "$REPO/src/main/resources" \
  --jar "$TMP/predecessor.jar" --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$PREDECESSOR" --tree-id "$TREE" --version 1.2.0 \
  --phase predecessor --output "$TMP/reject.json"
expect_failure legacy-missing-introduction "$BUILD" --source "$REPO/src/main/resources" \
  --jar "$TMP/predecessor.jar" --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$PREDECESSOR" --tree-id "$TREE" --version 1.2.0 \
  --phase predecessor --output "$TMP/reject.json" --strict-ancestor true
expect_failure bad-platform "$BUILD" --source "$REPO/src/main/resources" \
  --jar "$TMP/candidate.jar" --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/arm64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

MUTATION=$TMP/mutation
mkdir "$MUTATION"
cp -- "$REPO/src/main/resources/application.yml" "$MUTATION/application.yml"
cp -- "$REPO/src/main/resources/application-prod.yml" "$MUTATION/application-prod.yml"
sed -i 's/DEMO_CATALOG_BOOTSTRAP_ENABLED:false/DEMO_CATALOG_BOOTSTRAP_ENABLED:true/' \
  "$MUTATION/application.yml"
make_jar_dir() {
  local dir=$1 output=$2 work
  work=$TMP/dir-classes-$(basename "$output")
  mkdir -p "$work/BOOT-INF/classes"
  cp -- "$dir/application.yml" "$work/BOOT-INF/classes/application.yml"
  cp -- "$dir/application-prod.yml" "$work/BOOT-INF/classes/application-prod.yml"
  jar --create --file "$output" -C "$work" BOOT-INF/classes/application.yml \
    -C "$work" BOOT-INF/classes/application-prod.yml
}
make_jar_dir "$MUTATION" "$TMP/true.jar"
expect_failure true-default "$BUILD" --source "$MUTATION" --jar "$TMP/true.jar" \
  --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

cp -- "$REPO/src/main/resources/application.yml" "$MUTATION/application.yml"
printf '%s\n' '  bootstrap-enabled: ${DEMO_CATALOG_BOOTSTRAP_ENABLED:false}' \
  >>"$MUTATION/application.yml"
make_jar_dir "$MUTATION" "$TMP/duplicate.jar"
expect_failure duplicate "$BUILD" --source "$MUTATION" --jar "$TMP/duplicate.jar" \
  --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

cp -- "$REPO/src/main/resources/application.yml" "$MUTATION/application.yml"
cp -- "$REPO/src/main/resources/application-prod.yml" "$MUTATION/application-prod.yml"
sed -i 's/DEMO_CATALOG_BOOTSTRAP_ENABLED:false/DEMO_CATALOG_BOOTSTRAP_ENABLED/' \
  "$MUTATION/application.yml"
make_jar_dir "$MUTATION" "$TMP/unbound.jar"
expect_failure unbound "$BUILD" --source "$MUTATION" --jar "$TMP/unbound.jar" \
  --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

cp -- "$REPO/src/main/resources/application.yml" "$MUTATION/application.yml"
cp -- "$REPO/src/main/resources/application-prod.yml" "$MUTATION/application-prod.yml"
make_jar_dir "$MUTATION" "$TMP/mismatch.jar"
printf '%s\n' mismatch >>"$MUTATION/application-prod.yml"
expect_failure source-jar-mismatch "$BUILD" --source "$MUTATION" --jar "$TMP/mismatch.jar" \
  --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

MIXED=$TMP/mixed
mkdir "$MIXED"
cp -- "$REPO/src/main/resources/application.yml" "$MIXED/application.yml"
git -C "$REPO" show "$PREDECESSOR:src/main/resources/application-prod.yml" \
  >"$MIXED/application-prod.yml"
make_jar_dir "$MIXED" "$TMP/mixed.jar"
expect_failure mixed-mode "$BUILD" --source "$MIXED" --jar "$TMP/mixed.jar" \
  --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

cp -- "$REPO/src/main/resources/application.yml" "$MUTATION/application.yml"
cp -- "$REPO/src/main/resources/application-prod.yml" "$MUTATION/application-prod.yml"
sed -i 's/^[[:space:]]*bootstrap-enabled:/app.demo-catalog.bootstrap-enabled:/' \
  "$MUTATION/application.yml"
sed -i 's/DEMO_CATALOG_BOOTSTRAP_ENABLED:false/DEMO_CATALOG_BOOTSTRAP_ENABLED:true/' \
  "$MUTATION/application.yml"
make_jar_dir "$MUTATION" "$TMP/dotted-true.jar"
expect_failure dotted-true "$BUILD" --source "$MUTATION" --jar "$TMP/dotted-true.jar" \
  --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

cp -- "$REPO/src/main/resources/application.yml" "$MUTATION/application.yml"
cp -- "$REPO/src/main/resources/application-prod.yml" "$MUTATION/application-prod.yml"
sed -i 's/^[[:space:]]*bootstrap-enabled:/demo-catalog.bootstrap-enabled:/' \
  "$MUTATION/application.yml"
sed -i 's/${DEMO_CATALOG_BOOTSTRAP_ENABLED:false}/false/' "$MUTATION/application.yml"
make_jar_dir "$MUTATION" "$TMP/flat-unbound.jar"
expect_failure flat-unbound "$BUILD" --source "$MUTATION" --jar "$TMP/flat-unbound.jar" \
  --image-digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --image-id sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --platform linux/amd64 --source-sha "$INTRO" --tree-id "$TREE" --version 1.2.0 \
  --phase candidate --output "$TMP/reject.json"

echo "bootstrap default proof fixtures passed"
