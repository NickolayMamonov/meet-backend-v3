#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/run-beta-recovery-capture.sh
grep -Fq '.deploy.lock' "$script"
grep -Fq '.smtp-transaction.current' "$script"
grep -Fq 'beta-recovery-journal/v1' "$script"
grep -Fq 'postgres.dump.age' "$script"
grep -Fq 'uploads.tar.gz.age' "$script"
grep -Fq 'cmp -- "$pre" "$post"' "$script"
grep -Fq 'flock -n' "$script"
echo "beta recovery capture contract passed"
