#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/bin" "$TMP/assets"

repository=FixtureOwner/repo
release_id=120
tag=v1.2.0
version=1.2.0
source_sha=0123456789abcdef0123456789abcdef01234567
jq -n --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" '{
  id:$id,tag_name:$tag,target_commitish:$source,draft:true,prerelease:false,
  published_at:null,assets:[]
}' >"$TMP/release.json"
for asset in release-manifest.json image-index.json image-inspect.txt SHA256SUMS; do
  printf '%s\n' "$asset" >"$TMP/assets/$asset"
done

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${GH_FIXTURE_STATE:?}
log=${GH_FIXTURE_LOG:?}
case "${1:-}" in
  api)
    [ "${2:-}" = "repos/FixtureOwner/repo/releases/120" ] || exit 91
    cat "$state"
    ;;
  release)
    [ "${2:-}" = upload ] || exit 92
    tag=${3:?}
    file=${4:?}
    repository=
    [ "${5:-}" = --repo ] || exit 95
    repository=${6:?}
    printf 'upload %s %s %s\n' "$tag" "$file" "$repository" >>"$log"
    [ "$tag" = v1.2.0 ] || exit 93
    [ "$repository" = FixtureOwner/repo ] || exit 94
    digest=$(sha256sum "$file" | awk '{print $1}')
    name=$(basename "$file")
    jq --arg name "$name" --arg digest "sha256:$digest" \
      '.assets += [{id:((.assets | length) + 1),name:$name,state:"uploaded",digest:$digest}]' \
      "$state" >"$state.tmp"
    mv "$state.tmp" "$state"
    ;;
  *) exit 95 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_FIXTURE_STATE="$TMP/release.json"
export GH_FIXTURE_LOG="$TMP/gh.log"

"$ROOT_DIR/scripts/upload-release-assets.sh" \
  --repository "$repository" --release-id "$release_id" \
  --tag "$tag" --version "$version" --source-sha "$source_sha" \
  --assets-dir "$TMP/assets"

[ "$(wc -l <"$TMP/gh.log" | tr -d '[:space:]')" -eq 4 ]
grep -Fx "upload $tag $TMP/assets/release-manifest.json $repository" "$TMP/gh.log" >/dev/null
grep -Fx "upload $tag $TMP/assets/image-index.json $repository" "$TMP/gh.log" >/dev/null
grep -Fx "upload $tag $TMP/assets/image-inspect.txt $repository" "$TMP/gh.log" >/dev/null
grep -Fx "upload $tag $TMP/assets/SHA256SUMS $repository" "$TMP/gh.log" >/dev/null
! grep -Fq "upload $release_id " "$TMP/gh.log"
echo "release asset upload fixtures passed: exact tag target and create-only prefix"
