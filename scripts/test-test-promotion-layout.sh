#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml
VERIFY=$ROOT_DIR/scripts/verify-test-promotion-layout.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-test-promotion-layout.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT HUP INT TERM

usage() {
  echo "usage: $0 [--oras-bin ABSOLUTE_EXECUTABLE]" >&2
  exit 2
}

ORAS_BIN=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --oras-bin)
      [ "$#" -eq 2 ] || usage
      ORAS_BIN=$2
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [ -n "$ORAS_BIN" ]; then
  case "$ORAS_BIN" in
    /*) ;;
    *) echo "--oras-bin must be an absolute executable path" >&2; exit 2 ;;
  esac
  [ -f "$ORAS_BIN" ] && [ -x "$ORAS_BIN" ] ||
    { echo "--oras-bin is not an executable file: $ORAS_BIN" >&2; exit 2; }
fi

[ -f "$WORKFLOW" ] && [ -f "$VERIFY" ] || exit 1
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "timeout is required" >&2; exit 1; }

REAL_PATH=$PATH
SOURCE_SHA=0123456789abcdef0123456789abcdef01234567
SOURCE_ALIAS=test-sha-$SOURCE_SHA
IMAGE=ghcr.io/example/meet-backend
blob_digest() {
  sha256sum -- "$1" | awk '{print "sha256:" $1}'
}

blob_size() {
  wc -c <"$1" | tr -d '[:space:]'
}

layout_root_digest() {
  jq -er '
    [.manifests[] |
      select(.mediaType == "application/vnd.oci.image.index.v1+json" and
        .platform == null and
        .annotations["vnd.docker.reference.type"] != "attestation-manifest") |
      .digest] |
    if length == 1 then .[0] else error("layout root is not unique") end
  ' "$1/index.json"
}

layout_platform_digest() {
  local layout=$1
  local root
  root=$(layout_root_digest "$layout")
  jq -er '
    [.manifests[] |
      select(.mediaType == "application/vnd.oci.image.manifest.v1+json" and
        .platform.os == "linux" and .platform.architecture == "amd64" and
        (.platform.variant? // "") == "") |
      .digest] |
    if length == 1 then .[0] else error("layout platform is not unique") end
  ' "$layout/blobs/sha256/${root#sha256:}"
}

layout_blob_names() {
  local layout=$1
  local blob
  for blob in "$layout"/blobs/sha256/*; do
    [ -f "$blob" ] || continue
    basename -- "$blob"
  done | sort
}

assert_blob_names_are_content_addressed() {
  local layout=$1
  local blob name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    blob="$layout/blobs/sha256/$name"
    [ "$(blob_digest "$blob")" = "sha256:$name" ] ||
      { echo "non-content-addressed blob: $blob" >&2; return 1; }
  done < <(layout_blob_names "$layout")
}

build_fixture() {
  local layout=$1
  local work=$2
  local config_digest platform_digest attestation_config_digest
  local attestation_digest root_digest
  mkdir -p "$layout/blobs/sha256" "$work"
  jq -cnS '{imageLayoutVersion:"1.0.0"}' >"$layout/oci-layout"

  jq -cnS --arg source "$SOURCE_SHA" --arg version 1.2.3 '{
    architecture:"amd64",
    config:{Labels:{
      "org.opencontainers.image.source":"https://github.com/NickolayMamonov/meet-backend-v3",
      "org.opencontainers.image.revision":$source,
      "org.opencontainers.image.version":$version
    }},
    created:"1970-01-01T00:00:00Z",
    history:[],
    os:"linux",
    rootfs:{type:"layers",diff_ids:[]}
  }' >"$work/platform-config.json"
  config_digest=$(blob_digest "$work/platform-config.json")
  cp -- "$work/platform-config.json" "$layout/blobs/sha256/${config_digest#sha256:}"

  jq -cnS \
    --arg config_digest "$config_digest" \
    --argjson config_size "$(blob_size "$work/platform-config.json")" \
    '{
      schemaVersion:2,
      mediaType:"application/vnd.oci.image.manifest.v1+json",
      config:{
        mediaType:"application/vnd.oci.image.config.v1+json",
        digest:$config_digest,
        size:$config_size
      },
      layers:[]
    }' >"$work/platform-manifest.json"
  platform_digest=$(blob_digest "$work/platform-manifest.json")
  cp -- "$work/platform-manifest.json" "$layout/blobs/sha256/${platform_digest#sha256:}"

  jq -cnS '{
    attestation:"fixture-attestation",
    predicateType:"https://example.invalid/fixture/predicate/v1",
    subject:"fixture"
  }' >"$work/attestation-config.json"
  attestation_config_digest=$(blob_digest "$work/attestation-config.json")
  cp -- "$work/attestation-config.json" "$layout/blobs/sha256/${attestation_config_digest#sha256:}"

  jq -cnS \
    --arg config_digest "$attestation_config_digest" \
    --argjson config_size "$(blob_size "$work/attestation-config.json")" \
    --arg subject_digest "$platform_digest" \
    --argjson subject_size "$(blob_size "$work/platform-manifest.json")" \
    '{
      schemaVersion:2,
      mediaType:"application/vnd.oci.image.manifest.v1+json",
      artifactType:"application/vnd.in-toto+json",
      config:{
        mediaType:"application/vnd.oci.artifact.config.v1+json",
        digest:$config_digest,
        size:$config_size
      },
      layers:[],
      subject:{
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        digest:$subject_digest,
        size:$subject_size
      },
      annotations:{
        "vnd.docker.reference.type":"attestation-manifest",
        "vnd.docker.reference.digest":$subject_digest
      }
    }' >"$work/attestation-manifest.json"
  attestation_digest=$(blob_digest "$work/attestation-manifest.json")
  cp -- "$work/attestation-manifest.json" "$layout/blobs/sha256/${attestation_digest#sha256:}"

  jq -cnS \
    --arg platform_digest "$platform_digest" \
    --argjson platform_size "$(blob_size "$work/platform-manifest.json")" \
    --arg attestation_digest "$attestation_digest" \
    --argjson attestation_size "$(blob_size "$work/attestation-manifest.json")" \
    '{
      schemaVersion:2,
      mediaType:"application/vnd.oci.image.index.v1+json",
      manifests:[
        {
          mediaType:"application/vnd.oci.image.manifest.v1+json",
          digest:$platform_digest,
          size:$platform_size,
          platform:{os:"linux",architecture:"amd64"}
        },
        {
          mediaType:"application/vnd.oci.image.manifest.v1+json",
          digest:$attestation_digest,
          size:$attestation_size,
          platform:{os:"unknown",architecture:"unknown"},
          annotations:{
            "vnd.docker.reference.type":"attestation-manifest",
            "vnd.docker.reference.digest":$platform_digest
          }
        }
      ]
    }' >"$work/root-index.json"
  root_digest=$(blob_digest "$work/root-index.json")
  cp -- "$work/root-index.json" "$layout/blobs/sha256/${root_digest#sha256:}"

  jq -cnS \
    --arg root_digest "$root_digest" \
    --argjson root_size "$(blob_size "$work/root-index.json")" \
    --arg alias "$SOURCE_ALIAS" \
    '{
      schemaVersion:2,
      manifests:[{
        mediaType:"application/vnd.oci.image.index.v1+json",
        digest:$root_digest,
        size:$root_size,
        annotations:{"org.opencontainers.image.ref.name":$alias}
      }]
    }' >"$layout/index.json"

  for file in "$layout"/blobs/sha256/*; do
    [ -f "$file" ] || continue
    digest=$(blob_digest "$file")
    [ -n "$digest" ] || return 1
  done
}

make_protected_state() {
  local output=$1
  local subjects=${2:-}
  jq -cnS --argjson subjects "${subjects:-[]}" '{
    schema:"meet-backend/test-promotion-protected-state/v1",
    protected:{subjectDigests:$subjects}
  }' >"$output"
}

extract_publish_fragment() {
  local output=$1
  local start_marker='            local_root_digest=$(jq -er'
  local end_marker='            oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"'
  local starts ends start end
  starts=$(grep -Fc -- "$start_marker" "$WORKFLOW")
  ends=$(grep -Fc -- "$end_marker" "$WORKFLOW")
  [ "$starts" -eq 1 ] && [ "$ends" -eq 1 ] ||
    { echo "publish fragment anchors are not unique" >&2; return 1; }
  start=$(grep -nF -- "$start_marker" "$WORKFLOW" | cut -d: -f1)
  end=$(grep -nF -- "$end_marker" "$WORKFLOW" | cut -d: -f1)
  [ "$start" -lt "$end" ] || { echo "publish fragment anchor order is invalid" >&2; return 1; }
  sed -n "${start},${end}p" "$WORKFLOW" | sed 's/^            //' >"$output"
  bash -n "$output"
  [ -s "$output" ]
}

make_sandbox_tools() {
  local sandbox=$1
  mkdir -p "$sandbox/scripts" "$sandbox/bin"
  cp -- "$VERIFY" "$sandbox/scripts/verify-test-promotion-layout.sh"
  cp -- "$ROOT_DIR/scripts/verify-test-promotion-publication.sh" \
    "$sandbox/scripts/verify-test-promotion-publication.sh"
  cp -- "$ROOT_DIR/scripts/record-test-promotion-registry-state.sh" \
    "$sandbox/scripts/record-test-promotion-registry-state.sh"
  chmod 755 "$sandbox/scripts/verify-test-promotion-layout.sh"
  chmod 755 "$sandbox/scripts/verify-test-promotion-publication.sh" \
    "$sandbox/scripts/record-test-promotion-registry-state.sh"
  cat >"$sandbox/scripts/verify-dev-promotion-source.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repository=
source_checkout=
source_sha=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) repository=$2; shift 2 ;;
    --source-checkout) source_checkout=$2; shift 2 ;;
    --source-sha) source_sha=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) echo "fixture source verifier: unexpected argument $1" >&2; exit 2 ;;
  esac
done
[ "$repository" = "$source_checkout" ] &&
  [ "$source_sha" = "${SOURCE_SHA:?}" ] &&
  [ "$output" = "${RUNNER_TEMP:?}/dev-promotion-source-publish.json" ] ||
  { echo "fixture source verifier: unexpected invocation" >&2; exit 1; }
printf '%s\n' source-verified >>"${ORAS_EVENTS:?}"
jq -cnS --arg source "$source_sha" --arg tree "${TREE_ID:?}" \
  --arg version "${VERSION:?}" '{
    schema:"meet-backend/dev-promotion-source/v1",
    sourceSha:$source, authoritySha:$source, remoteSha:$source,
    treeId:$tree, version:$version, clean:true, detached:true
  }' >"$output"
EOF
  chmod 755 "$sandbox/scripts/verify-dev-promotion-source.sh"
  cat >"$sandbox/bin/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

events=${ORAS_EVENTS:?}
layout=${ORAS_LAYOUT:?}
image=${IMAGE:?}
source_sha=${SOURCE_SHA:?}
source_alias="test-sha-$source_sha"
expected_ref="$image:$source_alias"
[ "$#" -eq 4 ] &&
  [ "$1" = cp ] &&
  [ "$2" = --from-oci-layout ] ||
  { echo "ORAS spy: argv prefix is not the production copy command" >&2; exit 1; }

root_digest=$(
  jq -er '
    [.manifests[] |
      select(.mediaType == "application/vnd.oci.image.index.v1+json" and
        .platform == null and
        .annotations["vnd.docker.reference.type"] != "attestation-manifest") |
      .digest] |
    if length == 1 then .[0] else error("spy root is not unique") end
  ' "$layout/index.json"
)
root_blob="$layout/blobs/sha256/${root_digest#sha256:}"
[ -f "$root_blob" ] &&
  [ "$(sha256sum "$root_blob" | awk '{print "sha256:" $1}')" = "$root_digest" ] ||
  { echo "ORAS spy: independently computed root digest is invalid" >&2; exit 1; }
source_alias=$(
  jq -er --arg digest "$root_digest" '
    [.manifests[] | select(.digest == $digest) |
      .annotations["org.opencontainers.image.ref.name"]] |
    if length == 1 then .[0] else error("spy source alias is not unique") end
  ' "$layout/index.json"
)
[ "$source_alias" = "test-sha-$source_sha" ] ||
  { echo "ORAS spy: source alias is not source-derived" >&2; exit 1; }
if [ "${3:-}" != "$layout@$root_digest" ]; then
  printf 'ORAS spy: expected source=%s actual source=%s\n' \
    "$layout@$root_digest" "${3:-<missing>}" >&2
  exit 1
fi
if [ "${4:-}" != "$expected_ref" ]; then
  printf 'ORAS spy: expected destination=%s actual destination=%s\n' \
    "$expected_ref" "${4:-<missing>}" >&2
  exit 1
fi
printf '%s\n' copy-accepted >>"$events"
EOF
  chmod 755 "$sandbox/bin/oras"
}

run_publish_fragment() {
  local layout=$1
  local protected=$2
  local sandbox=$3
  local fragment=$sandbox/publish-fragment.sh
  local status
  mkdir -p "$sandbox"
  : >"$sandbox/events"
  RUNNER_TEMP="$sandbox/runner-temp"
  mkdir -p "$RUNNER_TEMP"
  local proof=$RUNNER_TEMP/layout-proof.json
  cp -- "$protected" "$RUNNER_TEMP/protected-before.json"
  jq -n '[[]]' >"$RUNNER_TEMP/protected-package-versions.json"
  extract_publish_fragment "$fragment"
  make_sandbox_tools "$sandbox"
  local github_output=$sandbox/github-output
  local registry_state=$RUNNER_TEMP/test-promotion-registry-state.json
  : >"$github_output"
  bash "$sandbox/scripts/record-test-promotion-registry-state.sh" init \
    --file "$registry_state" --source "$SOURCE_SHA" \
    --run-id 35354750679 --run-attempt 2
  bash "$sandbox/scripts/record-test-promotion-registry-state.sh" classify \
    --file "$registry_state" --source "$SOURCE_SHA" \
    --run-id 35354750679 --run-attempt 2 --initial-state absent
  set +e
  (
    cd -- "$sandbox"
    env \
      PATH="$sandbox/bin:$REAL_PATH" \
      layout="$layout" \
      ref="$IMAGE:$SOURCE_ALIAS" \
      GITHUB_WORKSPACE="$sandbox" \
      SOURCE_SHA="$SOURCE_SHA" \
      TREE_ID=abcdefabcdefabcdefabcdefabcdefabcdefabcd \
      VERSION=1.2.3 \
      IMAGE="$IMAGE" \
      GITHUB_RUN_ID=35354750679 \
      GITHUB_RUN_ATTEMPT=2 \
      GITHUB_REPOSITORY=NickolayMamonov/meet-backend-v3 \
      GITHUB_OUTPUT="$github_output" \
      RUNNER_TEMP="$RUNNER_TEMP" \
      REGISTRY_STATE="$registry_state" \
      GH_TOKEN=fixture-token \
      ORAS_EVENTS="$sandbox/events" \
      ORAS_LAYOUT="$layout" \
      bash -e -u -o pipefail "$fragment" \
      >"$sandbox/stdout" 2>"$sandbox/stderr"
  )
  status=$?
  printf '%s\n' "$status" >"$sandbox/status"
  printf '%s\n' "$proof" >"$sandbox/proof-path"
  return "$status"
}

replace_root_blob() {
  local layout=$1
  local work=$2
  local new_file=$3
  local old_root new_root
  old_root=$(layout_root_digest "$layout")
  new_root=$(blob_digest "$new_file")
  cp -- "$new_file" "$layout/blobs/sha256/${new_root#sha256:}"
  rm -f -- "$layout/blobs/sha256/${old_root#sha256:}"
  jq -cS --arg old "$old_root" --arg new "$new_root" \
    --argjson size "$(blob_size "$new_file")" \
    '(.manifests[] | select(.digest == $old) | .digest) = $new |
     (.manifests[] | select(.digest == $new) | .size) = $size' \
    "$layout/index.json" >"$work/index.json"
  mv -f -- "$work/index.json" "$layout/index.json"
}

copy_root_with_mutation() {
  local layout=$1
  local work=$2
  local expression=$3
  local old_root
  old_root=$(layout_root_digest "$layout")
  jq -cS "$expression" "$layout/blobs/sha256/${old_root#sha256:}" \
    >"$work/mutated-root.json"
  replace_root_blob "$layout" "$work" "$work/mutated-root.json"
}

mutate_missing_root() {
  local layout=$1
  local work=$2
  local fake=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  jq -cS --arg fake "sha256:$fake" \
    '(.manifests[0].digest) = $fake' "$layout/index.json" >"$work/index.json"
  mv -f -- "$work/index.json" "$layout/index.json"
}

mutate_ambiguous_root() {
  local layout=$1
  local work=$2
  local root root_file second_file second_digest second_size
  root=$(layout_root_digest "$layout")
  root_file="$layout/blobs/sha256/${root#sha256:}"
  second_file="$work/second-root.json"
  jq -cS '.annotations={"fixture":"second-root"}' "$root_file" >"$second_file"
  second_digest=$(blob_digest "$second_file")
  second_size=$(blob_size "$second_file")
  cp -- "$second_file" "$layout/blobs/sha256/${second_digest#sha256:}"
  jq -cS --arg digest "$second_digest" --arg alias "$SOURCE_ALIAS-secondary" \
    --argjson size "$second_size" \
    '.manifests += [{
      mediaType:"application/vnd.oci.image.index.v1+json",
      digest:$digest,
      size:$size,
      annotations:{"org.opencontainers.image.ref.name":$alias}
    }]' "$layout/index.json" >"$work/index.json"
  mv -f -- "$work/index.json" "$layout/index.json"
}

mutate_corrupt_root() {
  local layout=$1
  local work=$2
  local root
  root=$(layout_root_digest "$layout")
  cp -- "$layout/blobs/sha256/${root#sha256:}" "$work/corrupt-root.json"
  printf '\n' >>"$work/corrupt-root.json"
  cp -- "$work/corrupt-root.json" "$layout/blobs/sha256/${root#sha256:}"
}

mutate_missing_platform() {
  local layout=$1
  local work=$2
  copy_root_with_mutation "$layout" "$work" \
    '.manifests = [.manifests[] | select(.platform.os != "linux" or .platform.architecture != "amd64")]'
}

mutate_ambiguous_platform() {
  local layout=$1
  local work=$2
  local platform platform_file duplicate_file duplicate_digest duplicate_size
  local root root_file
  platform=$(layout_platform_digest "$layout")
  platform_file="$layout/blobs/sha256/${platform#sha256:}"
  duplicate_file="$work/duplicate-platform.json"
  jq -cS '.annotations={"fixture":"duplicate-platform"}' "$platform_file" >"$duplicate_file"
  duplicate_digest=$(blob_digest "$duplicate_file")
  duplicate_size=$(blob_size "$duplicate_file")
  cp -- "$duplicate_file" "$layout/blobs/sha256/${duplicate_digest#sha256:}"
  root=$(layout_root_digest "$layout")
  root_file="$layout/blobs/sha256/${root#sha256:}"
  jq -cS --arg duplicate "$duplicate_digest" --argjson duplicate_size "$duplicate_size" \
    '.manifests += [{
      mediaType:"application/vnd.oci.image.manifest.v1+json",
      digest:$duplicate,
      size:$duplicate_size,
      platform:{os:"linux",architecture:"amd64"}
    }]' "$root_file" >"$work/mutated-root.json"
  replace_root_blob "$layout" "$work" "$work/mutated-root.json"
}

mutate_protected_root() {
  local layout=$1
  local protected=$2
  make_protected_state "$protected" "[\"$(layout_root_digest "$layout")\"]"
}

mutate_protected_platform() {
  local layout=$1
  local protected=$2
  make_protected_state "$protected" "[\"$(layout_platform_digest "$layout")\"]"
}

mutate_protected_referrer() {
  local layout=$1
  local protected=$2
  local root referrer
  root=$(layout_root_digest "$layout")
  referrer=$(jq -er '
    [.manifests[] |
      select(.annotations["vnd.docker.reference.type"] == "attestation-manifest") |
      .digest] |
    if length == 1 then .[0] else error("fixture referrer is not unique") end
  ' "$layout/blobs/sha256/${root#sha256:}")
  make_protected_state "$protected" "[\"$referrer\"]"
}

run_valid_and_negative_fixtures() {
  local base="$TMP/base-layout"
  local base_work="$TMP/base-work"
  local protected="$TMP/base-protected.json"
  local valid_sandbox="$TMP/valid"
  local status case_name case_layout case_work case_protected case_sandbox
  mkdir -p "$base_work"
  build_fixture "$base" "$base_work"
  assert_blob_names_are_content_addressed "$base"
  make_protected_state "$protected"

  set +e
  run_publish_fragment "$base" "$protected" "$valid_sandbox"
  status=$?
  set -e
  [ "$status" -eq 0 ] || {
    echo "valid publish fragment failed" >&2
    sed -n '1,160p' "$valid_sandbox/stderr" >&2
    return 1
  }
  [ "$(grep -Fc copy-accepted "$valid_sandbox/events")" -eq 1 ]
  [ "$(grep -nFx source-verified "$valid_sandbox/events" | cut -d: -f1)" -lt \
    "$(grep -nFx copy-accepted "$valid_sandbox/events" | cut -d: -f1)" ]
  jq -e --arg root "$(layout_root_digest "$base")" \
    --arg platform "$(layout_platform_digest "$base")" \
    '.protectedSubjectsExcluded == true and .rootDigest == $root and .platformDigest == $platform' \
    "$valid_sandbox/runner-temp/layout-proof.json" >/dev/null
  jq -e --arg root "$(layout_root_digest "$base")" \
    --arg platform "$(layout_platform_digest "$base")" \
    '.rootDigest == $root and .platformDigest == $platform' \
    "$valid_sandbox/runner-temp/test-promotion-publication-35354750679-2.json" >/dev/null
  jq -e '
    .initialAliasState == "absent" and
    .registryPublication == "confirmed" and
    .attestationWrite == "notStarted"
  ' "$valid_sandbox/runner-temp/test-promotion-registry-state.json" >/dev/null
  for alias_state in reusable partial rejected; do
    state_file="$TMP/$alias_state-registry-state.json"
    bash "$ROOT_DIR/scripts/record-test-promotion-registry-state.sh" init \
      --file "$state_file" --source "$SOURCE_SHA" \
      --run-id 35354750679 --run-attempt 2
    bash "$ROOT_DIR/scripts/record-test-promotion-registry-state.sh" classify \
      --file "$state_file" --source "$SOURCE_SHA" \
      --run-id 35354750679 --run-attempt 2 --initial-state "$alias_state"
    jq -e --arg state "$alias_state" \
      '.initialAliasState == $state and
       .registryPublication == "notStarted" and
       .attestationWrite == "notStarted"' "$state_file" >/dev/null
  done
  unknown_state="$TMP/unknown-registry-state.json"
  bash "$ROOT_DIR/scripts/record-test-promotion-registry-state.sh" init \
    --file "$unknown_state" --source "$SOURCE_SHA" \
    --run-id 35354750679 --run-attempt 2
  jq -e '
    .initialAliasState == "unknown" and
    .registryPublication == "notStarted" and
    .attestationWrite == "notStarted"
  ' "$unknown_state" >/dev/null
  printf 'local fixture admitted source_sha=%s alias=%s root=%s platform=%s\n' \
    "$SOURCE_SHA" "$SOURCE_ALIAS" "$(layout_root_digest "$base")" "$(layout_platform_digest "$base")"

  for case_name in \
    missing-root \
    ambiguous-root \
    corrupt-root \
    missing-platform \
    ambiguous-platform \
    protected-root \
    protected-platform \
    protected-referrer; do
    case_layout="$TMP/$case_name-layout"
    case_work="$TMP/$case_name-work"
    case_protected="$TMP/$case_name-protected.json"
    case_sandbox="$TMP/$case_name"
    cp -a -- "$base" "$case_layout"
    mkdir -p "$case_work"
    make_protected_state "$case_protected"
    case "$case_name" in
      missing-root) mutate_missing_root "$case_layout" "$case_work" ;;
      ambiguous-root) mutate_ambiguous_root "$case_layout" "$case_work" ;;
      corrupt-root) mutate_corrupt_root "$case_layout" "$case_work" ;;
      missing-platform) mutate_missing_platform "$case_layout" "$case_work" ;;
      ambiguous-platform) mutate_ambiguous_platform "$case_layout" "$case_work" ;;
      protected-root) mutate_protected_root "$case_layout" "$case_protected" ;;
      protected-platform) mutate_protected_platform "$case_layout" "$case_protected" ;;
      protected-referrer) mutate_protected_referrer "$case_layout" "$case_protected" ;;
    esac
    set +e
    run_publish_fragment "$case_layout" "$case_protected" "$case_sandbox"
    status=$?
    set -e
    [ "$status" -ne 0 ] || {
      echo "$case_name unexpectedly passed" >&2
      return 1
    }
    ! grep -Fq copy-accepted "$case_sandbox/events"
    [ ! -e "$case_sandbox/runner-temp/layout-proof.json" ]
    echo "$case_name rejected before accepted copy"
  done
}

compare_layout_graph() {
  local source=$1
  local destination=$2
  local name
  assert_blob_names_are_content_addressed "$source"
  assert_blob_names_are_content_addressed "$destination"
  diff -u <(layout_blob_names "$source") <(layout_blob_names "$destination") >/dev/null ||
    { echo "ORAS output graph digest set differs from fixture input" >&2; return 1; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    cmp -- "$source/blobs/sha256/$name" "$destination/blobs/sha256/$name" ||
      { echo "ORAS output graph blob differs: $name" >&2; return 1; }
  done < <(layout_blob_names "$source")
}

assert_oras_output() {
  local source=$1
  local destination=$2
  local expected_root expected_platform output_root output_platform
  expected_root=$(layout_root_digest "$source")
  expected_platform=$(layout_platform_digest "$source")
  output_root=$(
    jq -er --arg alias "$SOURCE_ALIAS" '
      [.manifests[] |
        select(.annotations["org.opencontainers.image.ref.name"] == $alias) |
        .digest] |
      if length == 1 then .[0] else error("ORAS output alias is not unique") end
    ' "$destination/index.json"
  )
  output_platform=$(layout_platform_digest "$destination")
  [ "$output_root" = "$expected_root" ] || {
    echo "ORAS output root differs from fixture input" >&2
    return 1
  }
  [ "$output_platform" = "$expected_platform" ] || {
    echo "ORAS output platform differs from fixture input" >&2
    return 1
  }
  compare_layout_graph "$source" "$destination"
}

run_real_oras_fixture() {
  local base="$TMP/base-layout"
  local base_work="$TMP/real-base-work"
  local bare_dest="$TMP/real-bare-destination"
  local missing_dest="$TMP/real-missing-destination"
  local output="$TMP/real-output"
  local root status
  mkdir -p "$base_work"
  build_fixture "$base" "$base_work"
  root=$(layout_root_digest "$base")

  set +e
  timeout 60s "$ORAS_BIN" cp --from-oci-layout "$base" \
    --to-oci-layout "$bare_dest:$SOURCE_ALIAS" >"$TMP/real-bare.stdout" 2>"$TMP/real-bare.stderr"
  status=$?
  set -e
  [ "$status" -ne 0 ] || { echo "ORAS accepted an unselected bare layout source" >&2; return 1; }
  grep -Fqi 'no tag or digest specified' "$TMP/real-bare.stderr" ||
    { echo "ORAS bare-source rejection did not identify the missing selector" >&2; return 1; }

  timeout 60s "$ORAS_BIN" cp --from-oci-layout "$base@$root" \
    --to-oci-layout "$output:$SOURCE_ALIAS"
  assert_oras_output "$base" "$output"

  set +e
  timeout 60s "$ORAS_BIN" cp --from-oci-layout \
    "$base@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    --to-oci-layout "$missing_dest:$SOURCE_ALIAS" >"$TMP/real-missing.stdout" \
    2>"$TMP/real-missing.stderr"
  status=$?
  set -e
  [ "$status" -ne 0 ] || { echo "ORAS accepted a nonexistent source digest" >&2; return 1; }
  if [ -f "$missing_dest/index.json" ]; then
    ! jq -e --arg alias "$SOURCE_ALIAS" \
      'any(.manifests[]; .annotations["org.opencontainers.image.ref.name"] == $alias)' \
      "$missing_dest/index.json" >/dev/null
  fi
}

run_valid_and_negative_fixtures
if [ -n "$ORAS_BIN" ]; then
  run_real_oras_fixture
  echo "test promotion OCI layout fixtures passed with verified ORAS: $ORAS_BIN"
else
  echo "test promotion OCI layout fixtures passed (offline)"
fi
