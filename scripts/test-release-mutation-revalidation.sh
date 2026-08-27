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

jq -n --argjson id "$release_id" --arg tag "$tag" --arg source "$source_sha" '{
  id:$id,name:$tag,tag_name:$tag,target_commitish:$source,
  draft:true,prerelease:false,immutable:false,published_at:null,assets:[]
}' >"$TMP/complete.json"
index=1
for asset in "${assets[@]}"; do
  digest=$(sha256sum "$TMP/assets/$asset" | awk '{print $1}')
  size=$(wc -c <"$TMP/assets/$asset" | tr -d '[:space:]')
  jq --argjson id "$index" --arg name "$asset" --arg digest "sha256:$digest" \
    --argjson size "$size" \
    '.assets += [{id:$id,name:$name,state:"uploaded",digest:$digest,size:$size}]' \
    "$TMP/complete.json" >"$TMP/release.tmp"
  mv "$TMP/release.tmp" "$TMP/complete.json"
  index=$((index + 1))
done
jq '.assets = []' "$TMP/complete.json" >"$TMP/empty.json"

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
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
printf 'fixture-policy-reader-token\n' >"$TMP/policy-token"

revalidate() {
  local file=$1 phase=$2
  shift 2
  "$ROOT_DIR/scripts/revalidate-release-mutation.sh" \
    --repository "$repository" --release-id "$release_id" --tag "$tag" \
    --version "$version" --source-sha "$source_sha" --release-file "$file" \
    --expected-route materialize --phase "$phase" \
    --policy-token-file "$TMP/policy-token" "$@"
}
reject_fixture() {
  local label=$1 filter=$2 source=${3:-$TMP/complete.json} phase=${4:-complete}
  jq "$filter" "$source" >"$TMP/rejected.json"
  if revalidate "$TMP/rejected.json" "$phase" >/dev/null 2>&1; then
    echo "revalidation accepted $label" >&2
    exit 1
  fi
}

if "$ROOT_DIR/scripts/revalidate-release-mutation.sh" \
  --repository "$repository" --release-id "$release_id" --tag "$tag" \
  --version "$version" --source-sha "$source_sha" \
  --release-file "$TMP/complete.json" --expected-route materialize \
  >/dev/null 2>&1; then
  echo "revalidation without the policy reader unexpectedly passed" >&2
  exit 1
fi
revalidate "$TMP/empty.json" empty >/dev/null
revalidate "$TMP/complete.json" complete --assets-dir "$TMP/assets" >/dev/null

printf '[]\n' >"$TMP/rejected.json"
if revalidate "$TMP/rejected.json" complete >/dev/null 2>&1; then
  echo "revalidation accepted a non-object release" >&2
  exit 1
fi
reject_fixture 'a renamed release' '.name = "renamed"'
reject_fixture 'a release without name' 'del(.name)'
reject_fixture 'an immutable release' '.immutable = true'
reject_fixture 'a release without immutable' 'del(.immutable)'
reject_fixture 'a release without published_at' 'del(.published_at)'
reject_fixture 'false published_at' '.published_at = false'
reject_fixture 'a non-draft release' '.draft = false'
reject_fixture 'a changed tag' '.tag_name = "v9.9.9"'
reject_fixture 'a changed source' '.target_commitish = "ffffffffffffffffffffffffffffffffffffffff"'
reject_fixture 'ambiguous asset names' '.assets[1].name = .assets[0].name'
reject_fixture 'ambiguous asset IDs' '.assets[1].id = .assets[0].id'
reject_fixture 'a non-uploaded asset' '.assets[0].state = "new"'
reject_fixture 'a zero-size asset' '.assets[0].size = 0'
reject_fixture 'a malformed digest' '.assets[0].digest = "sha256:nope"'
reject_fixture 'assets in the empty phase' '.assets = [.assets[0]]' "$TMP/complete.json" empty

printf 'unexpected\n' >"$TMP/assets/extra.txt"
if revalidate "$TMP/complete.json" complete --assets-dir "$TMP/assets" >/dev/null 2>&1; then
  echo "revalidation accepted an ambiguous local asset inventory" >&2
  exit 1
fi

echo "release mutation revalidation fixtures passed: exact release and phase inventory"
