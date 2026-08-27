#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
WORKFLOW=.github/workflows/release-please.yml
workflow=$(sed -n '1,$p' "$WORKFLOW")
controller=$(sed -n '/^  controller:/,/^  gates:/p' "$WORKFLOW")
route_step=$(awk '
  /^      - name: Normalize action result and current-action set difference$/ {
    in_step=1
  }
  in_step && /^      - name: / &&
    $0 !~ /Normalize action result and current-action set difference$/ { exit }
  in_step { print }
' "$WORKFLOW")
pre_action_step=$(awk '
  /^      - name: Classify current action before Release Please$/ {
    in_step=1
  }
  in_step && /^      - name: / &&
    $0 !~ /Classify current action before Release Please$/ { exit }
  in_step { print }
' "$WORKFLOW")

grep -Fq 'release_tag: ${{ steps.route.outputs.tag }}' <<<"$controller"
grep -Fq 'release_version: ${{ steps.route.outputs.version }}' <<<"$controller"
grep -Fq 'echo "tag=$PRE_TAG" >>"$GITHUB_OUTPUT"' <<<"$route_step"
grep -Fq 'echo "version=$PRE_VERSION" >>"$GITHUB_OUTPUT"' <<<"$route_step"
for invariant in \
  'continuation_id=377201468' \
  'continuation_tag=v1.3.0' \
  'continuation_version=1.3.0' \
  'continuation_source=a7abfe04f6852f479291a4710ebdee23e9ae8a34'; do
  grep -Fq "$invariant" <<<"$controller"
done
continuation_call=$(awk '
  /descriptor=\$\(scripts\/admit-empty-release-continuation.sh/ { in_call=1 }
  in_call { print }
  in_call && /--registry-state-file/ { exit }
' <<<"$controller")
if grep -Fq -- '--refs-file' <<<"$continuation_call"; then
  echo "live continuation must not use fixture-only authority" >&2
  exit 1
fi
if grep -Fq 'steps.route.outputs.release_tag' <<<"$controller" ||
   grep -Fq 'steps.route.outputs.release_version' <<<"$controller" ||
   grep -Fq 'echo "release_tag=' <<<"$route_step" ||
   grep -Fq 'echo "release_version=' <<<"$route_step"; then
  echo "controller mixes descriptor and downstream release output names" >&2
  exit 1
fi

classifier_call=$(awk '
  /continuation_state=\$\(scripts\/classify-release-continuation.sh/ { in_call=1 }
  in_call { print }
  in_call && /--releases-file/ { exit }
' <<<"$pre_action_step")
[ "$(grep -Fc 'scripts/classify-release-continuation.sh' <<<"$pre_action_step")" -eq 1 ]
for classifier_arg in \
  '--release-id "$continuation_id"' \
  '--tag "$continuation_tag"' \
  '--source-sha "$continuation_source"' \
  '--releases-file "$releases_before"'; do
  grep -Fq -- "$classifier_arg" <<<"$classifier_call"
done
classification_setup=$(sed -n \
  '/releases_before=.*release-relevant-before/,/case "$continuation_state" in/p' \
  <<<"$pre_action_step")
grep -Fq 'scripts/classify-release-continuation.sh' <<<"$classification_setup"
grep -Fq 'case "$continuation_state" in' <<<"$pre_action_step"
if grep -Eq '^[[:space:]]+(if|elif|while|until)[[:space:]]' \
     <<<"$classification_setup"; then
  echo "continuation classifier call must be unconditional" >&2
  exit 1
fi
if [ "$(grep -Fc 'jq ' <<<"$pre_action_step")" -ne 1 ] ||
   grep -Fq 'continuation_count' <<<"$pre_action_step" ||
   grep -Fq -- '--argjson id' <<<"$pre_action_step"; then
  echo "controller contains manual continuation jq/count state logic" >&2
  exit 1
fi
grep -Fq 'continuation classifier returned an invalid state' <<<"$pre_action_step"
if grep -Fq 'then "pending"' <<<"$pre_action_step" ||
   grep -Fq 'then "published"' <<<"$pre_action_step" ||
   grep -Fq '.immutable ==' <<<"$pre_action_step"; then
  echo "controller duplicates continuation classifier state logic" >&2
  exit 1
fi
pending_route=$(sed -n '/^            pending)/,/^            published|absent)/p' \
  <<<"$pre_action_step")
normal_route=$(sed -n '/^            published|absent)/,/^            \*)/p' \
  <<<"$pre_action_step")
wildcard_route=$(sed -n '/^            \*)/,/^          esac/p' \
  <<<"$pre_action_step")
grep -Fq 'scripts/release-registry-state.sh inspect' <<<"$pending_route"
grep -Fq 'scripts/admit-empty-release-continuation.sh' <<<"$pending_route"
grep -Fq 'scripts/resolve-release-descriptor.sh pre-action' <<<"$normal_route"
if grep -Fq 'scripts/resolve-release-descriptor.sh pre-action' <<<"$pending_route" ||
   grep -Fq 'scripts/release-registry-state.sh inspect' <<<"$normal_route" ||
   grep -Fq 'scripts/admit-empty-release-continuation.sh' <<<"$normal_route"; then
  echo "continuation state routes overlap" >&2
  exit 1
fi
grep -Fq 'continuation classifier returned an invalid state' <<<"$wildcard_route"
grep -Fq 'exit 1' <<<"$wildcard_route"
grep -Fq -- '--assets-dir "$RUNNER_TEMP/release-assets"' \
  <<<"$(sed -n '/scripts\/mutate-release-metadata.sh publish/,+8p' "$WORKFLOW")"
publication_step=$(sed -n '/Verify canonical publication tuple/,/Enforce protected history before publication writers/p' "$WORKFLOW")
grep -Fq '$VERSION" =~ ^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$' <<<"$publication_step"
grep -Fq 'test "$TAG" = "v$VERSION"' <<<"$publication_step"
grep -Fq '[[ "$RELEASE_ID" =~ ^[1-9][0-9]*$ ]]' <<<"$publication_step"
grep -Fq '[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]' <<<"$publication_step"
if grep -Fq 'v1.2.0' <<<"$publication_step"; then
  echo "publication tuple remains v1.2.0-specific" >&2
  exit 1
fi
grep -Fq 'MEE2-48-${TAG}-immutability-proof.json' <<<"$workflow"
grep -Fq 'MEE2-48-${{ env.TAG }}-immutability-proof' <<<"$workflow"
echo "release controller output contract fixture passed"
