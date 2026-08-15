#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-immutable-release-proof.sh
TMP=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$TMP"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM
mkdir "$TMP/bin" "$TMP/assets"

REPOSITORY=FixtureOwner/repo
TAG=v1.2.0
RELEASE_ID=120
SOURCE_SHA=1234567890abcdef1234567890abcdef12345678
ASSETS=(
  release-manifest.json
  image-index.json
  image-inspect.txt
  SHA256SUMS
)

printf '{"version":"1.2.0"}\n' >"$TMP/assets/release-manifest.json"
printf '{"digest":"sha256:fixture"}\n' >"$TMP/assets/image-index.json"
printf 'fixture image inspection\n' >"$TMP/assets/image-inspect.txt"
printf 'fixture checksums\n' >"$TMP/assets/SHA256SUMS"

jq -n \
  --argjson release_id "$RELEASE_ID" \
  --arg tag "$TAG" \
  --arg source_sha "$SOURCE_SHA" \
  --arg assets_dir "$TMP/assets" '
    def asset($id; $name):
      {
        id:$id,
        name:$name,
        state:"uploaded",
        digest:(
          "sha256:" +
          (
            if $name == "release-manifest.json" then $manifest
            elif $name == "image-index.json" then $index
            elif $name == "image-inspect.txt" then $inspect
            else $sums
            end
          )
        )
      };
    {
      id:$release_id,
      immutable:true,
      draft:false,
      tag_name:$tag,
      target_commitish:$source_sha,
      assets:[
        asset(1;"release-manifest.json"),
        asset(2;"image-index.json"),
        asset(3;"image-inspect.txt"),
        asset(4;"SHA256SUMS")
      ]
    }
  ' \
  --arg manifest "$(sha256sum "$TMP/assets/release-manifest.json" | awk '{print $1}')" \
  --arg index "$(sha256sum "$TMP/assets/image-index.json" | awk '{print $1}')" \
  --arg inspect "$(sha256sum "$TMP/assets/image-inspect.txt" | awk '{print $1}')" \
  --arg sums "$(sha256sum "$TMP/assets/SHA256SUMS" | awk '{print $1}')" \
  >"$TMP/release.json"
cp "$TMP/release.json" "$TMP/tag-release.json"

jq -n \
  --arg repository "$REPOSITORY" \
  --arg tag "$TAG" \
  --argjson release_id "$RELEASE_ID" \
  --arg source_sha "$SOURCE_SHA" \
  --arg manifest "$(sha256sum "$TMP/assets/release-manifest.json" | awk '{print $1}')" \
  --arg index "$(sha256sum "$TMP/assets/image-index.json" | awk '{print $1}')" \
  --arg inspect "$(sha256sum "$TMP/assets/image-inspect.txt" | awk '{print $1}')" \
  --arg sums "$(sha256sum "$TMP/assets/SHA256SUMS" | awk '{print $1}')" '
    {
      _type:"https://in-toto.io/Statement/v1",
      subject:[
        {
          uri:("pkg:github/" + $repository + "@" + $tag),
          digest:{sha1:$source_sha}
        },
        {name:"release-manifest.json",digest:{sha256:$manifest}},
        {name:"image-index.json",digest:{sha256:$index}},
        {name:"image-inspect.txt",digest:{sha256:$inspect}},
        {name:"SHA256SUMS",digest:{sha256:$sums}}
      ],
      predicateType:"https://in-toto.io/attestation/release/v0.2",
      predicate:{
        repository:$repository,
        databaseId:($release_id | tostring),
        tag:$tag,
        purl:("pkg:github/" + $repository + "@" + $tag)
      }
    }
  ' >"$TMP/statement.json"
payload=$(base64 <"$TMP/statement.json" | tr -d '\n')
jq -n --arg payload "$payload" --slurpfile statement "$TMP/statement.json" '
  {
    attestation:{
      bundle:{
        mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",
        dsseEnvelope:{
          payload:$payload,
          payloadType:"application/vnd.in-toto+json",
          signatures:[{sig:"fixture-signature"}]
        }
      },
      bundle_url:"https://api.github.test/fixture-bundle"
    },
    verificationResult:{
      mediaType:"application/vnd.dev.sigstore.verificationresult+json;version=0.1",
      signature:{
        certificate:{
          certificateIssuer:"CN=Fulcio Intermediate l1,O=GitHub\\, Inc.",
          subjectAlternativeName:"https://dotcom.releases.github.com"
        }
      },
      statement:$statement[0]
    }
  }
' >"$TMP/attestation.json"

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

{
  separator=
  for argument in "$@"; do
    printf '%s%s' "$separator" "$argument"
    separator=$'\t'
  done
  printf '\n'
} >>"$GH_LOG"

if [ "$1" = api ]; then
  [ "$2" = --method ] && [ "$3" = GET ] && [ "$#" -eq 4 ] || exit 81
  case "$4" in
    "repos/$EXPECTED_REPOSITORY/releases/$EXPECTED_RELEASE_ID")
      cat "$RELEASE_RESPONSE"
      ;;
    "repos/$EXPECTED_REPOSITORY/releases/tags/$EXPECTED_TAG")
      cat "$TAG_RESPONSE"
      ;;
    *) exit 82 ;;
  esac
elif [ "$1" = release ] && [ "$2" = verify ]; then
  [ "$#" -eq 7 ] &&
    [ "$3" = "$EXPECTED_TAG" ] &&
    [ "$4" = --repo ] &&
    [ "$5" = "$EXPECTED_REPOSITORY" ] &&
    [ "$6" = --format ] &&
    [ "$7" = json ] || exit 83
  [ "${FAIL_ATTESTATION:-false}" != true ] || exit 1
  cat "$ATTESTATION_RESPONSE"
elif [ "$1" = release ] && [ "$2" = verify-asset ]; then
  [ "$#" -eq 6 ] &&
    [ "$3" = "$EXPECTED_TAG" ] &&
    [ "$5" = --repo ] &&
    [ "$6" = "$EXPECTED_REPOSITORY" ] || exit 84
  [ -f "$4" ] || exit 85
  [ "${FAIL_ASSET:-}" != "$(basename "$4")" ] || exit 1
else
  exit 86
fi
EOF
chmod +x "$TMP/bin/gh"

export PATH="$TMP/bin:$PATH"
export GH_LOG=$TMP/gh.log
export EXPECTED_REPOSITORY=$REPOSITORY
export EXPECTED_TAG=$TAG
export EXPECTED_RELEASE_ID=$RELEASE_ID
export RELEASE_RESPONSE=$TMP/release.json
export TAG_RESPONSE=$TMP/tag-release.json
export ATTESTATION_RESPONSE=$TMP/attestation.json

proof_command() {
  "$VERIFY" \
    --repository "$REPOSITORY" \
    --tag "$TAG" \
    --release-id "$RELEASE_ID" \
    --source-sha "$SOURCE_SHA" \
    --assets-dir "$TMP/assets"
}

expect_failure() {
  local marker=$1
  shift
  : >"$GH_LOG"
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "expected immutable release proof rejection: $marker" >&2
    exit 1
  fi
  [ ! -s "$TMP/stdout" ] || {
    echo "proof rejection emitted stdout: $marker" >&2
    exit 1
  }
  [ -s "$TMP/stderr" ] || {
    echo "proof rejection omitted its safe error: $marker" >&2
    exit 1
  }
}

: >"$GH_LOG"
proof_command >"$TMP/proof.json"
jq -e \
  --arg repository "$REPOSITORY" \
  --arg tag "$TAG" \
  --argjson release_id "$RELEASE_ID" \
  --arg source_sha "$SOURCE_SHA" '
    .repository == $repository and
    .tag == $tag and
    .releaseId == $release_id and
    .sourceSha == $source_sha and
    .immutable == true and
    .draft == false and
    .attestation.verified == true and
    .attestation.predicateType ==
      "https://in-toto.io/attestation/release/v0.2" and
    (.attestation.bundleSha256 | test("^[0-9a-f]{64}$")) and
    (.attestation.claimSha256 | test("^[0-9a-f]{64}$")) and
    (.assets | length == 4) and
    all(.assets[];
      .repository == $repository and
      .tag == $tag and
      .releaseId == $release_id and
      .verified == true and
      (.apiDigest == ("sha256:" + .downloadSha256)) and
      (.attestationBundleSha256 == $bundle)
    )
  ' --arg bundle "$(jq -r '.attestation.bundleSha256' "$TMP/proof.json")" \
  "$TMP/proof.json" >/dev/null
! grep -Fq fixture-signature "$TMP/proof.json"
! grep -Fq fixture-bundle "$TMP/proof.json"

[ "$(grep -c $'^release\tverify-asset\t' "$GH_LOG")" -eq 4 ]
for asset in "${ASSETS[@]}"; do
  grep -Fx \
    $'release\tverify-asset\t'"$TAG"$'\t'"$TMP/assets/$asset"$'\t--repo\t'"$REPOSITORY" \
    "$GH_LOG" >/dev/null
done
! grep -Eq $'^release\tverify-asset\t--repo|^release\tverify-asset\t[^v]' \
  "$GH_LOG"
! grep -Fq '/releases/latest' "$GH_LOG"

expect_failure omitted-tag \
  "$VERIFY" --repository "$REPOSITORY" \
  --release-id "$RELEASE_ID" --source-sha "$SOURCE_SHA" \
  --assets-dir "$TMP/assets"
[ ! -s "$GH_LOG" ]

expect_failure wrong-explicit-tag \
  "$VERIFY" --repository "$REPOSITORY" --tag 1.2.0 \
  --release-id "$RELEASE_ID" --source-sha "$SOURCE_SHA" \
  --assets-dir "$TMP/assets"
[ ! -s "$GH_LOG" ]

jq '.id = 101 | .tag_name = "v1.0.1"' \
  "$TMP/tag-release.json" >"$TMP/latest-v1.0.1.json"
TAG_RESPONSE=$TMP/latest-v1.0.1.json \
  expect_failure latest-resolved-tag proof_command
! grep -q $'^release\tverify\t' "$GH_LOG"
! grep -Fq '/releases/latest' "$GH_LOG"

for mutation in \
  '.immutable = false' \
  'del(.immutable)' \
  '.immutable = "true"' \
  '.draft = true' \
  '.id = 121' \
  '.tag_name = "v1.0.1"' \
  '.target_commitish = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'; do
  jq "$mutation" "$TMP/release.json" >"$TMP/mutated-release.json"
  RELEASE_RESPONSE=$TMP/mutated-release.json \
    expect_failure "release mutation: $mutation" proof_command
  ! grep -q $'^release\tverify\t' "$GH_LOG"
done

jq '.verificationResult.statement.predicate.databaseId = "121"' \
  "$TMP/attestation.json" >"$TMP/wrong-attestation.json"
ATTESTATION_RESPONSE=$TMP/wrong-attestation.json \
  expect_failure wrong-attestation-release proof_command
! grep -q $'^release\tverify-asset\t' "$GH_LOG"

jq '.verificationResult.signature.certificate.subjectAlternativeName =
      "https://example.invalid"' \
  "$TMP/attestation.json" >"$TMP/wrong-attestation.json"
ATTESTATION_RESPONSE=$TMP/wrong-attestation.json \
  expect_failure wrong-attestation-certificate proof_command
! grep -q $'^release\tverify-asset\t' "$GH_LOG"

FAIL_ATTESTATION=true expect_failure missing-attestation proof_command
! grep -q $'^release\tverify-asset\t' "$GH_LOG"

FAIL_ASSET=image-inspect.txt \
  expect_failure unverified-asset proof_command
[ "$(grep -c $'^release\tverify-asset\t' "$GH_LOG")" -eq 3 ]

cp "$TMP/assets/SHA256SUMS" "$TMP/original-sums"
printf 'tampered checksums\n' >"$TMP/assets/SHA256SUMS"
expect_failure downloaded-digest-mismatch proof_command
! grep -q $'^release\tverify-asset\t' "$GH_LOG"
mv "$TMP/original-sums" "$TMP/assets/SHA256SUMS"

for method in PUT PATCH DELETE; do
  : >"$GH_LOG"
  if (
    # shellcheck source=verify-immutable-release-proof.sh
    source "$VERIFY"
    export GH_COMMAND=gh
    api_request "$method" repos/FixtureOwner/repo/releases/120 \
      "$TMP/forbidden.json"
  ) >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "expected local $method rejection" >&2
    exit 1
  fi
  [ ! -s "$GH_LOG" ] || {
    echo "$method reached GitHub CLI transport" >&2
    exit 1
  }
done

echo "immutable release proof fixtures passed: explicit v1.2.0, same numeric release, immutable API, v0.2 attestation identity/binding, four exact asset invocations, and read-only transport"
