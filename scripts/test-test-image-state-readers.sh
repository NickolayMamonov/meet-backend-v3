#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
READ="$ROOT_DIR/scripts/read-test-image-state.sh"
ADMIT="$ROOT_DIR/scripts/admit-test-image.sh"
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

fail() { echo "test image state reader fixture failed: $*" >&2; exit 1; }
expect_failure() {
  local name=$1
  shift
  if "$@" >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"; then
    fail "expected failure was accepted: $name"
  fi
}

SOURCE=0123456789abcdef0123456789abcdef01234567
VERSION=1.2.3
REPOSITORY=NickolayMamonov/meet-backend-v3
IMAGE=ghcr.io/nickolaymamonov/meet-backend-v3
ALIAS=test-sha-$SOURCE
DATA=$TMP/data
BIN=$TMP/bin
mkdir "$DATA" "$BIN"

digest_of() { printf 'sha256:%s\n' "$(sha256sum "$1" | awk '{print $1}')"; }
size_of() { wc -c <"$1" | tr -d ' '; }

jq -cS -n --arg source "$SOURCE" --arg version "$VERSION" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
   config:{mediaType:"application/vnd.oci.image.config.v1+json",
     digest:"sha256:1111111111111111111111111111111111111111111111111111111111111111",
     size:2},layers:[],
   fixtureLabels:{
     "org.opencontainers.image.source":"https://github.com/NickolayMamonov/meet-backend-v3",
     "org.opencontainers.image.revision":$source,
     "org.opencontainers.image.version":$version}}
' >"$DATA/platform.json"
PLATFORM=$(digest_of "$DATA/platform.json")
PLATFORM_SIZE=$(size_of "$DATA/platform.json")

make_attestation() {
  local kind=$1 artifact=$2 layer=$3 predicate=$4 output=$5
  : "$kind"
  jq -cS -n --arg platform "$PLATFORM" --argjson size "$PLATFORM_SIZE" \
    --arg artifact "$artifact" --arg layer "$layer" --arg predicate "$predicate" '
    {schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
     artifactType:$artifact,subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",
       digest:$platform,size:$size},
     config:{mediaType:"application/vnd.oci.empty.v1+json",
       digest:"sha256:2222222222222222222222222222222222222222222222222222222222222222",
       size:2},
     layers:[{mediaType:$artifact,digest:$layer,size:17,
       annotations:{"in-toto.io/predicate-type":$predicate}}]}
  ' >"$output"
}
make_attestation provenance application/vnd.in-toto+json \
  sha256:3333333333333333333333333333333333333333333333333333333333333333 \
  https://slsa.dev/provenance/v1 "$DATA/provenance.json"
make_attestation sbom application/spdx+json \
  sha256:5555555555555555555555555555555555555555555555555555555555555555 \
  https://spdx.dev/Document "$DATA/sbom.json"
PROVENANCE=$(digest_of "$DATA/provenance.json")
PROVENANCE_SIZE=$(size_of "$DATA/provenance.json")
SBOM=$(digest_of "$DATA/sbom.json")
SBOM_SIZE=$(size_of "$DATA/sbom.json")

jq -cS -n --arg platform "$PLATFORM" --argjson platformSize "$PLATFORM_SIZE" \
  --arg provenance "$PROVENANCE" --argjson provenanceSize "$PROVENANCE_SIZE" \
  --arg sbom "$SBOM" --argjson sbomSize "$SBOM_SIZE" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",manifests:[
    {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,
      size:$platformSize,platform:{os:"linux",architecture:"amd64"}},
    {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$provenance,
      size:$provenanceSize,annotations:{
        "vnd.docker.reference.type":"attestation-manifest",
        "vnd.docker.reference.digest":$platform},
      platform:{os:"unknown",architecture:"unknown"}},
    {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$sbom,
      size:$sbomSize,annotations:{
        "vnd.docker.reference.type":"attestation-manifest",
        "vnd.docker.reference.digest":$platform},
      platform:{os:"unknown",architecture:"unknown"}}]}
' >"$DATA/root.json"
ROOT=$(digest_of "$DATA/root.json")
export FIXTURE_DATA="$DATA" ALIAS ROOT PLATFORM PROVENANCE SBOM

cp "$DATA/platform.json" "$DATA/${PLATFORM#sha256:}.json"
cp "$DATA/provenance.json" "$DATA/${PROVENANCE#sha256:}.json"
cp "$DATA/sbom.json" "$DATA/${SBOM#sha256:}.json"
cp "$DATA/root.json" "$DATA/${ROOT#sha256:}.json"

jq -cS -n --arg source "$SOURCE" --arg version "$VERSION" '
  {"org.opencontainers.image.source":
    "https://github.com/NickolayMamonov/meet-backend-v3",
   "org.opencontainers.image.revision":$source,
   "org.opencontainers.image.version":$version}
' >"$DATA/labels.json"

jq -cS -n --arg root "$ROOT" --arg source "$SOURCE" '
  [{verificationResult:{
    statement:{predicateType:"https://slsa.dev/provenance/v1",
      subject:[{name:"image-index.json",
        digest:{sha256:($root|sub("^sha256:";""))}}]},
    signature:{certificate:{
      sourceRepositoryURI:"https://github.com/NickolayMamonov/meet-backend-v3",
      sourceRepositoryDigest:$source,sourceRepositoryRef:"refs/heads/dev",
      buildSignerURI:"https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/build.yml@refs/heads/dev",
      subjectAlternativeName:"https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/build.yml@refs/heads/dev"
    }}}}]
' >"$DATA/verified.json"

cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${FAKE_SCENARIO:-valid}
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --write-out) shift 2 ;;
    --*) shift ;;
    *) url=$1; shift ;;
  esac
done
[ -n "$output" ] || { echo "curl fixture requires --output" >&2; exit 90; }
status=200
if [[ "$url" == https://ghcr.io/token\?* ]]; then
  printf '{"token":"registry-token"}\n' >"$output"
elif [[ "$url" == https://ghcr.io/v2/*/manifests/* ]]; then
  reference=${url##*/manifests/}
  case "$reference" in
    "$ALIAS")
      case "$scenario" in
        absent) printf '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}\n' >"$output"; status=404 ;;
        ambiguous-404) printf '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}\n' >"$output"; status=404 ;;
        unknown-404) printf '{"errors":[{"code":"UNKNOWN","message":"not sure"}]}\n' >"$output"; status=404 ;;
        malformed-root) printf '{"schemaVersion":2}\n' >"$output" ;;
        *) cat "$FIXTURE_DATA/root.json" >"$output" ;;
      esac
      ;;
    *)
      case "$scenario" in
        child-error) printf '{"errors":[{"code":"DENIED","message":"denied"}]}\n' >"$output"; status=403 ;;
        child-mismatch) cat "$FIXTURE_DATA/${reference#sha256:}.json" >"$output"; printf ' ' >>"$output" ;;
        *) cat "$FIXTURE_DATA/${reference#sha256:}.json" >"$output" ;;
      esac
      ;;
  esac
else
  echo "unexpected curl URL: $url" >&2
  exit 91
fi
printf '%s' "$status"
EOF

cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  pull) exit 0 ;;
  image)
    [ "$2" = inspect ] || exit 92
    cat "$FIXTURE_DATA/labels.json"
    ;;
  *) echo "unexpected docker invocation: $*" >&2; exit 93 ;;
esac
EOF

cat >"$BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
scenario=${FAKE_SCENARIO:-valid}
if [ "$1" = auth ] && [ "$2" = token ]; then
  printf 'fixture-token\n'
  exit 0
fi
if [ "$1" = api ]; then
  endpoint=${!#}
  case "$endpoint" in
    users/*/packages/container/*/versions\?*)
      case "$scenario" in
        absent)
          printf '[[]]\n' ;;
        ambiguous-404)
          jq -cn --arg alias "$ALIAS" --arg root "$ROOT" '
            [[{id:1,name:$root,metadata:{container:{tags:[$alias]}}},
              {id:2,name:"sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
               metadata:{container:{tags:[$alias]}}}]]
          ' ;;
        extra-alias)
          jq -cn --arg alias "$ALIAS" --arg root "$ROOT" '
            [[{id:1,name:$root,metadata:{container:{tags:[$alias,"v1.2.3"]}}}]]
          ' ;;
        *) jq -cn --arg alias "$ALIAS" --arg root "$ROOT" '
          [[{id:1,name:$root,metadata:{container:{tags:[$alias]}}}]]
        ' ;;
      esac
      ;;
    repos/*/attestations/*)
      case "$scenario" in
        empty-attestation|absent) printf '{"attestations":[]}\n' ;;
        malformed-attestation) printf '{"attestations":{}}\n' ;;
        *) printf '{"attestations":[{"bundle":{"fixture":"present"}}]}\n' ;;
      esac
      ;;
    user) printf '{"login":"fixture-user"}\n' ;;
    *) echo "unexpected gh endpoint: $endpoint" >&2; exit 94 ;;
  esac
  exit 0
fi
if [ "$1" = attestation ] && [ "$2" = verify ]; then
  [ "$scenario" != verify-fail ] || exit 95
  cat "$FIXTURE_DATA/verified.json"
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 96
EOF
chmod +x "$BIN/curl" "$BIN/docker" "$BIN/gh"

run_read() {
  env PATH="$BIN:$PATH" GH_TOKEN=fixture GITHUB_ACTOR=fixture-user \
    GITHUB_REPOSITORY="$REPOSITORY" FIXTURE_DATA="$DATA" \
    FAKE_SCENARIO="${1:-valid}" bash "$READ" "$IMAGE" "$ALIAS" "$SOURCE" "$VERSION"
}

bash -n "$READ"
bash -n "$ADMIT"
run_read valid >"$TMP/valid.json"
jq -e --arg root "$ROOT" --arg platform "$PLATFORM" '
  .bindings | length == 1 and .[0].digest == $root and
  .[0].rootDigest == $root and .[0].platformDigest == $platform and
  .[0].attestationStatus == "verified" and
  (. [0].referrers | length == 2)
' "$TMP/valid.json" >/dev/null || fail "verified reader output is incomplete"
bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" \
  --input "$TMP/valid.json" --expected-root-digest "$ROOT" \
  --expected-platform-digest "$PLATFORM" >/dev/null

run_read empty-attestation >"$TMP/empty-attestation.json"
jq -e '.bindings[0].attestationStatus == "missing" and
  (.bindings[0].githubAttestations | length == 0)' "$TMP/empty-attestation.json" >/dev/null ||
  fail "successful empty attestation collection was not classified missing"
bash "$ADMIT" inspect --source "$SOURCE" --version "$VERSION" \
  --input "$TMP/empty-attestation.json" >"$TMP/partial.json"
jq -e '.state == "partial" and .reason == "missing-github-attestation"' "$TMP/partial.json" >/dev/null ||
  fail "unsigned inspection was not quarantined as partial"
expect_failure unsigned-verify bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" \
  --input "$TMP/empty-attestation.json"

run_read absent >"$TMP/absent.json"
jq -e '.bindings == []' "$TMP/absent.json" >/dev/null || fail "confirmed absence was not emitted"
expect_failure unknown-404 run_read unknown-404
expect_failure ambiguous-404 run_read ambiguous-404
expect_failure extra-alias run_read extra-alias
expect_failure malformed-root run_read malformed-root
expect_failure malformed-attestation run_read malformed-attestation
expect_failure verify-fail run_read verify-fail
expect_failure child-error run_read child-error
expect_failure child-mismatch run_read child-mismatch

echo "test image state reader fixtures passed: authenticated lookup, exact candidate binding, verified/missing attestations, digest identity, and rejection paths"
