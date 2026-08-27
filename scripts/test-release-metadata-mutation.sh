#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/bin" "$TMP/assets" "$TMP/repo"

repository=FixtureOwner/repo
release_id=120
tag=v1.2.0
version=1.2.0
assets=(release-manifest.json image-index.json image-inspect.txt SHA256SUMS)
printf '## [1.2.0]\n\n- Fixture release.\n' >"$TMP/repo/CHANGELOG.md"
git -C "$TMP/repo" init -q
git -C "$TMP/repo" add CHANGELOG.md
git -C "$TMP/repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -q -m fixture
source_sha=$(git -C "$TMP/repo" rev-parse HEAD)

reset_assets() {
  for asset in "${assets[@]}"; do
    printf 'fixture bytes for %s\n' "$asset" >"$TMP/assets/$asset"
  done
}
reset_release() {
  reset_assets
  jq -n --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" '{
    id:$id,name:$tag,tag_name:$tag,target_commitish:$source,
    draft:true,prerelease:false,immutable:false,published_at:null,assets:[]
  }' >"$TMP/release.json"
  index=1
  for asset in "${assets[@]}"; do
    digest=$(sha256sum "$TMP/assets/$asset" | awk '{print $1}')
    size=$(wc -c <"$TMP/assets/$asset" | tr -d '[:space:]')
    jq --argjson id "$index" --arg name "$asset" --arg digest "sha256:$digest" \
      --argjson size "$size" \
      '.assets += [{id:$id,name:$name,state:"uploaded",digest:$digest,size:$size}]' \
      "$TMP/release.json" >"$TMP/release.tmp"
    mv "$TMP/release.tmp" "$TMP/release.json"
    index=$((index + 1))
  done
  printf '0\n' >"$TMP/get-count"
  : >"$TMP/gh.log"
}

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${GH_FIXTURE_STATE:?}
log=${GH_FIXTURE_LOG:?}
count_file=${GH_FIXTURE_GET_COUNT:?}
assets_dir=${GH_FIXTURE_ASSETS:?}
[ "${1:-}" = api ] || exit 90
shift
if [ "${1:-}" = --method ]; then
  [ "${2:-}" = PATCH ] || exit 91
  [ "${3:-}" = "repos/FixtureOwner/repo/releases/120" ] || exit 92
  [ "${4:-}" = --input ] || exit 93
  [ -s "${5:-}" ] || exit 94
  printf 'patch\n' >>"$log"
  jq '.draft = false | .immutable = false |
      .published_at = "2026-08-26T12:00:00Z"' "$state"
  exit 0
fi
endpoint=${1:-}
case "$endpoint" in
  repos/FixtureOwner/repo/releases/120)
    count=$(cat "$count_file")
    count=$((count + 1))
    printf '%s\n' "$count" >"$count_file"
    printf 'get-release %s\n' "$count" >>"$log"
    if [ "$count" -eq 2 ] && [ -n "${GH_FIXTURE_RACE:-}" ]; then
      case "$GH_FIXTURE_RACE" in
        renamed) jq '.name = "renamed"' "$state" ;;
        immutable) jq '.immutable = true' "$state" ;;
        missing-published) jq 'del(.published_at)' "$state" ;;
        false-published) jq '.published_at = false' "$state" ;;
        draft) jq '.draft = false' "$state" ;;
        tag) jq '.tag_name = "v9.9.9"' "$state" ;;
        source) jq '.target_commitish = "ffffffffffffffffffffffffffffffffffffffff"' "$state" ;;
        duplicate-name) jq '.assets[1].name = .assets[0].name' "$state" ;;
        duplicate-id) jq '.assets[1].id = .assets[0].id' "$state" ;;
        zero-id) jq '.assets[0].id = 0' "$state" ;;
        zero-size) jq '.assets[0].size = 0' "$state" ;;
        bad-state) jq '.assets[0].state = "new"' "$state" ;;
        bad-digest) jq '.assets[0].digest = "sha256:nope"' "$state" ;;
        wrong-digest) jq '.assets[0].digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$state" ;;
        wrong-size) jq '.assets[0].size += 1' "$state" ;;
        array) printf '[]\n' ;;
        *) exit 95 ;;
      esac
    else
      cat "$state"
    fi
    ;;
  repos/FixtureOwner/repo/git/ref/tags/*)
    printf 'tag-ref %s\n' "$endpoint" >>"$log"
    if [ "${GH_FIXTURE_RACE:-}" = local-bytes ] &&
       [ ! -e "$assets_dir/.mutated" ]; then
      printf 'changed after initial validation\n' >>"$assets_dir/release-manifest.json"
      : >"$assets_dir/.mutated"
    fi
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  *) exit 96 ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"enabled":true}\n' >"$output"
printf '200'
EOF
chmod +x "$TMP/bin/gh" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export GH_FIXTURE_STATE="$TMP/release.json"
export GH_FIXTURE_LOG="$TMP/gh.log"
export GH_FIXTURE_GET_COUNT="$TMP/get-count"
export GH_FIXTURE_ASSETS="$TMP/assets"
printf 'fixture-policy-reader-token\n' >"$TMP/policy-token"

publish() {
  "$ROOT_DIR/scripts/mutate-release-metadata.sh" publish \
    --repository "$repository" --release-id "$release_id" \
    --version "$version" --tag "$tag" --source-sha "$source_sha" \
    --assets-dir "$TMP/assets" --policy-token-file "$TMP/policy-token" \
    --repo-dir "$TMP/repo"
}
reject_race() {
  local race=$1
  reset_release
  if GH_FIXTURE_RACE="$race" publish >/dev/null 2>&1; then
    echo "metadata mutation accepted the $race final-boundary race" >&2
    exit 1
  fi
  if grep -Fx patch "$TMP/gh.log" >/dev/null; then
    echo "metadata mutation patched after the $race final-boundary race" >&2
    exit 1
  fi
}

if "$ROOT_DIR/scripts/mutate-release-metadata.sh" canonicalize \
  --repository "$repository" --release-id "$release_id" --version "$version" \
  --tag "$tag" --source-sha "$source_sha" >/dev/null 2>&1; then
  echo "retired metadata operation unexpectedly accepted" >&2
  exit 1
fi
reset_release
if "$ROOT_DIR/scripts/mutate-release-metadata.sh" publish \
  --repository "$repository" --release-id "$release_id" --version "$version" \
  --tag "$tag" --source-sha "$source_sha" --assets-dir "$TMP/assets" \
  --repo-dir "$TMP/repo" >/dev/null 2>&1; then
  echo "publication without the policy reader unexpectedly passed" >&2
  exit 1
fi
reset_release
if "$ROOT_DIR/scripts/mutate-release-metadata.sh" publish \
  --repository "$repository" --release-id "$release_id" --version "$version" \
  --tag "$tag" --source-sha "$source_sha" \
  --policy-token-file "$TMP/policy-token" --repo-dir "$TMP/repo" \
  >/dev/null 2>&1; then
  echo "publication without the asset directory unexpectedly passed" >&2
  exit 1
fi

reset_release
publication=$(publish)
grep -Fx 'mutation=verified' <<<"$publication" >/dev/null
grep -Fx 'operation=publish' <<<"$publication" >/dev/null
[ "$(grep -c '^get-release ' "$TMP/gh.log")" -eq 2 ]
[ "$(grep -c '^patch$' "$TMP/gh.log")" -eq 1 ]
[ "$(tail -n 2 "$TMP/gh.log")" = $'get-release 2\npatch' ] || {
  echo "final release binding was not immediately before PATCH" >&2
  exit 1
}

reject_race renamed
reject_race immutable
reject_race missing-published
reject_race false-published
reject_race draft
reject_race tag
reject_race source
reject_race duplicate-name
reject_race duplicate-id
reject_race zero-id
reject_race zero-size
reject_race bad-state
reject_race bad-digest
reject_race wrong-digest
reject_race wrong-size
reject_race array
reject_race local-bytes

reset_release
printf 'unexpected\n' >"$TMP/assets/extra.txt"
if publish >/dev/null 2>&1; then
  echo "metadata mutation accepted more than four local assets" >&2
  exit 1
fi
[ ! -s "$TMP/gh.log" ]
reset_release
: >"$TMP/assets/SHA256SUMS"
if publish >/dev/null 2>&1; then
  echo "metadata mutation accepted an empty local asset" >&2
  exit 1
fi
[ ! -s "$TMP/gh.log" ]

echo "publish-only metadata mutation fixtures passed: final asset binding and race rejection"
