#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-dev-promotion-source.sh
TMP=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -r -- "$TMP"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

git_config() {
  git -C "$1" config user.name fixture
  git -C "$1" config user.email fixture@example.invalid
}

expect_failure() {
  local marker=$1
  shift
  if "$@" >"$TMP/$marker.stdout" 2>"$TMP/$marker.stderr"; then
    echo "expected source authority rejection: $marker" >&2
    exit 1
  fi
  [ ! -s "$TMP/$marker.stdout" ] ||
    { echo "source rejection emitted stdout: $marker" >&2; exit 1; }
  [ -s "$TMP/$marker.stderr" ] ||
    { echo "source rejection omitted safe stderr: $marker" >&2; exit 1; }
}

mkdir "$TMP/seed"
git -C "$TMP/seed" init -q
git_config "$TMP/seed"
printf '{\n  "version": "1.2.0"\n}\n' >"$TMP/seed/version.json"
printf 'fixture\n' >"$TMP/seed/tracked.txt"
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm initial
initial_sha=$(git -C "$TMP/seed" rev-parse HEAD)
git init -q --bare "$TMP/remote.git"
git -C "$TMP/remote.git" symbolic-ref HEAD refs/heads/dev
git -C "$TMP/seed" remote add origin "$TMP/remote.git"
git -C "$TMP/seed" push -q origin HEAD:dev

git clone -q "$TMP/remote.git" "$TMP/control"
git clone -q "$TMP/remote.git" "$TMP/source"
git -C "$TMP/source" checkout -q --detach "$initial_sha"

source_command() {
  "$VERIFY" \
    --repository "$TMP/control" \
    --source-checkout "$TMP/source" \
    --source-sha "$1" \
    --output "$2" \
    "${@:3}"
}

source_command "$initial_sha" "$TMP/authority.json"
jq -e \
  --arg sha "$initial_sha" \
  --arg tree "$(git -C "$TMP/source" rev-parse 'HEAD^{tree}')" '
  keys == [
    "authoritySha","clean","detached","remoteSha","schema",
    "sourceSha","treeId","version"
  ] and
  .schema == "meet-backend/dev-promotion-source/v1" and
  .sourceSha == $sha and .authoritySha == $sha and .remoteSha == $sha and
  .treeId == $tree and .version == "1.2.0" and
  .detached == true and .clean == true
' "$TMP/authority.json" >/dev/null
source_command "$initial_sha" "$TMP/authority-repeat.json"
cmp "$TMP/authority.json" "$TMP/authority-repeat.json"
[ "$(wc -l <"$TMP/authority.json" | tr -d ' ')" -eq 1 ]

expect_failure uppercase \
  source_command "$(printf '%s' "$initial_sha" | tr '[:lower:]' '[:upper:]')" \
  "$TMP/rejected.json"
expect_failure short source_command "${initial_sha%?}" "$TMP/rejected.json"

git -C "$TMP/source" checkout -q dev
expect_failure attached source_command "$initial_sha" "$TMP/rejected.json"
git -C "$TMP/source" checkout -q --detach "$initial_sha"
printf 'dirty\n' >"$TMP/source/untracked"
expect_failure dirty source_command "$initial_sha" "$TMP/rejected.json"
rm "$TMP/source/untracked"

printf 'advanced\n' >>"$TMP/seed/tracked.txt"
git -C "$TMP/seed" commit -qam advance
advanced_sha=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin HEAD:dev
expect_failure stale source_command "$initial_sha" "$TMP/rejected.json"

git -C "$TMP/source" fetch -q origin dev
cat >"$TMP/git-race" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$3" = ls-remote ]; then
  printf '%s\trefs/heads/dev\n' "$RACED_SHA"
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$TMP/git-race"
git -C "$TMP/source" checkout -q --detach "$advanced_sha"
RACED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
REAL_GIT=$(command -v git) \
  expect_failure moving-authority \
  source_command "$advanced_sha" "$TMP/rejected.json" \
    --git-command "$TMP/git-race"

printf '{\n  "version": "01.2.0"\n}\n' >"$TMP/seed/version.json"
git -C "$TMP/seed" add version.json
git -C "$TMP/seed" commit -qm invalid-version
invalid_sha=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin HEAD:dev
git -C "$TMP/source" fetch -q origin dev
git -C "$TMP/source" checkout -q --detach "$invalid_sha"
expect_failure invalid-version \
  source_command "$invalid_sha" "$TMP/rejected.json"

printf '{\n  "version": "1.2.1",\n  "extra": true\n}\n' \
  >"$TMP/seed/version.json"
git -C "$TMP/seed" add version.json
git -C "$TMP/seed" commit -qm ambiguous-version
ambiguous_sha=$(git -C "$TMP/seed" rev-parse HEAD)
git -C "$TMP/seed" push -q origin HEAD:dev
git -C "$TMP/source" fetch -q origin dev
git -C "$TMP/source" checkout -q --detach "$ambiguous_sha"
expect_failure ambiguous-version \
  source_command "$ambiguous_sha" "$TMP/rejected.json"

echo "dev promotion source fixtures passed"
