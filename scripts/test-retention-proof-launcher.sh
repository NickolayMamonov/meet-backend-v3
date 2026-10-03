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
grep -Fq '"enabled": false' scripts/fixtures/retention-proof/toolchain.lock.json
grep -Fq '"enabled": false' .github/retention-proof-registration.json
! grep -Eq '(^|[[:space:]])(docker|sudo|curl|gh)([[:space:]]|$)|test-test-vps-retention.sh' \
  scripts/run-test-vps-retention-proof.sh

for source in \
  scripts/run-test-vps-retention-proof.sh \
  scripts/fixtures/retention-proof/proof-entrypoint.sh; do
  bash -n "$source"
done

echo "non-root retention launcher denial and fake API tests passed; Docker was not invoked"
