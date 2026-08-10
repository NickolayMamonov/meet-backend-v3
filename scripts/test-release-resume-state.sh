#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VERIFY=$SCRIPT_DIR/verify-release-resume-state.sh
FIXTURES=$SCRIPT_DIR/fixtures/release-resume
VALID=$FIXTURES/valid
WORK_DIR=$(mktemp -d)
trap 'rm -r "$WORK_DIR"' EXIT HUP INT TERM

MUTATION_LOG=$WORK_DIR/mutations.log
export MUTATION_LOG
: > "$MUTATION_LOG"
mkdir "$WORK_DIR/bin"
for command_name in gh docker; do
  {
    echo '#!/bin/sh'
    echo 'printf "%s %s\n" "$(basename "$0")" "$*" >> "$MUTATION_LOG"'
    echo 'exit 99'
  } > "$WORK_DIR/bin/$command_name"
  chmod +x "$WORK_DIR/bin/$command_name"
done
PATH=$WORK_DIR/bin:$PATH
export PATH

RELEASE_ID=367640510
REPOSITORY=NickolayMamonov/meet-backend-v3
VERSION=1.0.1
TAG=v1.0.1
SOURCE_SHA=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
TARGET=$SOURCE_SHA
IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3

if grep -Eq \
  'gh release (upload|edit)|docker (push|tag)|imagetools create|(^|[[:space:]])repair([[:space:]]|$)|gh api .*--method' \
  "$VERIFY"; then
  echo "verifier contains a forbidden remote mutation command" >&2
  exit 1
fi

verify_fixture() {
  fixture=$1
  expected_target=${2:-$TARGET}
  "$VERIFY" "$RELEASE_ID" \
    --repository "$REPOSITORY" \
    --version "$VERSION" \
    --tag "$TAG" \
    --source-sha "$SOURCE_SHA" \
    --target "$expected_target" \
    --image "$IMAGE" \
    --fixture "$1"
}

update_json() {
  filter=$1
  file=$2
  jq "$filter" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

refresh_checksums() {
  fixture=$1
  (
    cd "$fixture/assets"
    checksum_file=104
    sha256sum 101 | awk '{print $1 "  release-manifest.json"}' > "$checksum_file"
    sha256sum 102 | awk '{print $1 "  image-index.json"}' >> "$checksum_file"
    sha256sum 103 | awk '{print $1 "  image-inspect.txt"}' >> "$checksum_file"
  )
}

make_case() {
  case_name=$1
  fixture=$WORK_DIR/$case_name
  cp -R "$VALID" "$fixture"
  mutation=$(jq -r '.mutation' "$FIXTURES/cases/$case_name.json")
  [ "$mutation" = "$case_name" ]
  case "$mutation" in
    metadata-only)
      update_json '.assets = []' "$fixture/release.json"
      ;;
    corrupt-asset)
      echo corrupt >> "$fixture/assets/102"
      ;;
    missing-asset)
      rm "$fixture/assets/103"
      ;;
    extra-asset)
      update_json '.assets += [{"id":105,"name":"unexpected.txt"}]' "$fixture/release.json"
      echo unexpected > "$fixture/assets/105"
      ;;
    path-traversal)
      printf '%s\n' \
        'c349aa352d587bb8177cef8e5dd38312788d6adebd4d003af8916017ad3f5017  ../release-manifest.json' \
        '86d6f96699e69bc504c16d8f4c6ce71e17cfb7fda491ffbe0603be7920cfc8ff  image-index.json' \
        '478d29afa9770621918ccc0a8c0e404d294da80d36a2ca8a892e2741ac177d36  image-inspect.txt' \
        > "$fixture/assets/104"
      ;;
    wrong-descriptor)
      update_json '.target_commitish = "0000000000000000000000000000000000000000"' \
        "$fixture/release.json"
      ;;
    wrong-digest)
      update_json '.digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
        "$fixture/registry.json"
      ;;
    tag-divergent)
      update_json \
        '.exists = true | .targetSha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
        "$fixture/tag.json"
      ;;
    tag-present-valid)
      update_json \
        '.exists = true | .targetSha = "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc"' \
        "$fixture/tag.json"
      ;;
    empty-registry)
      update_json '.aliases = {}' "$fixture/registry.json"
      ;;
    partial-registry)
      update_json 'del(.aliases["1.0.1"])' "$fixture/registry.json"
      ;;
    divergent-registry)
      update_json '.aliases["1.0.1"] = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
        "$fixture/registry.json"
      ;;
    latest-registry)
      update_json '.latest = .digest' "$fixture/registry.json"
      ;;
    extra-registry)
      update_json \
        '.versions += [{"digest":"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","tags":[]}]' \
        "$fixture/registry.json"
      ;;
    alias-failure)
      update_json '.aliases = ["v1.0.1","1.0.1"]' "$fixture/assets/101"
      refresh_checksums "$fixture"
      ;;
    oci-failure)
      update_json '.ociEvidence.provenance = false' "$fixture/registry.json"
      ;;
    filesystem-failure)
      update_json '.identity.filesystem = false' "$fixture/registry.json"
      ;;
    readiness-failure)
      update_json '.identity.readiness = false' "$fixture/registry.json"
      ;;
    evidence-failure)
      update_json '.evidence = ["image-index.json"]' "$fixture/assets/101"
      refresh_checksums "$fixture"
      ;;
    attestation-failure)
      update_json '.verified = false' "$fixture/attestation.json"
      ;;
    independent-source-target)
      update_json \
        '.target_commitish = "ffffffffffffffffffffffffffffffffffffffff"' \
        "$fixture/release.json"
      ;;
    *)
      echo "unknown fixture mutation: $mutation" >&2
      exit 1
      ;;
  esac
  printf '%s\n' "$fixture"
}

valid_output=$(verify_fixture "$VALID")
[ "$valid_output" = "resume_admission=verified" ]
[ ! -s "$MUTATION_LOG" ]

tag_present_fixture=$(make_case tag-present-valid)
tag_present_output=$(verify_fixture "$tag_present_fixture")
[ "$tag_present_output" = "resume_admission=verified" ]
[ ! -s "$MUTATION_LOG" ]

generated_placeholder_fixture=$WORK_DIR/generated-placeholder
cp -R "$VALID" "$generated_placeholder_fixture"
jq '.tag_name = "untagged-d63e3a440e23d8d24858"' \
  "$generated_placeholder_fixture/release.json" \
  >"$generated_placeholder_fixture/release.json.tmp"
mv "$generated_placeholder_fixture/release.json.tmp" \
  "$generated_placeholder_fixture/release.json"
generated_output=$(dash "$VERIFY" "$RELEASE_ID" \
  --repository "$REPOSITORY" \
  --version "$VERSION" \
  --tag "$TAG" \
  --source-sha "$SOURCE_SHA" \
  --target "$TARGET" \
  --image "$IMAGE" \
  --observed-state generated_placeholder \
  --observed-tag untagged-d63e3a440e23d8d24858 \
  --fixture "$generated_placeholder_fixture")
[ "$generated_output" = "resume_admission=verified" ]
[ ! -s "$MUTATION_LOG" ]

failures=0
for case_file in "$FIXTURES"/cases/*.json; do
  case_name=$(basename "$case_file" .json)
  case "$case_name" in
    tag-present-valid) continue ;;
  esac
  fixture=$(make_case "$case_name")
  output_file=$WORK_DIR/$case_name.output
  if verify_fixture "$fixture" > "$output_file" 2>&1; then
    echo "expected rejection for $case_name" >&2
    exit 1
  fi
  if grep -Fq 'resume_admission=verified' "$output_file"; then
    echo "rejected case emitted verified admission: $case_name" >&2
    exit 1
  fi
  [ ! -s "$MUTATION_LOG" ] || {
    echo "fixture verification invoked a mutation-capable command for $case_name" >&2
    exit 1
  }
  failures=$((failures + 1))
done

[ "$failures" -eq 20 ]
echo "release resume verifier fixtures passed: 3 valid, $failures rejected, 0 mutation commands"
