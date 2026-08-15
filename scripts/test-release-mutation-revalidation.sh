#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/bin"
SHA=0123456789abcdef0123456789abcdef01234567
jq -n --arg sha "$SHA" '{
  id:120,tag_name:"v1.2.0",target_commitish:$sha,draft:true,prerelease:false,
  published_at:null,assets:[{id:1},{id:2},{id:3},{id:4}]
}' >"$TMP/release.json"
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
if "$ROOT_DIR/scripts/revalidate-release-mutation.sh" \
  --repository FixtureOwner/repo --release-id 120 --tag v1.2.0 \
  --version 1.2.0 --source-sha "$SHA" --release-file "$TMP/release.json" \
  --expected-route materialize >/dev/null 2>&1; then
  echo "revalidation without the policy reader unexpectedly passed" >&2
  exit 1
fi
"$ROOT_DIR/scripts/revalidate-release-mutation.sh" \
  --repository FixtureOwner/repo --release-id 120 --tag v1.2.0 \
  --version 1.2.0 --source-sha "$SHA" --release-file "$TMP/release.json" \
  --expected-route materialize --policy-token-file "$TMP/policy-token" >/dev/null
jq '.assets = []' "$TMP/release.json" >"$TMP/empty-release.json"
"$ROOT_DIR/scripts/revalidate-release-mutation.sh" \
  --repository FixtureOwner/repo --release-id 120 --tag v1.2.0 \
  --version 1.2.0 --source-sha "$SHA" --release-file "$TMP/empty-release.json" \
  --expected-route materialize --phase empty \
  --policy-token-file "$TMP/policy-token" >/dev/null
if "$ROOT_DIR/scripts/revalidate-release-mutation.sh" \
  --repository FixtureOwner/repo --release-id 120 --tag v1.2.0 \
  --version 1.2.0 --source-sha "$SHA" --release-file "$TMP/release.json" \
  --expected-route materialize --phase empty \
  --policy-token-file "$TMP/policy-token" >/dev/null 2>&1; then
  echo "non-empty draft passed the empty-draft revalidation" >&2
  exit 1
fi
echo "release mutation revalidation fixtures passed"
