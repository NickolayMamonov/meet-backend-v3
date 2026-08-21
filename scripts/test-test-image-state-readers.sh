#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
COLLECT=$ROOT_DIR/scripts/collect-test-promotion-protected-state.sh
READ=$ROOT_DIR/scripts/read-test-image-state.sh
ADMIT=$ROOT_DIR/scripts/admit-test-image.sh
TMP=$(mktemp -d)
MAIN_BASHPID=$BASHPID
cleanup_tmp() {
  local status=$?
  trap - EXIT HUP INT TERM
  if [ "$BASHPID" = "$MAIN_BASHPID" ]; then
    rm -r -- "$TMP"
  fi
  exit "$status"
}
trap cleanup_tmp EXIT HUP INT TERM

fail() { echo "test image state reader fixture failed: $*" >&2; exit 1; }
expect_failure() {
  local name=$1
  shift
  if "$@" >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"; then
    fail "expected failure was accepted: $name"
  fi
  [ -s "$TMP/$name.stderr" ] || fail "failure omitted stderr: $name"
}

SOURCE=0123456789abcdef0123456789abcdef01234567
VERSION=1.2.3
REPOSITORY=NickolayMamonov/meet-backend-v3
IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3
ALIAS=test-sha-$SOURCE
PROVENANCE_LAYER=sha256:3333333333333333333333333333333333333333333333333333333333333333
SBOM_LAYER=sha256:5555555555555555555555555555555555555555555555555555555555555555
REAL_PROVENANCE_LAYER=sha256:7777777777777777777777777777777777777777777777777777777777777777
REAL_SBOM_LAYER=sha256:8888888888888888888888888888888888888888888888888888888888888888
DATA=$TMP/data
BIN=$TMP/bin
mkdir "$DATA" "$BIN"

digest_of() { printf 'sha256:%s\n' "$(sha256sum "$1" | awk '{print $1}')"; }
size_of() { wc -c <"$1" | tr -d ' '; }

jq -cS -n \
  --arg source "$SOURCE" --arg version "$VERSION" '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    config:{
      mediaType:"application/vnd.oci.image.config.v1+json",
      digest:"sha256:1111111111111111111111111111111111111111111111111111111111111111",
      size:2
    },
    layers:[],
    fixtureLabels:{
      "org.opencontainers.image.source":
        "https://github.com/NickolayMamonov/meet-backend-v3",
      "org.opencontainers.image.revision":$source,
      "org.opencontainers.image.version":$version
    }
  }
' >"$DATA/platform.json"
PLATFORM=$(digest_of "$DATA/platform.json")
PLATFORM_SIZE=$(size_of "$DATA/platform.json")

jq -cS -n --arg platform "$PLATFORM" --argjson size "$PLATFORM_SIZE" '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    artifactType:"application/vnd.in-toto+json",
    subject:{
      mediaType:"application/vnd.oci.image.manifest.v1+json",
      digest:$platform,size:$size
    },
    config:{
      mediaType:"application/vnd.oci.empty.v1+json",
      digest:"sha256:2222222222222222222222222222222222222222222222222222222222222222",
      size:2
    },
    layers:[{
      mediaType:"application/vnd.in-toto+json",
      digest:"sha256:3333333333333333333333333333333333333333333333333333333333333333",
      size:17,
      annotations:{
        "in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"
      }
    }]
  }
' >"$DATA/provenance.json"
PROVENANCE=$(digest_of "$DATA/provenance.json")
PROVENANCE_SIZE=$(size_of "$DATA/provenance.json")

jq -cS -n --arg platform "$PLATFORM" --argjson size "$PLATFORM_SIZE" '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    artifactType:"application/spdx+json",
    subject:{
      mediaType:"application/vnd.oci.image.manifest.v1+json",
      digest:$platform,size:$size
    },
    config:{
      mediaType:"application/vnd.oci.empty.v1+json",
      digest:"sha256:4444444444444444444444444444444444444444444444444444444444444444",
      size:2
    },
    layers:[{
      mediaType:"application/spdx+json",
      digest:"sha256:5555555555555555555555555555555555555555555555555555555555555555",
      size:19,
      annotations:{
        "in-toto.io/predicate-type":"https://spdx.dev/Document"
      }
    }]
  }
' >"$DATA/sbom.json"
SBOM=$(digest_of "$DATA/sbom.json")
SBOM_SIZE=$(size_of "$DATA/sbom.json")

jq -cS -n \
  --arg platform "$PLATFORM" --argjson platformSize "$PLATFORM_SIZE" \
  --arg provenance "$PROVENANCE" --argjson provenanceSize "$PROVENANCE_SIZE" \
  --arg sbom "$SBOM" --argjson sbomSize "$SBOM_SIZE" '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.index.v1+json",
    manifests:[
      {
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        digest:$platform,size:$platformSize,
        platform:{os:"linux",architecture:"amd64"}
      },
      {
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        digest:$provenance,size:$provenanceSize,
        annotations:{
          "vnd.docker.reference.type":"attestation-manifest",
          "vnd.docker.reference.digest":$platform
        },
        platform:{os:"unknown",architecture:"unknown"}
      },
      {
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        digest:$sbom,size:$sbomSize,
        annotations:{
          "vnd.docker.reference.type":"attestation-manifest",
          "vnd.docker.reference.digest":$platform
        },
        platform:{os:"unknown",architecture:"unknown"}
      }
    ]
  }
' >"$DATA/root.json"
ROOT=$(digest_of "$DATA/root.json")

jq -cS -n --arg platform "$PLATFORM" --argjson size "$PLATFORM_SIZE" '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    artifactType:"application/vnd.docker.attestation.manifest.v1+json",
    config:{
      mediaType:"application/vnd.oci.empty.v1+json",
      digest:"sha256:6666666666666666666666666666666666666666666666666666666666666666",
      size:2
    },
    layers:[
      {
        mediaType:"application/vnd.in-toto+json",
        digest:"sha256:7777777777777777777777777777777777777777777777777777777777777777",
        size:23,
        annotations:{
          "in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"
        }
      },
      {
        mediaType:"application/vnd.in-toto+json",
        digest:"sha256:8888888888888888888888888888888888888888888888888888888888888888",
        size:29,
        annotations:{
          "in-toto.io/predicate-type":"https://spdx.dev/Document"
        }
      }
    ]
  }
' >"$DATA/real-attestation.json"
REAL_ATTESTATION=$(digest_of "$DATA/real-attestation.json")
REAL_ATTESTATION_SIZE=$(size_of "$DATA/real-attestation.json")
jq -cS -n \
  --arg platform "$PLATFORM" --argjson platformSize "$PLATFORM_SIZE" \
  --arg attestation "$REAL_ATTESTATION" \
  --argjson attestationSize "$REAL_ATTESTATION_SIZE" '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.index.v1+json",
    manifests:[
      {
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        digest:$platform,size:$platformSize,
        platform:{os:"linux",architecture:"amd64"}
      },
      {
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        digest:$attestation,size:$attestationSize,
        annotations:{
          "vnd.docker.reference.type":"attestation-manifest",
          "vnd.docker.reference.digest":$platform
        },
        platform:{os:"unknown",architecture:"unknown"}
      }
    ]
  }
' >"$DATA/real-root.json"
REAL_ROOT=$(digest_of "$DATA/real-root.json")

jq -cS -n --arg source "$SOURCE" '
  [[{
    id:371012814,
    tag_name:"v1.2.3",
    target_commitish:$source,
    draft:false,immutable:true,protected:true,prerelease:false,
    published_at:"2026-08-12T01:00:00Z",
    assets:[]
  }]]
' >"$DATA/releases.json"
jq -cS -n \
  --arg root "$ROOT" --arg platform "$PLATFORM" \
  --arg provenance "$PROVENANCE" --arg sbom "$SBOM" \
  --arg source "$SOURCE" --arg alias "$ALIAS" '
  [[
    {id:1,name:$root,metadata:{container:{tags:[
      "v1.2.3","1.2.3",("sha-"+$source),$alias
    ]}}},
    {id:2,name:$platform,metadata:{container:{tags:[]}}},
    {id:3,name:$provenance,metadata:{container:{tags:[]}}},
    {id:4,name:$sbom,metadata:{container:{tags:[]}}}
  ]]
' >"$DATA/packages.json"
jq -cS -n --arg root "$ROOT" --arg source "$SOURCE" '
  [{
    attestation:{bundle:{fixture:"verified-bundle"}},
    verificationResult:{
      statement:{
        predicateType:"https://slsa.dev/provenance/v1",
        subject:[{name:"image-index.json",digest:{sha256:($root|sub("^sha256:";""))}}]
      },
      signature:{certificate:{
        sourceRepositoryURI:
          "https://github.com/NickolayMamonov/meet-backend-v3",
        sourceRepositoryDigest:$source,
        sourceRepositoryRef:"refs/heads/dev",
        buildSignerURI:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/build.yml@refs/heads/dev",
        subjectAlternativeName:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/build.yml@refs/heads/dev"
      }}
    }
  }]
' >"$DATA/verified.json"
jq '.[] .verificationResult.signature.certificate.sourceRepositoryDigest =
  "ffffffffffffffffffffffffffffffffffffffff"' \
  "$DATA/verified.json" >"$DATA/verified-mismatch.json"
jq -cS '
  .manifests[0].platform.variant = "v8"
' "$DATA/root.json" >"$DATA/root-wrong-platform.json"

jq -cS --arg provenance "$PROVENANCE" '
  .manifests |= map(
    if .digest == $provenance then .size += 1 else . end
  )
' "$DATA/root.json" >"$DATA/root-wrong-size.json"
ROOT_WRONG_SIZE=$(digest_of "$DATA/root-wrong-size.json")
jq -cS --arg provenance "$PROVENANCE" '
  .manifests |= map(
    if .digest == $provenance
    then .mediaType = "application/vnd.oci.image.index.v1+json"
    else . end
  )
' "$DATA/root.json" >"$DATA/root-wrong-media.json"
ROOT_WRONG_MEDIA=$(digest_of "$DATA/root-wrong-media.json")

jq -cS 'del(.artifactType)' \
  "$DATA/provenance.json" >"$DATA/provenance-missing-artifact.json"
PROVENANCE_MISSING_ARTIFACT=$(digest_of "$DATA/provenance-missing-artifact.json")
PROVENANCE_MISSING_ARTIFACT_SIZE=$(size_of "$DATA/provenance-missing-artifact.json")
jq -cS --arg old "$PROVENANCE" --arg replacement "$PROVENANCE_MISSING_ARTIFACT" \
  --argjson size "$PROVENANCE_MISSING_ARTIFACT_SIZE" '
  .manifests |= map(
    if .digest == $old then .digest = $replacement | .size = $size else . end
  )
' "$DATA/root.json" >"$DATA/root-missing-artifact.json"
ROOT_MISSING_ARTIFACT=$(digest_of "$DATA/root-missing-artifact.json")

jq -cS 'del(.layers[0].annotations["in-toto.io/predicate-type"])' \
  "$DATA/provenance.json" >"$DATA/provenance-missing-predicate.json"
PROVENANCE_MISSING_PREDICATE=$(digest_of "$DATA/provenance-missing-predicate.json")
PROVENANCE_MISSING_PREDICATE_SIZE=$(size_of "$DATA/provenance-missing-predicate.json")
jq -cS --arg old "$PROVENANCE" --arg replacement "$PROVENANCE_MISSING_PREDICATE" \
  --argjson size "$PROVENANCE_MISSING_PREDICATE_SIZE" '
  .manifests |= map(
    if .digest == $old then .digest = $replacement | .size = $size else . end
  )
' "$DATA/root.json" >"$DATA/root-missing-predicate.json"
ROOT_MISSING_PREDICATE=$(digest_of "$DATA/root-missing-predicate.json")

jq -cS --arg foreign "$SBOM" '.subject.digest = $foreign' \
  "$DATA/provenance.json" >"$DATA/provenance-subject-disagreement.json"
PROVENANCE_SUBJECT_DISAGREEMENT=$(
  digest_of "$DATA/provenance-subject-disagreement.json"
)
PROVENANCE_SUBJECT_DISAGREEMENT_SIZE=$(
  size_of "$DATA/provenance-subject-disagreement.json"
)
jq -cS --arg old "$PROVENANCE" \
  --arg replacement "$PROVENANCE_SUBJECT_DISAGREEMENT" \
  --argjson size "$PROVENANCE_SUBJECT_DISAGREEMENT_SIZE" '
  .manifests |= map(
    if .digest == $old then .digest = $replacement | .size = $size else . end
  )
' "$DATA/root.json" >"$DATA/root-subject-disagreement.json"
ROOT_SUBJECT_DISAGREEMENT=$(digest_of "$DATA/root-subject-disagreement.json")
jq -cS -n --arg source "$SOURCE" '
  {object:{type:"commit",sha:$source}}
' >"$DATA/tag-ref.json"
jq -cS -n --arg source "$SOURCE" --arg version "$VERSION" '
  {
    "org.opencontainers.image.source":
      "https://github.com/NickolayMamonov/meet-backend-v3",
    "org.opencontainers.image.revision":$source,
    "org.opencontainers.image.version":$version
  }
' >"$DATA/labels.json"

export FIXTURE_DATA=$DATA ROOT PLATFORM PROVENANCE SBOM SOURCE VERSION ALIAS
export REAL_ROOT REAL_ATTESTATION ROOT_WRONG_SIZE ROOT_WRONG_MEDIA
export ROOT_MISSING_ARTIFACT PROVENANCE_MISSING_ARTIFACT
export ROOT_MISSING_PREDICATE PROVENANCE_MISSING_PREDICATE
export ROOT_SUBJECT_DISAGREEMENT PROVENANCE_SUBJECT_DISAGREEMENT
cp "$DATA/platform.json" "$DATA/${PLATFORM#sha256:}.json"
cp "$DATA/provenance.json" "$DATA/${PROVENANCE#sha256:}.json"
cp "$DATA/sbom.json" "$DATA/${SBOM#sha256:}.json"
cp "$DATA/root.json" "$DATA/${ROOT#sha256:}.json"
cp "$DATA/real-attestation.json" "$DATA/${REAL_ATTESTATION#sha256:}.json"
cp "$DATA/real-root.json" "$DATA/${REAL_ROOT#sha256:}.json"
cp "$DATA/root-wrong-size.json" "$DATA/${ROOT_WRONG_SIZE#sha256:}.json"
cp "$DATA/root-wrong-media.json" "$DATA/${ROOT_WRONG_MEDIA#sha256:}.json"
cp "$DATA/provenance-missing-artifact.json" \
  "$DATA/${PROVENANCE_MISSING_ARTIFACT#sha256:}.json"
cp "$DATA/root-missing-artifact.json" \
  "$DATA/${ROOT_MISSING_ARTIFACT#sha256:}.json"
cp "$DATA/provenance-missing-predicate.json" \
  "$DATA/${PROVENANCE_MISSING_PREDICATE#sha256:}.json"
cp "$DATA/root-missing-predicate.json" \
  "$DATA/${ROOT_MISSING_PREDICATE#sha256:}.json"
cp "$DATA/provenance-subject-disagreement.json" \
  "$DATA/${PROVENANCE_SUBJECT_DISAGREEMENT#sha256:}.json"
cp "$DATA/root-subject-disagreement.json" \
  "$DATA/${ROOT_SUBJECT_DISAGREEMENT#sha256:}.json"

cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${FAKE_SCENARIO:-valid}
if [ "$1" = buildx ] && [ "$2" = imagetools ] &&
   [ "$3" = inspect ] && [ "$4" = --raw ]; then
  reference=$5
  if [[ "$reference" == *":$ALIAS" ]]; then
    case "$scenario" in
      inspect-fail|inspect-existing|inventory-error) exit 44 ;;
      malformed-root) printf '{"schemaVersion":2}\n'; exit 0 ;;
      wrong-platform) cat "$FIXTURE_DATA/root-wrong-platform.json"; exit 0 ;;
      real-shape) cat "$FIXTURE_DATA/real-root.json"; exit 0 ;;
      *) cat "$FIXTURE_DATA/root.json"; exit 0 ;;
    esac
  fi
  digest=${reference##*@}
  if [ "$scenario" = child-read-fail ] && [ "$digest" = "$PROVENANCE" ]; then
    exit 45
  fi
  if [ "$scenario" = child-byte-mismatch ] && [ "$digest" = "$PLATFORM" ]; then
    cat "$FIXTURE_DATA/${digest#sha256:}.json"
    printf ' '
    exit 0
  fi
  cat "$FIXTURE_DATA/${digest#sha256:}.json"
  exit 0
fi
if [ "$1" = pull ]; then
  [ "$scenario" != pull-fail ] || exit 46
  exit 0
fi
if [ "$1" = image ] && [ "$2" = inspect ]; then
  cat "$FIXTURE_DATA/labels.json"
  exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 98
EOF

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${FAKE_SCENARIO:-valid}
if [ "$1" = api ]; then
  endpoint=${!#}
  case "$endpoint" in
    repos/*/releases\?*)
      cat "$FIXTURE_DATA/releases.json"
      ;;
    users/*/packages/container/*/versions\?*)
      case "$scenario" in
        inventory-error) exit 47 ;;
        inspect-fail) printf '[[]]\n' ;;
        inspect-existing)
          jq -cn --arg root "$ROOT" --arg alias "$ALIAS" \
            '[[{id:1,name:$root,metadata:{container:{tags:[$alias]}}}]]'
          ;;
        real-shape)
          jq -cn --arg root "$REAL_ROOT" --arg platform "$PLATFORM" \
            --arg attestation "$REAL_ATTESTATION" --arg source "$SOURCE" \
            --arg alias "$ALIAS" '
            [[
              {id:1,name:$root,metadata:{container:{tags:[
                "v1.2.3","1.2.3",("sha-"+$source),$alias
              ]}}},
              {id:2,name:$platform,metadata:{container:{tags:[]}}},
              {id:3,name:$attestation,metadata:{container:{tags:[]}}}
            ]]
          '
          ;;
        collector-wrong-size|collector-wrong-media|\
        collector-missing-artifact|collector-missing-predicate|\
        collector-subject-disagreement)
          root=$ROOT
          provenance=$PROVENANCE
          case "$scenario" in
            collector-wrong-size) root=$ROOT_WRONG_SIZE ;;
            collector-wrong-media) root=$ROOT_WRONG_MEDIA ;;
            collector-missing-artifact)
              root=$ROOT_MISSING_ARTIFACT
              provenance=$PROVENANCE_MISSING_ARTIFACT
              ;;
            collector-missing-predicate)
              root=$ROOT_MISSING_PREDICATE
              provenance=$PROVENANCE_MISSING_PREDICATE
              ;;
            collector-subject-disagreement)
              root=$ROOT_SUBJECT_DISAGREEMENT
              provenance=$PROVENANCE_SUBJECT_DISAGREEMENT
              ;;
          esac
          jq -cn --arg root "$root" --arg platform "$PLATFORM" \
            --arg provenance "$provenance" --arg sbom "$SBOM" \
            --arg source "$SOURCE" --arg alias "$ALIAS" '
            [[
              {id:1,name:$root,metadata:{container:{tags:[
                "v1.2.3","1.2.3",("sha-"+$source),$alias
              ]}}},
              {id:2,name:$platform,metadata:{container:{tags:[]}}},
              {id:3,name:$provenance,metadata:{container:{tags:[]}}},
              {id:4,name:$sbom,metadata:{container:{tags:[]}}}
            ]]
          '
          ;;
        *) cat "$FIXTURE_DATA/packages.json" ;;
      esac
      ;;
    repos/*/git/ref/tags/*)
      cat "$FIXTURE_DATA/tag-ref.json"
      ;;
    *)
      echo "unexpected gh api endpoint: $endpoint" >&2
      exit 97
      ;;
  esac
  exit 0
fi
if [ "$1" = attestation ] && [ "$2" = verify ]; then
  if [ "$scenario" = attestation-mismatch ]; then
    cat "$FIXTURE_DATA/verified-mismatch.json"
  else
    verified_root=$ROOT
    case "$scenario" in
      real-shape) verified_root=$REAL_ROOT ;;
      collector-wrong-size) verified_root=$ROOT_WRONG_SIZE ;;
      collector-wrong-media) verified_root=$ROOT_WRONG_MEDIA ;;
      collector-missing-artifact) verified_root=$ROOT_MISSING_ARTIFACT ;;
      collector-missing-predicate) verified_root=$ROOT_MISSING_PREDICATE ;;
      collector-subject-disagreement)
        verified_root=$ROOT_SUBJECT_DISAGREEMENT
        ;;
    esac
    jq -cS --arg root "${verified_root#sha256:}" '
      .[0].verificationResult.statement.subject[0].digest.sha256 = $root
    ' "$FIXTURE_DATA/verified.json"
  fi
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 96
EOF
chmod +x "$BIN/docker" "$BIN/gh"

run_read() {
  env PATH="$BIN:$PATH" GH_TOKEN=fixture \
    GITHUB_REPOSITORY="$REPOSITORY" FAKE_SCENARIO="${1:-valid}" \
    bash "$READ" "$IMAGE" "$ALIAS" "$SOURCE" "$VERSION"
}
run_collect() {
  local scenario=$1 output=$2
  env PATH="$BIN:$PATH" GH_TOKEN=fixture FAKE_SCENARIO="$scenario" \
    bash "$COLLECT" --repository "$REPOSITORY" --image "$IMAGE" \
      --candidate-alias "$ALIAS" --output "$output"
}

bash -n "$COLLECT"
bash -n "$READ"

run_read valid >"$TMP/read-valid.json"
jq -e \
  --arg root "$ROOT" --arg platform "$PLATFORM" \
  --arg provenance "$PROVENANCE_LAYER" --arg sbom "$SBOM_LAYER" \
  --arg source "$SOURCE" '
  .bindings | length == 1 and
  .[0].digest == $root and
  .[0].root.mediaType == "application/vnd.oci.image.index.v1+json" and
  .[0].root.manifests[0].digest == $platform and
  .[0].root.manifests[0].platform == {os:"linux",architecture:"amd64"} and
  .[0].platform.digest == $platform and
  (any(.[0].referrers[];
    .digest == $provenance and .kind == "provenance" and
    .artifactType == "application/vnd.in-toto+json" and
    .predicateType == "https://slsa.dev/provenance/v1")) and
  (any(.[0].referrers[];
    .digest == $sbom and .kind == "sbom" and
    .artifactType == "application/spdx+json" and
    .predicateType == "https://spdx.dev/Document")) and
  .[0].githubAttestations[0].source == $source and
  .[0].githubAttestations[0].revision == $source and
  .[0].githubAttestations[0].repository ==
    "https://github.com/NickolayMamonov/meet-backend-v3" and
  .[0].githubAttestations[0].workflow ==
    "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/build.yml@refs/heads/dev"
' "$TMP/read-valid.json" >/dev/null ||
  fail "read script did not preserve verified OCI/GitHub evidence"
bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" \
  --input "$TMP/read-valid.json" >/dev/null ||
  fail "read output is not compatible with image admission"

run_read real-shape >"$TMP/read-real-shape.json"
jq -e --arg root "$REAL_ROOT" --arg platform "$PLATFORM" \
  --arg provenance "$REAL_PROVENANCE_LAYER" --arg sbom "$REAL_SBOM_LAYER" '
  .bindings[0].digest == $root and
  (.bindings[0].referrers | length == 2) and
  (any(.bindings[0].referrers[];
    .digest == $provenance and .subject == $platform and
    .kind == "provenance" and
    .artifactType == "application/vnd.in-toto+json")) and
  (any(.bindings[0].referrers[];
    .digest == $sbom and .subject == $platform and
    .kind == "sbom" and
    .artifactType == "application/vnd.in-toto+json"))
' "$TMP/read-real-shape.json" >/dev/null ||
  fail "reader did not preserve the real BuildKit layer bindings"
set +e
real_admission=$(
  bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" \
    --input "$TMP/read-real-shape.json" 2>"$TMP/read-real-admission.stderr"
)
real_admission_status=$?
set -e
[ "$real_admission_status" -eq 0 ] ||
  fail "admission rejected the preserved BuildKit SBOM artifact type"

run_read inspect-fail >"$TMP/read-absent.json"
jq -e '.bindings == []' "$TMP/read-absent.json" >/dev/null ||
  fail "independently confirmed absence was not emitted"
expect_failure inspect-existing run_read inspect-existing
expect_failure inventory-error run_read inventory-error
expect_failure malformed-root run_read malformed-root
expect_failure wrong-platform run_read wrong-platform
expect_failure child-read-fail run_read child-read-fail
expect_failure child-byte-mismatch run_read child-byte-mismatch
expect_failure attestation-mismatch run_read attestation-mismatch

run_collect valid "$TMP/collected.json"
jq -e \
  --arg root "$ROOT" --arg platform "$PLATFORM" \
  --arg provenance "$PROVENANCE" --arg sbom "$SBOM" \
  --arg source "$SOURCE" '
  (.registry.manifests | length == 4) and
  all(.registry.manifests[]; .size > 0) and
  (any(.registry.manifests[];
    .digest == $root and
    .mediaType == "application/vnd.oci.image.index.v1+json")) and
  (any(.registry.manifests[];
    .digest == $platform and
    .mediaType == "application/vnd.oci.image.manifest.v1+json")) and
  (any(.registry.manifests[];
    .digest == $provenance and
    .subjectDigest == $platform and
    .artifactType == "application/vnd.in-toto+json" and
    .predicateTypes == ["https://slsa.dev/provenance/v1"])) and
  (any(.registry.manifests[];
    .digest == $sbom and
    .subjectDigest == $platform and
    .artifactType == "application/spdx+json" and
    .predicateTypes == ["https://spdx.dev/Document"])) and
  (.registry.attestations | length == 1) and
  .registry.attestations[0].subjectDigest == $root and
  .registry.attestations[0].sourceDigest == $source and
  .registry.attestations[0].sourceRepository ==
    "https://github.com/NickolayMamonov/meet-backend-v3" and
  (.registry.attestations[0].bundleDigest |
    test("^sha256:[0-9a-f]{64}$"))
' "$TMP/collected.json" >/dev/null ||
  fail "collector did not preserve descriptor or verified attestation evidence"
! grep -Fq '"size":0' "$TMP/collected.json" ||
  fail "collector emitted a zero-sized OCI descriptor"

run_collect real-shape "$TMP/collected-real-shape.json"
jq -e --arg root "$REAL_ROOT" --arg platform "$PLATFORM" \
  --arg attestation "$REAL_ATTESTATION" '
  (any(.registry.manifests[];
    .digest == $root and .size > 0)) and
  (any(.registry.manifests[];
    .digest == $attestation and
    .subjectDigest == $platform and
    .artifactType ==
      "application/vnd.docker.attestation.manifest.v1+json" and
    .predicateTypes == [
      "https://slsa.dev/provenance/v1",
      "https://spdx.dev/Document"
    ]))
' "$TMP/collected-real-shape.json" >/dev/null ||
  fail "collector rejected or rewrote the real BuildKit attestation shape"

expect_failure collector-child-read \
  run_collect child-read-fail "$TMP/collector-child-read.json"
expect_failure collector-attestation-mismatch \
  run_collect attestation-mismatch "$TMP/collector-attestation-mismatch.json"
expect_failure collector-inventory-error \
  run_collect inventory-error "$TMP/collector-inventory-error.json"
expect_failure collector-wrong-size \
  run_collect collector-wrong-size "$TMP/collector-wrong-size.json"
expect_failure collector-wrong-media \
  run_collect collector-wrong-media "$TMP/collector-wrong-media.json"
expect_failure collector-missing-artifact \
  run_collect collector-missing-artifact "$TMP/collector-missing-artifact.json"
expect_failure collector-missing-predicate \
  run_collect collector-missing-predicate "$TMP/collector-missing-predicate.json"
expect_failure collector-subject-disagreement \
  run_collect collector-subject-disagreement \
    "$TMP/collector-subject-disagreement.json"

echo "test image state reader fixtures passed: exact descriptors, verified identities, real BuildKit binding, independent absence, and remote/mismatch rejection"
