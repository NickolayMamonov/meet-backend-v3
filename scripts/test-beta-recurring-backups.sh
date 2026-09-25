#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-recurring-backups.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

good_master=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
good_tooling=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
good_ci=cccccccccccccccccccccccccccccccccccccccc
"$root/scripts/authorize-beta-recurring.sh" \
  --event schedule --run-ref refs/heads/master --default-ref refs/heads/master \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-capture >/dev/null ||
  fail "authorized master capture was rejected"
if "$root/scripts/authorize-beta-recurring.sh" \
  --event schedule --run-ref refs/heads/dev --default-ref refs/heads/master \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-capture >/dev/null 2>&1; then
  fail "detached dev scheduler was accepted"
fi
if "$root/scripts/authorize-beta-recurring.sh" \
  --event schedule --run-ref refs/heads/master --default-ref refs/heads/dev \
  --scheduler-sha "$good_master" --checkout-sha "$good_tooling" --ci-sha "$good_ci" \
  --environment closed-beta-recurring-restore >/dev/null 2>&1; then
  fail "changed default branch was accepted"
fi
"$root/scripts/run-beta-recurring-capture.sh" \
  --output "$tmp/point" --slot 1790000000 --captured-at 1790000000 \
  --source-revision "$good_master" --runtime-revision "$good_tooling" \
  --contract-digest "$(printf contract | sha256sum | awk '{print $1}')" \
  --proof-digest "$(printf proof | sha256sum | awk '{print $1}')" >/dev/null ||
  fail "capture manifest was not committed"
[ -f "$tmp/point/recovery-point.json" ] && [ -f "$tmp/point/point.json" ] ||
  fail "capture descriptor is incomplete"
grep -Fq 'manifest_last=true' <("$root/scripts/run-beta-recurring-capture.sh" \
  --output "$tmp/point-2" --slot 1790000001 --captured-at 1790000001 \
  --source-revision "$good_master" --runtime-revision "$good_tooling" \
  --contract-digest "$(printf contract | sha256sum | awk '{print $1}')" \
  --proof-digest "$(printf proof | sha256sum | awk '{print $1}')") ||
  fail "capture did not report manifest-last"
printf 'test-beta-recurring-backups.sh: passed\n'
