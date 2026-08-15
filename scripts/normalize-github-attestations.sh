#!/usr/bin/env bash
set -euo pipefail

fail() { echo "GitHub attestation normalization failed: $*" >&2; exit 1; }

input=
subject_digest=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) input=${2:?}; shift 2 ;;
    --subject-digest) subject_digest=${2:?}; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done

[ -f "$input" ] || fail "input is missing"
[[ "$subject_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "subject digest is invalid"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v base64 >/dev/null 2>&1 || fail "base64 is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
jq -e '.attestations | type == "array"' "$input" >/dev/null ||
  fail "attestation API response is malformed"

work_dir=$(mktemp -d)
trap 'rm -r -- "$work_dir"' EXIT HUP INT TERM
records=$work_dir/records.jsonl
: >"$records"
subject_hex=${subject_digest#sha256:}
count=$(jq -r '.attestations | length' "$input")

for ((index = 0; index < count; index++)); do
  bundle=$work_dir/bundle-$index.json
  statement=$work_dir/statement-$index.json
  jq -cS ".attestations[$index].bundle" "$input" >"$bundle" ||
    fail "bundle $index cannot be read"
  jq -e '
    type == "object" and
    (.mediaType | type == "string" and length > 0) and
    (.dsseEnvelope | type == "object") and
    (.dsseEnvelope.payload | type == "string" and length > 0)
  ' "$bundle" >/dev/null || fail "bundle $index is malformed"
  jq -rj '.dsseEnvelope.payload' "$bundle" |
    base64 --decode >"$statement" 2>/dev/null ||
    fail "bundle $index payload is not valid base64"
  jq -e \
    --arg subject "$subject_hex" '
    type == "object" and
    ._type == "https://in-toto.io/Statement/v1" and
    (.predicateType | type == "string" and length > 0) and
    (
      [.subject[]? | select(.digest.sha256? == $subject)] |
      length == 1
    ) and (
      .predicate.buildDefinition.externalParameters.workflow as $workflow |
      ($workflow.repository |
        type == "string" and startswith("https://github.com/")) and
      ($workflow.ref | type == "string" and startswith("refs/")) and
      (
        [
          .predicate.buildDefinition.resolvedDependencies[]? |
          select(.uri? == ("git+" + $workflow.repository + "@" + $workflow.ref)) |
          select(.digest.gitCommit? |
            type == "string" and test("^[0-9a-f]{40}$"))
        ] |
        length == 1
      ) and
      (.predicate.runDetails.builder.id |
        type == "string" and
        startswith($workflow.repository + "/.github/workflows/") and
        endswith("@" + $workflow.ref))
    )
  ' "$statement" >/dev/null ||
    fail "bundle $index claims are malformed or bind another subject"

  bundle_sha=$(jq -cS . "$bundle" | tr -d '\r\n' |
    sha256sum | awk '{print $1}')
  predicate_type=$(jq -r '.predicateType' "$statement")
  source_repository=$(
    jq -r '.predicate.buildDefinition.externalParameters.workflow.repository' \
      "$statement"
  )
  workflow_ref=$(
    jq -r '.predicate.buildDefinition.externalParameters.workflow.ref' \
      "$statement"
  )
  source_digest=$(
    jq -r '
      .predicate.buildDefinition.externalParameters.workflow as $workflow |
        [
          .predicate.buildDefinition.resolvedDependencies[]? |
          select(.uri? == ("git+" + $workflow.repository + "@" + $workflow.ref)) |
          select(.digest.gitCommit? |
            type == "string" and test("^[0-9a-f]{40}$"))
        ][0].digest.gitCommit
    ' "$statement"
  )
  signer_workflow=$(jq -r '.predicate.runDetails.builder.id' "$statement")

  jq -cn \
    --arg subjectDigest "$subject_digest" \
    --arg predicateType "$predicate_type" \
    --arg sourceRepository "$source_repository" \
    --arg sourceDigest "$source_digest" \
    --arg workflowRef "$workflow_ref" \
    --arg signerWorkflow "$signer_workflow" \
    --arg bundleDigest "sha256:$bundle_sha" '
    {
      subjectDigest:$subjectDigest,
      predicateType:$predicateType,
      sourceRepository:$sourceRepository,
      sourceDigest:$sourceDigest,
      workflowRef:$workflowRef,
      signerWorkflow:$signerWorkflow,
      bundleDigest:$bundleDigest
    }
  ' >>"$records"
done

jq -cS -s '
  sort_by(.predicateType,.bundleDigest) |
  if (map(.bundleDigest) | unique | length) == length
  then .
  else error("duplicate attestation bundle digest")
  end
' "$records"
