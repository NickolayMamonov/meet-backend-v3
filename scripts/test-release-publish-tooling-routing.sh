#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
publish=$(sed -n '/^  publish:/,$p' .github/workflows/release-please.yml)
tooling=$(awk '
  /^      - name: Checkout reviewed publication tooling$/ { in_step=1 }
  in_step && /^      - name: / &&
    $0 !~ /Checkout reviewed publication tooling$/ { exit }
  in_step { print }
' <<<"$publish")
source_checkout=$(awk '
  /^      - name: Checkout exact publication source$/ { in_step=1 }
  in_step && /^      - name: / &&
    $0 !~ /Checkout exact publication source$/ { exit }
  in_step { print }
' <<<"$publish")
build=$(awk '
  /^      - name: Build exact image$/ { in_step=1 }
  in_step && /^      - name: / && $0 !~ /Build exact image$/ { exit }
  in_step { print }
' <<<"$publish")

grep -Fq 'ref: ${{ github.sha }}' <<<"$tooling"
if grep -Fq 'path:' <<<"$tooling"; then
  echo "reviewed publication tooling must own the workspace root" >&2
  exit 1
fi
grep -Fq 'ref: ${{ needs.controller.outputs.source_sha }}' <<<"$source_checkout"
grep -Fq 'path: source' <<<"$source_checkout"
grep -Fq -- '--build-arg "BACKEND_REVISION=$SOURCE_SHA" source' <<<"$build"

echo "release publication tooling-routing fixture passed"
