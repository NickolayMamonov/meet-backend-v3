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
COLLECT_RELEASE_ID=367640510
COLLECT_TAG=v1.0.1
COLLECT_VERSION=1.0.1
COLLECT_SOURCE=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
COLLECT_ROOT=sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6
COLLECT_SIGNER=4bff2902511e8e739d7604bf120b121429e60aeb
PROVENANCE_LAYER=sha256:3333333333333333333333333333333333333333333333333333333333333333
SBOM_LAYER=sha256:5555555555555555555555555555555555555555555555555555555555555555
REAL_PROVENANCE_LAYER=sha256:7777777777777777777777777777777777777777777777777777777777777777
REAL_SBOM_LAYER=sha256:8888888888888888888888888888888888888888888888888888888888888888
DATA=$TMP/data
BIN=$TMP/bin
mkdir "$DATA" "$BIN"

digest_of() { printf 'sha256:%s\n' "$(sha256sum "$1" | awk '{print $1}')"; }
size_of() { wc -c <"$1" | tr -d ' '; }
REAL_SHA256SUM=$(command -v sha256sum)

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
    layers:[{
      mediaType:"application/vnd.oci.image.layer.v1.tar+gzip",
      digest:"sha256:9999999999999999999999999999999999999999999999999999999999999999",
      size:1
    }],
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

jq -cS -n '{mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",fixture:"closure-derived-sigstore-bundle"}' >"$DATA/sigstore.bundle"
BUNDLE=$(digest_of "$DATA/sigstore.bundle")
BUNDLE_SIZE=$(size_of "$DATA/sigstore.bundle")

jq -cS -n --arg platform "$PLATFORM" --argjson size "$PLATFORM_SIZE" '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",artifactType:"application/vnd.in-toto+json",subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,size:$size},config:{mediaType:"application/vnd.oci.empty.v1+json",digest:"sha256:2222222222222222222222222222222222222222222222222222222222222222",size:2},layers:[{mediaType:"application/vnd.in-toto+json",digest:"sha256:3333333333333333333333333333333333333333333333333333333333333333",size:17,annotations:{"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}}]}' >"$DATA/provenance.json"
PROVENANCE=$(digest_of "$DATA/provenance.json")
PROVENANCE_SIZE=$(size_of "$DATA/provenance.json")

jq -cS -n --arg platform "$PLATFORM" --argjson size "$PLATFORM_SIZE" '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",artifactType:"application/spdx+json",subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,size:$size},config:{mediaType:"application/vnd.oci.empty.v1+json",digest:"sha256:4444444444444444444444444444444444444444444444444444444444444444",size:2},layers:[{mediaType:"application/spdx+json",digest:"sha256:5555555555555555555555555555555555555555555555555555555555555555",size:19,annotations:{"in-toto.io/predicate-type":"https://spdx.dev/Document"}}]}' >"$DATA/sbom.json"
SBOM=$(digest_of "$DATA/sbom.json")
SBOM_SIZE=$(size_of "$DATA/sbom.json")

jq -cS -n --arg platform "$PLATFORM" --argjson size "$PLATFORM_SIZE" --arg bundle "$BUNDLE" --argjson bundleSize "$BUNDLE_SIZE" '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",artifactType:"application/vnd.dev.sigstore.bundle.v0.3+json",subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,size:$size},config:{mediaType:"application/vnd.oci.empty.v1+json",digest:"sha256:6666666666666666666666666666666666666666666666666666666666666666",size:2},layers:[{mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",digest:$bundle,size:$bundleSize,annotations:{"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}}]}' >"$DATA/signature.json"
SIGNATURE=$(digest_of "$DATA/signature.json")
SIGNATURE_SIZE=$(size_of "$DATA/signature.json")

jq -cS -n --arg platform "$PLATFORM" --argjson platformSize "$PLATFORM_SIZE" --arg provenance "$PROVENANCE" --argjson provenanceSize "$PROVENANCE_SIZE" --arg sbom "$SBOM" --argjson sbomSize "$SBOM_SIZE" --arg signature "$SIGNATURE" --argjson signatureSize "$SIGNATURE_SIZE" '{schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",manifests:[{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,size:$platformSize,platform:{os:"linux",architecture:"amd64"}},{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$provenance,size:$provenanceSize,annotations:{"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":$platform},platform:{os:"unknown",architecture:"unknown"}},{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$sbom,size:$sbomSize,annotations:{"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":$platform},platform:{os:"unknown",architecture:"unknown"}},{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$signature,size:$signatureSize,annotations:{"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":$platform},platform:{os:"unknown",architecture:"unknown"}}]}' >"$DATA/root.json"
ROOT=$(digest_of "$DATA/root.json")

jq -cS -n --arg bundle "$BUNDLE" --argjson bundleSize "$BUNDLE_SIZE" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",artifactType:"application/vnd.docker.attestation.manifest.v1+json",config:{mediaType:"application/vnd.oci.empty.v1+json",digest:"sha256:6666666666666666666666666666666666666666666666666666666666666666",size:2},layers:[
    {mediaType:"application/vnd.in-toto+json",digest:"sha256:7777777777777777777777777777777777777777777777777777777777777777",size:23,annotations:{"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}},
    {mediaType:"application/vnd.in-toto+json",digest:"sha256:8888888888888888888888888888888888888888888888888888888888888888",size:29,annotations:{"in-toto.io/predicate-type":"https://spdx.dev/Document"}},
    {mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",digest:$bundle,size:$bundleSize}
  ]}
' >"$DATA/real-attestation.json"
REAL_ATTESTATION=$(digest_of "$DATA/real-attestation.json")
REAL_ATTESTATION_SIZE=$(size_of "$DATA/real-attestation.json")
jq -cS -n \
  --arg platform "$PLATFORM" --argjson platformSize "$PLATFORM_SIZE" \
  --arg attestation "$REAL_ATTESTATION" --argjson attestationSize "$REAL_ATTESTATION_SIZE" \
  '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.index.v1+json",
    manifests:[
      {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,size:$platformSize,platform:{os:"linux",architecture:"amd64"}},
      {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$attestation,size:$attestationSize,annotations:{"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":$platform},platform:{os:"unknown",architecture:"unknown"}}
    ]
  }
' >"$DATA/real-root.json"
REAL_ROOT=$(digest_of "$DATA/real-root.json")

jq -cS -n --arg source "$SOURCE" '
  [[{
    id:123,
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
  --arg signature "$SIGNATURE" \
  --arg source "$SOURCE" --arg alias "$ALIAS" '
  [[
    {id:1,name:$root,metadata:{container:{tags:[
      "v1.2.3","1.2.3",("sha-"+$source),$alias
    ]}}},
    {id:2,name:$platform,metadata:{container:{tags:[]}}},
    {id:3,name:$provenance,metadata:{container:{tags:[]}}},
    {id:4,name:$sbom,metadata:{container:{tags:[]}}},
    {id:5,name:$signature,metadata:{container:{tags:[]}}}
  ]]
' >"$DATA/packages.json"
jq -cS -n --arg root "$ROOT" --arg source "$SOURCE" --arg image "$IMAGE" '
  [{
    attestation:{bundle:{fixture:"verified-bundle"}},
    verificationResult:{
      statement:{
        predicateType:"https://slsa.dev/provenance/v1",
        subject:[{name:$image,digest:{sha256:($root|sub("^sha256:";""))}}]
      },
      signature:{certificate:{
        sourceRepositoryURI:
          "https://github.com/NickolayMamonov/meet-backend-v3",
        sourceRepositoryDigest:$source,
        sourceRepositoryRef:"refs/heads/dev",
        buildSignerURI:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/promote-dev-digest-to-test-vps.yml@refs/heads/dev",
        buildSignerDigest:$source,
        subjectAlternativeName:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/promote-dev-digest-to-test-vps.yml@refs/heads/dev",
        issuer:"https://token.actions.githubusercontent.com",
        workflowIdentity:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/promote-dev-digest-to-test-vps.yml@refs/heads/dev"
      }}
    }
  }]
' >"$DATA/verified.json"
jq '
  .[0].verificationResult.signature.certificate.buildSignerURI =
    "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" |
  .[0].verificationResult.signature.certificate.subjectAlternativeName =
    "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev" |
  .[0].verificationResult.signature.certificate.workflowIdentity =
    "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev"
' "$DATA/verified.json" >"$DATA/verified-release.json"
jq '.[] .verificationResult.signature.certificate.sourceRepositoryDigest =
  "ffffffffffffffffffffffffffffffffffffffff"' \
  "$DATA/verified.json" >"$DATA/verified-mismatch.json"
jq -cS -n \
  --arg root "$COLLECT_ROOT" --arg image "$IMAGE" \
  --arg source "$COLLECT_SIGNER" '
  [{
    verificationResult:{
      statement:{
        predicateType:"https://slsa.dev/provenance/v1",
        subject:[{name:$image,digest:{sha256:($root|sub("^sha256:";""))}}]
      },
      signature:{certificate:{
        sourceRepositoryURI:
          "https://github.com/NickolayMamonov/meet-backend-v3",
        sourceRepositoryDigest:$source,
        sourceRepositoryRef:"refs/heads/dev",
        buildSignerURI:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev",
        buildSignerDigest:$source,
        subjectAlternativeName:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev",
        issuer:"https://token.actions.githubusercontent.com",
        workflowIdentity:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev"
      }}
    }
  }]
' >"$DATA/collect-verified.json"
jq -cS -n --arg source "$COLLECT_SOURCE" --arg tag "$COLLECT_TAG" --arg version "$COLLECT_VERSION" --argjson releaseId "$COLLECT_RELEASE_ID" '
  [[{
    id:$releaseId,
    tag_name:$tag,
    target_commitish:$source,
    draft:false,immutable:true,protected:true,prerelease:false,
    published_at:"2026-08-12T01:00:00Z",
    assets:[]
  }]]
' >"$DATA/collect-releases.json"
jq -cS -n --arg source "$COLLECT_SOURCE" '
  {object:{type:"commit",sha:$source}}
' >"$DATA/collect-tag-ref.json"
jq -cS -n \
  --arg root "$COLLECT_ROOT" --arg platform "$PLATFORM" \
  --arg provenance "$PROVENANCE" --arg sbom "$SBOM" \
  --arg signature "$SIGNATURE" --arg source "$COLLECT_SOURCE" \
  --arg tag "$COLLECT_TAG" --arg version "$COLLECT_VERSION" '
  [[
    {id:2001,name:$root,metadata:{container:{tags:[
      $tag,$version,("sha-"+$source)
    ]}}},
    {id:2002,name:$platform,metadata:{container:{tags:[]}}},
    {id:2003,name:$provenance,metadata:{container:{tags:[]}}},
    {id:2004,name:$sbom,metadata:{container:{tags:[]}}},
    {id:2005,name:$signature,metadata:{container:{tags:[]}}}
  ]]
' >"$DATA/collect-packages.json"
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

export FIXTURE_DATA=$DATA ROOT PLATFORM PROVENANCE SBOM BUNDLE SIGNATURE SOURCE VERSION ALIAS
export REAL_ROOT REAL_ATTESTATION ROOT_WRONG_SIZE ROOT_WRONG_MEDIA
export ROOT_MISSING_ARTIFACT PROVENANCE_MISSING_ARTIFACT
export ROOT_MISSING_PREDICATE PROVENANCE_MISSING_PREDICATE
export ROOT_SUBJECT_DISAGREEMENT PROVENANCE_SUBJECT_DISAGREEMENT
export IMAGE COLLECT_ROOT COLLECT_SOURCE COLLECT_SIGNER DATA REAL_SHA256SUM
cp "$DATA/platform.json" "$DATA/${PLATFORM#sha256:}.json"
cp "$DATA/provenance.json" "$DATA/${PROVENANCE#sha256:}.json"
cp "$DATA/sbom.json" "$DATA/${SBOM#sha256:}.json"
cp "$DATA/signature.json" "$DATA/${SIGNATURE#sha256:}.json"
cp "$DATA/sigstore.bundle" "$DATA/${BUNDLE#sha256:}.bundle"
cp "$DATA/root.json" "$DATA/${ROOT#sha256:}.json"
cp "$DATA/root.json" "$DATA/${COLLECT_ROOT#sha256:}.json"
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
if [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ] &&
   [[ "$*" == *"$IMAGE@$COLLECT_ROOT"* ]]; then
  if [ "$scenario" = real-shape ]; then
    cat "$FIXTURE_DATA/real-root.json"
  else
    cat "$FIXTURE_DATA/root.json"
  fi
  exit 0
fi
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
      if [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ]; then
        cat "$FIXTURE_DATA/collect-releases.json"
      else
        cat "$FIXTURE_DATA/releases.json"
      fi
      ;;
    users/*/packages/container/*/versions\?*)
      if [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ]; then
        case "$scenario" in
          inventory-error|collector-wrong-size|collector-wrong-media|\
          collector-missing-artifact|collector-missing-predicate|\
          collector-subject-disagreement)
            exit 47
            ;;
          real-shape)
            jq -cn --arg root "$COLLECT_ROOT" --arg platform "$PLATFORM" \
              --arg attestation "$REAL_ATTESTATION" --arg source "$COLLECT_SOURCE" '
              [[
                {id:2001,name:$root,metadata:{container:{tags:[
                  "v1.0.1","1.0.1",("sha-"+$source)
                ]}}},
                {id:2002,name:$platform,metadata:{container:{tags:[]}}},
                {id:2003,name:$attestation,metadata:{container:{tags:[]}}}
              ]]
            '
            exit 0
            ;;
          *)
            cat "$FIXTURE_DATA/collect-packages.json"
            exit 0
            ;;
        esac
      fi
      case "$scenario" in
        inventory-error) exit 47 ;;
        inspect-fail) printf '[[]]\n' ;;
        inspect-existing)
          jq -cn --arg root "$ROOT" --arg alias "$ALIAS" \
            '[[{id:1,name:$root,metadata:{container:{tags:[$alias]}}}]]'
          ;;
        real-shape)
          jq -cn --arg root "$REAL_ROOT" --arg platform "$PLATFORM" \
            --arg attestation "$REAL_ATTESTATION" --arg signature "$SIGNATURE" --arg source "$SOURCE" \
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
            --arg signature "$SIGNATURE" \
            --arg source "$SOURCE" --arg alias "$ALIAS" '
            [[
              {id:1,name:$root,metadata:{container:{tags:[
                "v1.2.3","1.2.3",("sha-"+$source),$alias
              ]}}},
              {id:2,name:$platform,metadata:{container:{tags:[]}}},
              {id:3,name:$provenance,metadata:{container:{tags:[]}}},
              {id:4,name:$sbom,metadata:{container:{tags:[]}}},
              {id:5,name:$signature,metadata:{container:{tags:[]}}}
            ]]
          '
          ;;
        *) cat "$FIXTURE_DATA/packages.json" ;;
      esac
      ;;
    repos/*/git/ref/tags/*)
      if [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ]; then
        cat "$FIXTURE_DATA/collect-tag-ref.json"
      else
        cat "$FIXTURE_DATA/tag-ref.json"
      fi
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
    if [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ]; then
      verified_root=$COLLECT_ROOT
    else
      verified_root=$ROOT
    fi
    case "$scenario" in
      real-shape)
        if [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ]; then
          verified_root=$COLLECT_ROOT
        else
          verified_root=$REAL_ROOT
        fi
        ;;
      collector-wrong-size) verified_root=$ROOT_WRONG_SIZE ;;
      collector-wrong-media) verified_root=$ROOT_WRONG_MEDIA ;;
      collector-missing-artifact) verified_root=$ROOT_MISSING_ARTIFACT ;;
      collector-missing-predicate) verified_root=$ROOT_MISSING_PREDICATE ;;
      collector-subject-disagreement)
        verified_root=$ROOT_SUBJECT_DISAGREEMENT
        ;;
    esac
    response="$FIXTURE_DATA/verified.json"
    [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ] &&
      response="$FIXTURE_DATA/collect-verified.json"
    jq -cS --arg root "${verified_root#sha256:}" '
      .[0].verificationResult.statement.subject[0].digest.sha256 = $root
    ' "$response"
  fi
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 96
EOF
cat >"$BIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAKE_ATTESTATION_MODE:-candidate}" = release ] &&
   [ "$#" -eq 1 ] &&
   [ "$(basename -- "$1")" = "raw-${COLLECT_ROOT#sha256:}.json" ]; then
  printf '%s  %s\n' "${COLLECT_ROOT#sha256:}" "$1"
  exit 0
fi
exec "$REAL_SHA256SUM" "$@"
EOF
chmod +x "$BIN/docker" "$BIN/gh" "$BIN/sha256sum"

run_read() {
  env PATH="$BIN:$PATH" GH_TOKEN=fixture \
    IMAGE_ATTESTATION_FIXTURE_DIR="$DATA" \
    GITHUB_REPOSITORY="$REPOSITORY" FAKE_SCENARIO="${1:-valid}" \
    bash "$READ" "$IMAGE" "$ALIAS" "$SOURCE" "$VERSION"
}
run_collect() {
  local scenario=$1 output=$2
  env PATH="$BIN:$PATH" GH_TOKEN=fixture IMAGE_ATTESTATION_FIXTURE_DIR="$DATA" \
    FAKE_ATTESTATION_MODE=release FAKE_SCENARIO="$scenario" \
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
  .[0].attestationEvidence[0].schema ==
    "meet-backend/image-attestation-evidence/v2" and
  .[0].attestationEvidence[0].sourceRepository ==
    "https://github.com/NickolayMamonov/meet-backend-v3" and
  .[0].attestationEvidence[0].releaseSourceDigest == $source and
  .[0].attestationEvidence[0].certificateSourceDigest == $source and
  .[0].attestationEvidence[0].signerDigest == $source and
  .[0].attestationEvidence[0].sourceRef == "refs/heads/dev" and
  .[0].attestationEvidence[0].signerWorkflow ==
    ".github/workflows/promote-dev-digest-to-test-vps.yml" and
  .[0].attestationEvidence[0].rootDigest == $root and
  .[0].attestationEvidence[0].platformDigest == $platform and
  .[0].attestationEvidence[0].subject.digest == $root
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
if ! bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" \
  --input "$TMP/read-real-shape.json" \
  >"$TMP/read-real-admission.json" 2>"$TMP/read-real-admission.stderr"; then
  fail "admission rejected the preserved BuildKit SBOM artifact type"
fi

run_read inspect-fail >"$TMP/read-absent.json"
jq -e '.schema == "meet-backend/test-image-state/v2" and .bindings == []' "$TMP/read-absent.json" >/dev/null ||
  fail "independently confirmed absence was not emitted as canonical v2 state"
bash "$ADMIT" inspect --source "$SOURCE" --version "$VERSION" \
  --input "$TMP/read-absent.json" >"$TMP/read-absent-admission.json" ||
  fail "canonical absent reader output was rejected by image admission"
jq -e '.state == "absent" and .reason == "no-binding"' "$TMP/read-absent-admission.json" >/dev/null ||
  fail "image admission did not preserve absent state"
printf '%s\n' '{"schema":"meet-backend/test-image-state/v1","bindings":[]}' >"$TMP/read-absent-v1.json"
if bash "$ADMIT" inspect --source "$SOURCE" --version "$VERSION" \
    --input "$TMP/read-absent-v1.json" >"$TMP/read-absent-v1-admission.json" 2>"$TMP/read-absent-v1.stderr"; then
  fail "v1 absent reader output was accepted"
fi
jq -e '.state == "rejected" and .reason == "malformed-input"' "$TMP/read-absent-v1-admission.json" >/dev/null ||
  fail "v1 absent reader output was not rejected as malformed"
printf '{\n' >"$TMP/read-absent-malformed.json"
if bash "$ADMIT" inspect --source "$SOURCE" --version "$VERSION" \
    --input "$TMP/read-absent-malformed.json" >"$TMP/read-absent-malformed-admission.json" 2>"$TMP/read-absent-malformed.stderr"; then
  fail "malformed absent reader output was accepted"
fi
jq -e '.state == "rejected" and .reason == "malformed-input"' "$TMP/read-absent-malformed-admission.json" >/dev/null ||
  fail "malformed absent reader output was not rejected"
expect_failure inspect-existing run_read inspect-existing
expect_failure inventory-error run_read inventory-error
expect_failure malformed-root run_read malformed-root
expect_failure wrong-platform run_read wrong-platform
expect_failure child-read-fail run_read child-read-fail
expect_failure child-byte-mismatch run_read child-byte-mismatch
expect_failure attestation-mismatch run_read attestation-mismatch

run_collect valid "$TMP/collected.json"
jq -e \
  --arg root "$COLLECT_ROOT" --arg platform "$PLATFORM" \
  --arg provenance "$PROVENANCE" --arg sbom "$SBOM" \
  --arg signature "$SIGNATURE" \
  --arg source "$COLLECT_SOURCE" --arg signer "$COLLECT_SIGNER" '
  (.registry.manifests | length == 5) and
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
  (any(.registry.manifests[];
    .digest == $signature and
    .subjectDigest == $platform and
    .artifactType == "application/vnd.dev.sigstore.bundle.v0.3+json" and
    .predicateTypes == ["https://slsa.dev/provenance/v1"])) and
  (.registry.evidence | length == 1) and
  .registry.evidence[0].schema ==
    "meet-backend/image-attestation-evidence/v2" and
  .registry.evidence[0].rootDigest == $root and
  .registry.evidence[0].platformDigest == $platform and
  .registry.evidence[0].subject.digest == $root and
  .registry.evidence[0].releaseSourceDigest == $source and
  .registry.evidence[0].certificateSourceDigest == $signer and
  .registry.evidence[0].signerDigest == $signer and
  .registry.evidence[0].signerWorkflow ==
    ".github/workflows/release-please.yml" and
  .registry.evidence[0].sourceRepository ==
    "https://github.com/NickolayMamonov/meet-backend-v3" and
  (.registry.evidence[0].evidenceStorage.bundleDigest |
    test("^sha256:[0-9a-f]{64}$"))
' "$TMP/collected.json" >/dev/null ||
  fail "collector did not preserve descriptor or verified attestation evidence"
! grep -Fq '"size":0' "$TMP/collected.json" ||
  fail "collector emitted a zero-sized OCI descriptor"

run_collect real-shape "$TMP/collected-real-shape.json"
jq -e --arg root "$COLLECT_ROOT" --arg platform "$PLATFORM" \
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
