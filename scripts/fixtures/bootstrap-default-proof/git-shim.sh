#!/usr/bin/env bash
set -euo pipefail
exec "${BOOTSTRAP_REAL_GIT:?BOOTSTRAP_REAL_GIT is required}" "$@"
