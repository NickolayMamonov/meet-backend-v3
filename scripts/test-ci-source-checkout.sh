#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/ci.yml

[ -f "$WORKFLOW" ] || {
  echo "CI workflow not found: $WORKFLOW" >&2
  exit 1
}

workflow_text=$(<"$WORKFLOW")

require() {
  local needle=$1
  local label=$2
  case "$workflow_text" in
    *"$needle"*) ;;
    *)
      echo "$label misses invariant: $needle" >&2
      exit 1
      ;;
  esac
}

count_exact() {
  local expected=$1
  local needle=$2
  local label=$3
  local actual
  actual=$(grep -Fc "$needle" "$WORKFLOW" || true)
  [ "$actual" -eq "$expected" ] || {
    echo "$label expected $expected occurrences, found $actual: $needle" >&2
    exit 1
  }
}

jobs=(gradle postgres scripts docker)
for job in "${jobs[@]}"; do
  job_block=$(
    awk -v wanted="$job" '
      /^  [a-z][a-z0-9-]*:$/ {
        name=$0
        sub(/^  /, "", name)
        sub(/:$/, "", name)
        in_job=(name == wanted)
      }
      in_job { print }
    ' "$WORKFLOW"
  )

  [ -n "$job_block" ] || {
    echo "CI workflow job not found: $job" >&2
    exit 1
  }
  grep -Fq 'name: Checkout reviewed source' <<<"$job_block"
  grep -Fq 'name: Checkout reviewed CI tooling' <<<"$job_block"
  grep -Fq 'name: Checkout exact release source' <<<"$job_block"
  grep -Fq 'name: Record reviewed source identity' <<<"$job_block"
  grep -Fq "working-directory: \${{ inputs.source_sha != '' && 'source' || '.' }}" <<<"$job_block"
  checkout_line=$(grep -nF 'name: Checkout exact release source' <<<"$job_block" | cut -d: -f1)
  identity_line=$(grep -nF 'name: Record reviewed source identity' <<<"$job_block" | cut -d: -f1)
  [ "$checkout_line" -lt "$identity_line" ] || {
    echo "$job identity proof must follow its checkout steps: $job" >&2
    exit 1
  }
done

count_exact 4 \
  'name: Checkout reviewed source' \
  'non-release source checkout sites'
count_exact 4 \
  'ref: ${{ inputs.ref || github.event.pull_request.head.sha || github.sha }}' \
  'non-release source checkout refs'
count_exact 4 \
  'name: Record reviewed source identity' \
  'source identity proof steps'
count_exact 4 \
  'actual_sha=$(git rev-parse HEAD)' \
  'source identity resolution'
count_exact 4 \
  'test "$actual_sha" = "$SOURCE_SHA"' \
  'release source identity assertions'
count_exact 4 \
  'expected_sha="${PR_HEAD_SHA:-$WORKFLOW_SHA}"' \
  'ordinary source fallback assertions'

require 'inputs.ref || github.event.pull_request.head.sha || github.sha' \
  'explicit-ref/PR-head/default checkout precedence'
require 'EXPLICIT_REF: ${{ inputs.ref }}' \
  'explicit caller ref recording'
require 'elif [ -n "$EXPLICIT_REF" ]; then' \
  'explicit caller ref branch'
require 'echo "reviewed source ref: $EXPLICIT_REF"' \
  'explicit caller ref resolution record'
require 'PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}' \
  'pull-request head identity'
require 'WORKFLOW_SHA: ${{ github.sha }}' \
  'push/default identity'

count_exact 4 \
  'name: Checkout reviewed CI tooling' \
  'release tooling checkout sites'
count_exact 4 \
  'ref: ${{ github.sha }}' \
  'release tooling refs'
count_exact 4 \
  'path: tooling' \
  'release tooling paths'
count_exact 4 \
  'name: Checkout exact release source' \
  'release source checkout sites'
count_exact 4 \
  'ref: ${{ inputs.source_sha }}' \
  'release source refs'
count_exact 4 \
  'path: source' \
  'release source paths'
count_exact 8 \
  "if: inputs.source_sha != ''" \
  'release checkout guards'

require 'permissions:' 'workflow permissions'
require '  contents: read' 'read-only workflow permissions'
count_exact 2 'contents: read' 'read-only permission declarations'
if grep -Eq 'contents:[[:space:]]*write|permissions:[[:space:]]*write' "$WORKFLOW"; then
  echo "CI workflow grants write permissions" >&2
  exit 1
fi
require 'push:' 'dev push trigger'
require '    branches: [dev]' 'dev-only push branch'
require 'source_sha, release_tag, release_version, and release_id must be supplied together' \
  'release tuple validation'

if grep -Eq 'actions/checkout@(v|[0-9]+([.][0-9]+){0,2})($|[^0-9a-f])' "$WORKFLOW"; then
  echo "CI workflow contains an unpinned checkout action" >&2
  exit 1
fi

echo "CI source checkout invariants passed"
