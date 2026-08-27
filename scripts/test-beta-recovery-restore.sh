#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$root/scripts/run-beta-recovery-restore.sh
workflow=$root/.github/workflows/prove-beta-backup-restore.yml

bash -n "$script"

grep -Fq 'artifactFiles' "$script"
grep -Fq 'source.ciphertexts' "$script"
grep -Fq 'captureRuntime' "$script"
grep -Fq 'databaseProof' "$script"
grep -Fq 'mediaProof' "$script"
grep -Fq -- '--source-sha' "$script"
grep -Fq -- '--repository' "$script"
grep -Fq -- '--tooling-digest' "$script"
grep -Fq -- '--workflow-digest' "$script"
grep -Fq -- '--database-digest' "$script"
grep -Fq -- '--media-digest' "$script"
grep -Fq -- '--database-proof' "$script"
grep -Fq -- '--media-proof' "$script"

grep -Fq 'temp_required=' "$script"
grep -Fq 'docker_required=' "$script"
grep -Fq 'shared=$(add "$temp_required" "$docker_required")' "$script"
grep -Fq 'mul_small "$1" 4' "$script"
grep -Fq 'mul_small "$2" 5' "$script"
grep -Fq 'docker pull --quiet "$image"' "$script"
grep -Fq 'docker image inspect "$image"' "$script"
grep -Fq 'HostConfig.Binds' "$script"
grep -Fq 'HostConfig.Mounts' "$script"
grep -Fq 'volume_provenance' "$script"
grep -Fq 'marker=$temp/volume.identity' "$script"
grep -Fq '^[0-9a-f]{64}$' "$script"

grep -Fq 'validate_upload_archive' "$script"
grep -Fq -- '--validate-uploads-archive' "$script"
grep -Fq 'tar --extract --gzip' "$script"
grep -Fq 'cleanup-survivors' "$script"
grep -Fq -- '"$0" --cleanup-survivors' "$script"
grep -Fq 'rm -f -- "$identity"' "$script"
grep -Fq 'rm -r -- "$private"' "$script"
grep -Fq 'docker container rm --force --volumes' "$script"
grep -Fq 'docker volume rm' "$script"
grep -Fq 'docker network rm' "$script"
grep -Fq 'rm -f -- "$marker"' "$script"
if grep -Eq 'docker (container|volume|network) rm[^|]*\|\|[[:space:]]*true' "$script"; then
  echo "cleanup masks Docker removal failures" >&2
  exit 1
fi
if grep -Eiq 'TEST_VPS|SSH_PRIVATE_KEY|TEST_VPS_HOST|postgresql?://' "$script"; then
  echo "restore script contains forbidden VPS or secret-custody material" >&2
  exit 1
fi

if awk '/restore-isolated:/{flag=1} /restore-post-probe:/{flag=0} flag' "$workflow" |
  grep -Eq 'TEST_VPS|SSH_PRIVATE_KEY|TEST_VPS_HOST'; then
  echo "isolated restore job has VPS custody" >&2
  exit 1
fi

fixture=$(mktemp -d)
trap 'rm -r -- "$fixture"' EXIT HUP INT TERM

mkdir -p "$fixture/valid/avatars/nested" "$fixture/valid/meetings" "$fixture/valid/communities" "$fixture/work"
printf 'avatar\n' >"$fixture/valid/avatars/file"
printf 'nested avatar\n' >"$fixture/valid/avatars/nested/file"
printf 'meeting\n' >"$fixture/valid/meetings/file"
printf 'community\n' >"$fixture/valid/communities/file"
tar --create --gzip --file "$fixture/valid.tar.gz" --directory "$fixture/valid" .
"$script" --validate-uploads-archive --archive "$fixture/valid.tar.gz" --work-dir "$fixture/work"

mkdir -p "$fixture/traversal/avatars" "$fixture/traversal/meetings" "$fixture/traversal/communities" "$fixture/traversal-work"
printf 'escape\n' >"$fixture/traversal/avatars/file"
tar --create --gzip --file "$fixture/traversal.tar.gz" --directory "$fixture/traversal" \
  --transform='s#^./avatars/file$#./avatars/../escape#' .
if "$script" --validate-uploads-archive --archive "$fixture/traversal.tar.gz" \
  --work-dir "$fixture/traversal-work"; then
  echo "traversal archive was accepted" >&2
  exit 1
fi

mkdir -p "$fixture/fifo/avatars" "$fixture/fifo/meetings" "$fixture/fifo/communities" "$fixture/fifo-work"
printf 'avatar\n' >"$fixture/fifo/avatars/file"
mkfifo "$fixture/fifo/meetings/pipe"
tar --create --gzip --file "$fixture/fifo.tar.gz" --directory "$fixture/fifo" .
if "$script" --validate-uploads-archive --archive "$fixture/fifo.tar.gz" \
  --work-dir "$fixture/fifo-work"; then
  echo "FIFO archive was accepted" >&2
  exit 1
fi

echo "beta recovery restore contract and archive fixtures passed"
