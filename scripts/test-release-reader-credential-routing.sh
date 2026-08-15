#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/release-please.yml
CI_WORKFLOW=$ROOT_DIR/.github/workflows/ci.yml
fail() { echo "release reader credential-routing fixture failed: $*" >&2; exit 1; }
workflow=$(sed 's/\r$//' "$WORKFLOW")
ci_workflow=$(sed 's/\r$//' "$CI_WORKFLOW")

controller=$(sed -n '/^  controller:/,/^  gates:/p' <<<"$workflow")
grep -Fq '      packages: read' <<<"$controller" ||
  fail "controller does not grant packages: read"

step_block() {
  local name=$1
  awk -v marker="      - name: $name" '
    $0 == marker { in_step=1 }
    in_step && $0 ~ /^      - name: / && $0 != marker { exit }
    in_step { print }
  ' <<<"$controller"
}

for helper_step in \
  'Enforce protected history before Release Please' \
  'Classify current action before Release Please' \
  'Enforce protected history after Release Please' \
  'Normalize action result and current-action set difference'; do
  block=$(step_block "$helper_step")
  [ -n "$block" ] || fail "missing controller helper step: $helper_step"
  grep -Fq 'GH_TOKEN: ${{ github.token }}' <<<"$block" ||
    fail "controller helper does not use github.token: $helper_step"
  if grep -Fq 'secrets.RELEASE_PLEASE_TOKEN' <<<"$block"; then
    fail "controller helper uses RELEASE_PLEASE_TOKEN: $helper_step"
  fi
done

[ "$(grep -Fc 'GH_TOKEN: ${{ github.token }}' <<<"$controller")" -eq 4 ] ||
  fail "controller must have exactly four github.token helper routes"
[ "$(grep -Fc 'secrets.RELEASE_PLEASE_TOKEN' <<<"$workflow")" -eq 1 ] ||
  fail "RELEASE_PLEASE_TOKEN must appear exactly once in the release workflow"
if grep -Fq 'secrets.RELEASE_PLEASE_TOKEN' <<<"$ci_workflow"; then
  fail "CI workflow must not use RELEASE_PLEASE_TOKEN"
fi

release_action=$(step_block 'Release Please current action')
grep -Fq \
  'uses: googleapis/release-please-action@c2a5a2bd6a758a0937f1ddb1e8950609867ed15c' \
  <<<"$release_action" || fail "Release Please action is not pinned"
grep -Fq 'token: ${{ secrets.RELEASE_PLEASE_TOKEN }}' <<<"$release_action" ||
  fail "pinned Release Please action does not use RELEASE_PLEASE_TOKEN"

echo "release reader credential-routing fixture passed"
