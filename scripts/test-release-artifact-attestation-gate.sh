#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/release-please.yml
workflow=$(sed 's/\r$//' "$WORKFLOW")
line_of() {
  grep -nF "$1" "$WORKFLOW" | head -1 | cut -d: -f1
}

create_line=$(line_of 'actions/attest-build-provenance@')
verify_line=$(line_of 'gh attestation verify "$ARTIFACT"')
push_line=$(line_of 'docker buildx build --platform linux/amd64')
publish_line=$(line_of 'scripts/mutate-release-metadata.sh publish')

[ -n "$create_line" ] && [ -n "$verify_line" ] &&
  [ -n "$push_line" ] && [ -n "$publish_line" ]
[ "$push_line" -lt "$create_line" ]
[ "$create_line" -lt "$verify_line" ]
[ "$verify_line" -lt "$publish_line" ]
grep -Fq 'attestations: write' <<<"$workflow"
grep -Fq 'subject-path: ${{ runner.temp }}/release-assets/image-index.json' <<<"$workflow"
grep -Fq -- '--predicate-type https://slsa.dev/provenance/v1' <<<"$workflow"
grep -Fq -- '--signer-workflow "github.com/$GITHUB_REPOSITORY/.github/workflows/release-please.yml"' \
  <<<"$workflow"
grep -Fq 'echo "verified=true" >>"$GITHUB_OUTPUT"' <<<"$workflow"
grep -Fq -- '--argjson artifact_attestation "${{ steps.verify_artifact_attestation.outputs.verified }}"' \
  <<<"$workflow"
! grep -Fq 'artifactAttestation:true' <<<"$workflow"
echo "workflow artifact-attestation create/verify gate fixture passed"
