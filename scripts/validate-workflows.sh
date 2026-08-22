#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ACTIONLINT=${ACTIONLINT:-actionlint}
WORKFLOW=${WORKFLOW:-"$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml"}

if [ "${1:-}" = "--actionlint" ]; then
  [ "$#" -eq 2 ] || {
    echo "usage: $0 [--actionlint PATH]" >&2
    exit 2
  }
  ACTIONLINT=$2
fi

command -v "$ACTIONLINT" >/dev/null 2>&1 || {
  echo "actionlint executable not found: $ACTIONLINT" >&2
  exit 127
}

[ -f "$WORKFLOW" ] || {
  echo "workflow YAML file not found: $WORKFLOW" >&2
  exit 1
}

# Keep the workflow parser, expression, and schema checks mandatory. The
# repository's existing ShellCheck gate owns checked-in shell scripts; disabling
# actionlint's embedded-shell integration avoids duplicate diagnostics for
# heredocs and GitHub expression text inside run blocks.
"$ACTIONLINT" -shellcheck "" "$WORKFLOW"
