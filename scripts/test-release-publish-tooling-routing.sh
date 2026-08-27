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
pre_push_revalidation=$(awk '
  /^      - name: Revalidate live empty draft before first image push$/ {
    in_step=1
  }
  in_step && /^      - name: / &&
    $0 !~ /Revalidate live empty draft before first image push$/ { exit }
  in_step { print }
' <<<"$publish")
build=$(awk '
  /^      - name: Build exact image$/ { in_step=1 }
  in_step && /^      - name: / && $0 !~ /Build exact image$/ { exit }
  in_step { print }
' <<<"$publish")
manifest=$(awk '
  /^      - name: Generate deterministic release manifest$/ { in_step=1 }
  in_step && /^      - name: / &&
    $0 !~ /Generate deterministic release manifest$/ { exit }
  in_step { print }
' <<<"$publish")

grep -Fq 'ref: ${{ github.sha }}' <<<"$tooling"
if grep -Fq 'path:' <<<"$tooling"; then
  echo "reviewed publication tooling must own the workspace root" >&2
  exit 1
fi
grep -Fq 'ref: ${{ needs.controller.outputs.source_sha }}' <<<"$source_checkout"
grep -Fq 'path: source' <<<"$source_checkout"
grep -Fq 'scripts/revalidate-release-mutation.sh \' <<<"$pre_push_revalidation"
grep -Fq 'scripts/verify-release-tag-ref.sh \' <<<"$pre_push_revalidation"
grep -Fq -- '--repository "$GITHUB_REPOSITORY" --tag "$TAG" \' \
  <<<"$pre_push_revalidation"
grep -Fq -- '--source-sha "$SOURCE_SHA" --expect-absent' \
  <<<"$pre_push_revalidation"
revalidate_line=$(grep -n 'scripts/revalidate-release-mutation.sh' \
  <<<"$pre_push_revalidation" | cut -d: -f1)
tag_ref_line=$(grep -n 'scripts/verify-release-tag-ref.sh' \
  <<<"$pre_push_revalidation" | cut -d: -f1)
[ "$revalidate_line" -lt "$tag_ref_line" ] || {
  echo "exact release revalidation must precede absent tag-ref verification" >&2
  exit 1
}
last_command=$(awk '
  substr($0, 1, 10) == "          " && substr($0, 11, 1) != " " {
    command=substr($0, 11)
  }
  END { print command }
' <<<"$pre_push_revalidation")
[ "$last_command" = 'scripts/verify-release-tag-ref.sh \' ] || {
  echo "absent tag-ref verification must be the final pre-push command" >&2
  exit 1
}
grep -Fq -- '--build-arg "BACKEND_REVISION=$SOURCE_SHA" source' <<<"$build"
grep -Fq \
  'uses: docker/setup-buildx-action@e468171a9de216ec08956ac3ada2f0791b6bd435' \
  <<<"$publish"
buildx_line=$(grep -n 'name: Set up attestation-capable Buildx' <<<"$publish" |
  cut -d: -f1)
build_line=$(grep -n 'name: Build exact image' <<<"$publish" | cut -d: -f1)
[ "$buildx_line" -lt "$build_line" ] || {
  echo "attestation-capable Buildx must be configured before image build" >&2
  exit 1
}
pre_push_line=$(grep -n \
  'name: Revalidate live empty draft before first image push' <<<"$publish" |
  cut -d: -f1)
[ "$pre_push_line" -lt "$build_line" ] || {
  echo "live empty-draft revalidation must precede image build" >&2
  exit 1
}
between_steps=$(sed -n "$((pre_push_line + 1)),$((build_line - 1))p" <<<"$publish")
if grep -q '^      - name:' <<<"$between_steps"; then
  echo "image build must immediately follow live empty-draft revalidation" >&2
  exit 1
fi
normalizer_count=$(grep -c \
  'scripts/normalize-release-pages.sh >"\$releases_' \
  .github/workflows/release-please.yml)
[ "$normalizer_count" -eq 3 ] || {
  echo "all three paginated release lists must use the release-page normalizer" >&2
  exit 1
}
if grep -Fq "jq -c 'add // []'" .github/workflows/release-please.yml; then
  echo "workflow must not flatten paginated release lists with jq add" >&2
  exit 1
fi
grep -Fq 'cd "$RUNNER_TEMP/release-assets"' <<<"$manifest"
grep -Fq \
  'sha256sum release-manifest.json image-index.json image-inspect.txt \' \
  <<<"$manifest"
grep -Fq '>SHA256SUMS' <<<"$manifest"
grep -Fq 'sha256sum -c SHA256SUMS >/dev/null' <<<"$manifest"
if grep -Fq 'sed "s#  $RUNNER_TEMP/release-assets/##"' <<<"$manifest"; then
  echo "release checksums must be generated from inside the asset directory" >&2
  exit 1
fi

echo "release publication tooling-routing fixture passed"
