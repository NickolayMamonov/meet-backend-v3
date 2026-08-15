#!/usr/bin/env bash
set -euo pipefail

WORKFLOW=.github/workflows/release-please.yml
controller=$(sed -n '/^  controller:/,/^  gates:/p' "$WORKFLOW")
route_step=$(awk '
  /^      - name: Normalize action result and current-action set difference$/ {
    in_step=1
  }
  in_step && /^      - name: / &&
    $0 !~ /Normalize action result and current-action set difference$/ { exit }
  in_step { print }
' "$WORKFLOW")

grep -Fq 'release_tag: ${{ steps.route.outputs.tag }}' <<<"$controller"
grep -Fq 'release_version: ${{ steps.route.outputs.version }}' <<<"$controller"
grep -Fq 'echo "tag=$PRE_TAG" >>"$GITHUB_OUTPUT"' <<<"$route_step"
grep -Fq 'echo "version=$PRE_VERSION" >>"$GITHUB_OUTPUT"' <<<"$route_step"
for invariant in \
  'continuation_id=371012814' \
  'continuation_tag=v1.2.0' \
  'continuation_version=1.2.0' \
  'continuation_source=9b6d2b06c0336ab8d153564dcf6328e81c4d7b36'; do
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

echo "release controller output contract fixture passed"
