#!/usr/bin/env bash
set -euo pipefail
grep -Fq 'queue: max' .github/workflows/release-please.yml
grep -Fq 'cancel-in-progress: false' .github/workflows/release-please.yml
echo "release controller queue fixture passed"
