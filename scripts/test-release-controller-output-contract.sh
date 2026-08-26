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

grep -Fq 'continuation_state=' <<<"$workflow"
grep -Fq 'then "pending"' <<<"$workflow"
grep -Fq 'then "published"' <<<"$workflow"
grep -Fq 'else "invalid"' <<<"$workflow"
grep -Fq '.immutable == false' <<<"$workflow"
grep -Fq '.immutable == true' <<<"$workflow"
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
grep -Fq '(.assets | type == "array" and length == 4)' <<<"$workflow"
grep -Fq '[.assets[].name] | sort' <<<"$workflow"
grep -Fq '["SHA256SUMS","image-index.json","image-inspect.txt","release-manifest.json"]' <<<"$workflow"
grep -Fq '[.assets[].name] | unique | length) == 4' <<<"$workflow"
grep -Fq '.name == $tag' <<<"$workflow"
echo "release controller output contract fixture passed"
