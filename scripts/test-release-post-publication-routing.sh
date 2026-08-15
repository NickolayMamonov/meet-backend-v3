#!/usr/bin/env bash
set -euo pipefail
grep -Fq 'route=completed' scripts/resolve-release-descriptor.sh
grep -Fq 'allow-completed' scripts/resolve-release-descriptor.sh
echo "post-publication routing fixture passed"
