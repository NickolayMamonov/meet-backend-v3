#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT
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
publication_checkpoint=$(awk '
  /^      - name: Verify canonical publication tuple$/ { in_step=1 }
  in_step && /^      - name: / &&
    $0 !~ /Verify canonical publication tuple$/ { exit }
  in_step && /^        run: \|$/ { in_run=1; next }
  in_run && /^          / { sub(/^          /, ""); print }
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

MOCK_HEAD=$(command git rev-parse HEAD)
git() {
  case "$*" in
    'rev-parse HEAD') printf '%s\n' "$MOCK_HEAD" ;;
    'merge-base --is-ancestor 9362e47e64c402d7eb38fd2c7e0420e7b01e78a0 HEAD') return 0 ;;
    'ls-remote origin refs/heads/dev')
      printf '%s\trefs/heads/dev\n' "$MOCK_CURRENT_DEV"
      ;;
    *) echo "unexpected git invocation in publication checkpoint: $*" >&2; return 97 ;;
  esac
}
export -f git
run_publication_checkpoint() {
  local attempt=$1 current_dev=$2 writer_sentinel=$3
  env GITHUB_REPOSITORY=NickolayMamonov/meet-backend-v3 \
    GITHUB_EVENT_NAME=push GITHUB_REF=refs/heads/dev \
    GITHUB_RUN_ATTEMPT="$attempt" \
    GITHUB_EVENT_BEFORE=9362e47e64c402d7eb38fd2c7e0420e7b01e78a0 \
    GITHUB_EVENT_AFTER="$MOCK_HEAD" GITHUB_SHA="$MOCK_HEAD" \
    RELEASE_ID=432691220 TAG=v1.7.0 VERSION=1.7.0 \
    SOURCE_SHA=9362e47e64c402d7eb38fd2c7e0420e7b01e78a0 \
    MOCK_HEAD="$MOCK_HEAD" MOCK_CURRENT_DEV="$current_dev" \
    WRITER_SENTINEL="$writer_sentinel" \
    bash -c "$publication_checkpoint"$'\n''touch "$WRITER_SENTINEL"'
}
same_dev_sentinel=$TMP/publication-writer-ran
run_publication_checkpoint 1 "$MOCK_HEAD" "$same_dev_sentinel"
[ -f "$same_dev_sentinel" ] || {
  echo "exact tuple/attempt-1/current-dev publication control was rejected" >&2
  exit 1
}
blocked_sentinel=$TMP/attempt-2-writer-ran
if run_publication_checkpoint 2 "$MOCK_HEAD" "$blocked_sentinel" \
  >/dev/null 2>&1; then
  echo "publication checkpoint admitted attempt 2" >&2
  exit 1
fi
[ ! -e "$blocked_sentinel" ] || {
  echo "publication writer ran after attempt-2 guard rejection" >&2
  exit 1
}
for drift_kind in unchanged-version advanced-version; do
  blocked_sentinel=$TMP/$drift_kind-writer-ran
  if [ "$drift_kind" = unchanged-version ]; then
    drift_sha=1111111111111111111111111111111111111111
  else
    drift_sha=2222222222222222222222222222222222222222
  fi
  if run_publication_checkpoint 1 \
    "$drift_sha" "$blocked_sentinel" \
    >/dev/null 2>&1; then
    echo "publication checkpoint admitted current-dev drift ($drift_kind)" >&2
    exit 1
  fi
  [ ! -e "$blocked_sentinel" ] || {
    echo "publication writer ran after current-dev drift ($drift_kind)" >&2
    exit 1
  }
done

echo "release publication tooling-routing fixture passed"
