#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
NORMALIZER=$ROOT_DIR/scripts/normalize-github-attestations.sh
[ -x "$NORMALIZER" ] ||
  { echo "GitHub attestation normalizer is not executable" >&2; exit 1; }
capture=$(sed 's/\r$//' "$ROOT_DIR/scripts/capture-protected-release-snapshot.sh")
snapshot_object=$(sed -n '/^snapshot_object()/,/^}/p' <<<"$capture")
grep -Fq '  jq -n -cS \' <<<"$snapshot_object" ||
  { echo "protected snapshot object construction waits for stdin" >&2; exit 1; }
grep -Fq -- '--slurpfile blocked "$blocked_object"' <<<"$capture" ||
  { echo "protected snapshot assembly does not read the blocked object from a file" >&2; exit 1; }
grep -Fq -- '--slurpfile immutable "$immutable_object"' <<<"$capture" ||
  { echo "protected snapshot assembly does not read the immutable object from a file" >&2; exit 1; }
if grep -Fq -- '--argjson blocked "$blocked_object"' <<<"$capture" ||
   grep -Fq -- '--argjson immutable "$immutable_object"' <<<"$capture"; then
  echo "protected snapshot assembly passes complete JSON objects through argv" >&2
  exit 1
fi

subject=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
source=0123456789abcdef0123456789abcdef01234567
jq -n \
  --arg subject "$subject" \
  --arg source "$source" '
  {
    _type:"https://in-toto.io/Statement/v1",
    subject:[{name:"ghcr.io/example/image",digest:{sha256:$subject}}],
    predicateType:"https://slsa.dev/provenance/v1",
    predicate:{
      buildDefinition:{
        externalParameters:{
          workflow:{
            repository:"https://github.com/example/repository",
            ref:"refs/heads/dev",
            path:".github/workflows/release.yml"
          }
        },
        resolvedDependencies:[
          {
            uri:"git+https://github.com/example/repository@refs/heads/dev",
            digest:{gitCommit:$source}
          }
        ]
      },
      runDetails:{
        builder:{
          id:"https://github.com/example/repository/.github/workflows/release.yml@refs/heads/dev"
        }
      }
    }
  }
' >"$TMP/statement.json"
payload=$(base64 <"$TMP/statement.json" | tr -d '\r\n')
jq -n --arg payload "$payload" '
  {
    attestations:[
      {
        bundle:{
          mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",
          dsseEnvelope:{
            payload:$payload,
            payloadType:"application/vnd.in-toto+json",
            signatures:[{sig:"fixture-signature"}]
          },
          verificationMaterial:{fixture:true}
        }
      }
    ]
  }
' >"$TMP/attestations.json"
"$NORMALIZER" \
  --input "$TMP/attestations.json" \
  --subject-digest "sha256:$subject" >"$TMP/normalized-attestations.json"
jq -e \
  --arg subject "sha256:$subject" \
  --arg source "$source" '
  length == 1 and
  .[0].subjectDigest == $subject and
  .[0].predicateType == "https://slsa.dev/provenance/v1" and
  .[0].sourceRepository == "https://github.com/example/repository" and
  .[0].sourceDigest == $source and
  .[0].workflowRef == "refs/heads/dev" and
  .[0].signerWorkflow ==
    "https://github.com/example/repository/.github/workflows/release.yml@refs/heads/dev" and
  (.[0].bundleDigest | test("^sha256:[0-9a-f]{64}$"))
' "$TMP/normalized-attestations.json" >/dev/null ||
  { echo "GitHub attestation normalization fixture failed" >&2; exit 1; }
"$NORMALIZER" \
  --input "$TMP/attestations.json" \
  --subject-digest "sha256:$subject" >"$TMP/normalized-attestations-repeat.json"
cmp --silent "$TMP/normalized-attestations.json" \
  "$TMP/normalized-attestations-repeat.json" ||
  { echo "GitHub attestation normalization is not deterministic" >&2; exit 1; }
if "$NORMALIZER" \
  --input "$TMP/attestations.json" \
  --subject-digest \
    sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  >/dev/null 2>&1; then
  echo "GitHub attestation normalizer accepted another subject" >&2
  exit 1
fi

cp "$ROOT_DIR/docs/evidence/MEE2-48-protected-history-v1.json" \
  "$TMP/snapshot.json"
"$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
  --snapshot "$TMP/snapshot.json"
if jq '.objects.blockedV1_1_0.release.draft = false' \
  "$TMP/snapshot.json" >"$TMP/drift.json" &&
  "$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
    --snapshot "$TMP/drift.json"; then
  echo "protected snapshot drift was incorrectly accepted" >&2
  exit 1
fi
if jq '.objects.blockedV1_1_0.githubAttestations[0].sourceDigest = "invalid"' \
  "$TMP/snapshot.json" >"$TMP/drift.json" &&
  "$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
    --snapshot "$TMP/drift.json"; then
  echo "malformed protected attestation was incorrectly accepted" >&2
  exit 1
fi

drift_filters=(
  '.objects.blockedV1_1_0.release.immutable = true'
  '.objects.blockedV1_1_0.release.bodySha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.assets[0].label = "drift"'
  '.objects.blockedV1_1_0.assets[0].apiDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.gitRef.state = "present"'
  '.objects.blockedV1_1_0.registry.protectedAliasBindings.latest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.registry.subjectDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.registry.versions = [{id:1,digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",tags:["v1.1.0"]}]'
  '.objects.blockedV1_1_0.registry.referrers = [{digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",mediaType:"application/json",size:1,subjectDigest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",artifactType:null,predicateTypes:[],rawManifestSha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
  '.objects.blockedV1_1_0.githubAttestations = [{predicateType:"fixture",bundleDigest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
)
for filter in "${drift_filters[@]}"; do
  jq "$filter" "$TMP/snapshot.json" >"$TMP/drift.json"
  if cmp --silent "$TMP/snapshot.json" "$TMP/drift.json"; then
    echo "protected snapshot drift matrix failed to change bytes: $filter" >&2
    exit 1
  fi
done
echo "protected snapshot fixtures passed"
