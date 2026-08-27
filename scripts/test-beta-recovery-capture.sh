#!/usr/bin/env bash
set -euo pipefail
fail(){ echo "beta recovery capture test failed: $*" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
capture=$root/scripts/run-beta-recovery-capture.sh
backup=$root/scripts/backup-production.sh
media=$root/scripts/beta-recovery-media-proof.sh
for script in "$capture" "$backup" "$media"; do [ -x "$script" ] || fail "not executable: $script"; bash -n "$script"; done
grep -Fq '.deploy.lock' "$capture"; grep -Fq 'reconcile_states' "$capture"; grep -Fq 'capture-database-proof.json' "$capture"
grep -Fq 'pg_database_size(current_database())' "$backup"; grep -Fq 'validate_upload_archive' "$backup"; grep -Fq 'tar --list --gzip --verbose' "$backup"
grep -Fq 'decimal_add' "$media"; grep -Fq 'ln -- "$candidate" "$output"' "$media"
command -v jq >/dev/null 2>&1 || fail "jq is required"
fixture=$(mktemp -d); trap 'rm -r -- "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/avatars" "$fixture/meetings" "$fixture/communities"
printf avatar >"$fixture/avatars/a.bin"; printf meeting >"$fixture/meetings/m.bin"; printf community >"$fixture/communities/c.bin"
media_output=$fixture/proof.json; bash "$media" --root "$fixture" --output "$media_output"
jq -e '.files==3 and .bytes==22 and (.canonicalDigest|test("^[0-9a-f]{64}$"))' "$media_output" >/dev/null
if bash "$media" --root "$fixture" --output "$media_output"; then fail "existing output was overwritten"; fi
ln -s "$fixture/avatars/a.bin" "$fixture/meetings/link"
if bash "$media" --root "$fixture" --output "$fixture/unsafe.json"; then fail "symlink was accepted"; fi
echo "beta recovery capture contract passed"
