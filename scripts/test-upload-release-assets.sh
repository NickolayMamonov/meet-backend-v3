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
assets=(release-manifest.json image-index.json image-inspect.txt SHA256SUMS)
for asset in "${assets[@]}"; do
  printf 'fixture bytes for %s\n' "$asset" >"$TMP/assets/$asset"
done

reset_release() {
  jq -n --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" '{
    id:$id,name:$tag,tag_name:$tag,target_commitish:$source,
    draft:true,prerelease:false,immutable:false,published_at:null,assets:[]
  }' >"$TMP/release.json"
  : >"$TMP/gh.log"
}

cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${GH_FIXTURE_STATE:?}
log=${GH_FIXTURE_LOG:?}
case "${1:-}" in
  api)
    [ "${2:-}" = "repos/FixtureOwner/repo/releases/120" ] || exit 91
    phase=$(jq '.assets | length' "$state")
    if [ "${GH_FIXTURE_RACE:-}" != "" ] &&
       [ "$phase" -eq "${GH_FIXTURE_RACE_PHASE:-1}" ]; then
      case "$GH_FIXTURE_RACE" in
        renamed) jq '.name = "renamed"' "$state" ;;
        immutable) jq '.immutable = true' "$state" ;;
        missing-published) jq 'del(.published_at)' "$state" ;;
        false-published) jq '.published_at = false' "$state" ;;
        draft) jq '.draft = false' "$state" ;;
        tag) jq '.tag_name = "v9.9.9"' "$state" ;;
        source) jq '.target_commitish = "ffffffffffffffffffffffffffffffffffffffff"' "$state" ;;
        bad-id) jq '.assets[0].id = 0' "$state" ;;
        bad-size) jq '.assets[0].size = 0' "$state" ;;
        bad-state) jq '.assets[0].state = "new"' "$state" ;;
        bad-digest) jq '.assets[0].digest = "sha256:nope"' "$state" ;;
        duplicate-id) jq '.assets[1].id = .assets[0].id' "$state" ;;
        duplicate-name) jq '.assets[1].name = .assets[0].name' "$state" ;;
        *) exit 96 ;;
      esac
    else
      cat "$state"
    fi
    ;;
  release)
    [ "${2:-}" = upload ] || exit 92
    tag=${3:?}
    file=${4:?}
    [ "${5:-}" = --repo ] || exit 95
    repository=${6:?}
    printf 'upload %s %s %s\n' "$tag" "$file" "$repository" >>"$log"
    [ "$tag" = v1.2.0 ] || exit 93
    [ "$repository" = FixtureOwner/repo ] || exit 94
    digest=$(sha256sum "$file" | awk '{print $1}')
    size=$(wc -c <"$file" | tr -d '[:space:]')
    name=$(basename "$file")
    jq --arg name "$name" --arg digest "sha256:$digest" --argjson size "$size" '
      .assets += [{
        id:((.assets | length) + 1),name:$name,state:"uploaded",
        digest:$digest,size:$size
      }]
    ' "$state" >"$state.tmp"
    mv "$state.tmp" "$state"
    ;;
  *) exit 95 ;;
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
printf 'fixture-policy-reader-token\n' >"$TMP/policy-token"

upload_assets() {
  "$ROOT_DIR/scripts/upload-release-assets.sh" \
    --repository "$repository" --release-id "$release_id" \
    --tag "$tag" --version "$version" --source-sha "$source_sha" \
    --assets-dir "$TMP/assets" --policy-token-file "$TMP/policy-token"
}
reject_race() {
  local race=$1 phase=${2:-1} expected_uploads=${3:-1}
  reset_release
  if GH_FIXTURE_RACE="$race" GH_FIXTURE_RACE_PHASE="$phase" \
    upload_assets >/dev/null 2>&1; then
    echo "asset upload accepted the $race writer-boundary race" >&2
    exit 1
  fi
  [ "$(wc -l <"$TMP/gh.log" | tr -d '[:space:]')" -eq "$expected_uploads" ] || {
    echo "asset upload crossed the $race writer boundary" >&2
    exit 1
  }
}

reset_release
if "$ROOT_DIR/scripts/upload-release-assets.sh" \
  --repository "$repository" --release-id "$release_id" \
  --tag "$tag" --version "$version" --source-sha "$source_sha" \
  --assets-dir "$TMP/assets" >/dev/null 2>&1; then
  echo "asset upload without the policy reader unexpectedly passed" >&2
  exit 1
fi

reset_release
upload_assets >/dev/null
[ "$(wc -l <"$TMP/gh.log" | tr -d '[:space:]')" -eq 4 ]
for asset in "${assets[@]}"; do
  grep -Fx "upload $tag $TMP/assets/$asset $repository" "$TMP/gh.log" >/dev/null
done
! grep -Fq "upload $release_id " "$TMP/gh.log"

reject_race renamed
reject_race immutable
reject_race missing-published
reject_race false-published
reject_race draft
reject_race tag
reject_race source
reject_race bad-id
reject_race bad-size
reject_race bad-state
reject_race bad-digest
reject_race duplicate-id 2 2
reject_race duplicate-name 2 2

printf 'unexpected\n' >"$TMP/assets/extra.txt"
reset_release
if upload_assets >/dev/null 2>&1; then
  echo "asset upload accepted an ambiguous local inventory" >&2
  exit 1
fi
[ ! -s "$TMP/gh.log" ]

echo "release asset upload fixtures passed: exact phase inventory and race rejection"
