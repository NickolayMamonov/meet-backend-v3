#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [ "$(id -u)" -eq 0 ]; then
  echo "launcher tests must run as a non-root user" >&2
  exit 77
fi

python3 -B scripts/test-retention-proof-registration.py
python3 -B scripts/test-retention-proof-supervisor.py

tmp=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$tmp"
  exit "$status"
}
trap cleanup EXIT

mkdir -m 700 "$tmp/bin"
docker_trace="$tmp/docker.trace"
cat >"$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
echo invoked >>"$docker_trace"
exit 99
EOF
chmod 700 "$tmp/bin/docker"

set +e
GITHUB_RUN_ATTEMPT=1 \
  GITHUB_REF=refs/heads/master \
  SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  IMAGE_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  PATH="$tmp/bin:$PATH" \
  timeout 30s bash scripts/run-test-vps-retention-proof.sh \
  >"$tmp/stdout" 2>"$tmp/stderr"
status=$?
set -e
[ "$status" -eq 1 ]
grep -Fq 'RETENTION_PROOF_BLOCKED' "$tmp/stderr"
[ ! -e "$docker_trace" ]
python3 -B - \
  scripts/fixtures/retention-proof/toolchain.lock.json \
  .github/retention-proof-registration.json <<'PY'
import json
import sys
from pathlib import Path

for filename in sys.argv[1:]:
    value = json.loads(Path(filename).read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("enabled") is not False:
        raise SystemExit(f"proof activation must remain disabled: {filename}")
PY
! grep -Eq '(^|[[:space:]])(docker|sudo|curl|gh)([[:space:]]|$)|test-test-vps-retention.sh' \
  scripts/run-test-vps-retention-proof.sh

for source in \
  scripts/run-test-vps-retention-proof.sh \
  scripts/fixtures/retention-proof/proof-entrypoint.sh; do
  bash -n "$source"
done

echo "non-root retention launcher denial and fake API tests passed; Docker was not invoked"
