#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
workflow=.github/workflows/deploy-test-vps.yml
deploy=scripts/deploy-test-vps-release.sh

[ -f "$workflow" ] && [ -f "$deploy" ]

for text in \
  'workflow_dispatch:' \
  "if: github.ref == 'refs/heads/dev'" \
  'name: test-vps' \
  'scripts/verify-immutable-release-proof.sh' \
  'scripts/verify-release-checksums.sh' \
  '--allow-immutable-v1.2.0-compact' \
  'cmp -s "$release_dir/image-index.json"' \
  'grep -Ec "^Digest:[[:space:]]+$digest$"' \
  'gh attestation verify "oci://$IMAGE@$digest"' \
  'ssh-keyscan -T 5 -p "$PORT" "$HOST"' \
  'ssh-keygen -lf - -E sha256' \
  'scripts/deploy-test-vps-release.sh' \
  '[ "$status" -eq 86 ]' \
  'rollback=completed previous_image_id=' \
  '--mode deploy' \
  'https://api.whysoezzy.online' \
  'meet-production_postgres_data' \
  'meet-production_uploads_data' \
  'Apply bounded test-VPS deployment retention' \
  'find "$path" -xdev -type f -delete' \
  'index=10' \
  'retention=applied'; do
  grep -Fq -- "$text" "$workflow" || {
    echo "test VPS workflow misses invariant: $text" >&2
    exit 1
  }
done

for stale in \
  "refs/heads/master" \
  '      name: production' \
  'backup-production.sh' \
  'PRODUCTION_SSH_PRIVATE_KEY' \
  ':latest'; do
  grep -Fq -- "$stale" "$workflow" && {
    echo "test VPS workflow contains prohibited production construct: $stale" >&2
    exit 1
  }
done

verify_line=$(grep -n 'scripts/verify-immutable-release-proof.sh' "$workflow" |
  cut -d: -f1)
ssh_line=$(grep -n 'ssh-keyscan -T 5' "$workflow" | cut -d: -f1)
[ "$verify_line" -lt "$ssh_line" ] || {
  echo "release verification must precede VPS network access" >&2
  exit 1
}

for text in \
  'trap on_exit EXIT' \
  'rollback()' \
  'rollback=completed previous_image_id=' \
  'restored_hash' \
  'previous_runtime_hash' \
  'runtime_check=network' \
  'rollback drill requires a target image distinct from the predecessor' \
  'http://127.0.0.1:8080/meetings' \
  'volume|meet-production_uploads_data' \
  'docker volume inspect meet-production_postgres_data' \
  "sed '/^$/d'" \
  '[ -z "$(docker port "$postgres")" ]' \
  '--no-deps --no-build --pull never --force-recreate' \
  'deployment=completed image_id='; do
  grep -Fq -- "$text" "$deploy" || {
    echo "test VPS deploy script misses invariant: $text" >&2
    exit 1
  }
done

if grep -Fq 'rm -rf' "$workflow" "$deploy"; then
  echo "test VPS deployment must not recursively delete host state" >&2
  exit 1
fi

cleanup_line=$(grep -n 'name: Apply bounded test-VPS deployment retention' \
  "$workflow" | cut -d: -f1)
evidence_line=$(grep -n 'name: Capture runtime and public HTTPS evidence' \
  "$workflow" | cut -d: -f1)
[ "$evidence_line" -lt "$cleanup_line" ] || {
  echo "retention must run only after final runtime evidence" >&2
  exit 1
}

echo "test VPS deploy workflow fixture passed"
