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
trap '[ "${KEEP_BETA_RECOVERY_FIXTURE:-0}" = 1 ] || rm -r -- "$fixture"' EXIT HUP INT TERM

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

run_restore_fixture() {
  local name=$1 expected_status=$2 mount_mode=${3:-valid} behavior=${4:-normal}
  local case_dir=$fixture/$name
  local hash tooling workflow_digest database_digest media_digest
  mkdir -p "$case_dir/artifact" "$case_dir/output" "$case_dir/docker-root" "$case_dir/docker-state" "$case_dir/temp"
  printf identity >"$case_dir/identity"
  printf 'database\n' >"$case_dir/database.dump"
  tar --create --gzip --file "$case_dir/uploads.tar.gz" --directory "$fixture/valid" .
  printf encrypted >"$case_dir/artifact/postgres.dump.age"
  printf encrypted >"$case_dir/artifact/uploads.tar.gz.age"
  jq -cnS '{schema:"meet-backend/closed-beta-database-proof/v1",rows:{users:1}}' \
    >"$case_dir/database-proof.json"
  "$root/scripts/beta-recovery-media-proof.sh" --root "$fixture/valid" \
    --output "$case_dir/media-proof.json"
  hash=$(jq -er '.canonicalDigest' "$case_dir/media-proof.json")
  jq -cnS --arg hash "$hash" '{schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
    runtime:{imageId:"sha256:test",configHash:$hash,health:"healthy",uploadsMount:"volume"},
    https:{meetingsStatus:"200",actuatorStatus:"404",httpRedirectHttps:true,meetingsJson:true}}' \
    >"$case_dir/runtime.json"
  tooling=$(for file in scripts/authorize-beta-recovery.sh scripts/run-beta-recovery-capture.sh \
    scripts/run-beta-recovery-restore.sh scripts/build-beta-recovery-evidence.sh \
    scripts/probe-test-vps-recovery-runtime.sh scripts/backup-production.sh \
    scripts/beta-recovery-database-proof.sql scripts/beta-recovery-media-proof.sh; do
    sha256sum "$file"
  done | sort | sha256sum | awk '{print $1}')
  workflow_digest=$(sha256sum .github/workflows/prove-beta-backup-restore.yml | awk '{print $1}')
  database_digest=$(sha256sum scripts/beta-recovery-database-proof.sql | awk '{print $1}')
  media_digest=$(sha256sum scripts/beta-recovery-media-proof.sh | awk '{print $1}')
  bash "$root/scripts/build-beta-recovery-evidence.sh" manifest \
    --recovery-id recovery-fixture --source-sha 0123456789abcdef0123456789abcdef01234567 \
    --repository NickolayMamonov/meet-backend-v3 --run-id 7 \
    --artifact-name beta-recovery-recovery-fixture-7 \
    --tooling-digest "$tooling" --workflow-digest "$workflow_digest" \
    --database-digest "$database_digest" --media-digest "$media_digest" \
    --captured-at 2026-08-27T19:00:00Z --point-time 2026-08-27T19:00:00Z \
    --observed-age-seconds 120 \
    --database-bytes 1 --uploads-files "$(jq -er '.files' "$case_dir/media-proof.json")" \
    --uploads-bytes "$(jq -er '.bytes' "$case_dir/media-proof.json")" --uploads-digest "$hash" \
    --database-proof "$case_dir/database-proof.json" --media-proof "$case_dir/media-proof.json" \
    --runtime-proof "$case_dir/runtime.json" \
    --database-ciphertext "$case_dir/artifact/postgres.dump.age" \
    --uploads-ciphertext "$case_dir/artifact/uploads.tar.gz.age" \
    --output "$case_dir/recovery-point.json"
  cp -- "$case_dir/recovery-point.json" "$case_dir/artifact/"
  bash "$root/scripts/build-beta-recovery-evidence.sh" validate-artifact \
    --artifact-dir "$case_dir/artifact" --recovery-id recovery-fixture \
    --source-sha 0123456789abcdef0123456789abcdef01234567 \
    --repository NickolayMamonov/meet-backend-v3 --run-id 7
  mkdir -p "$case_dir/bin"
  ln -- "$root/scripts/fixtures/beta-recovery/fake-docker.sh" "$case_dir/bin/docker"
  ln -- "$root/scripts/fixtures/beta-recovery/fake-age.sh" "$case_dir/bin/age"
  chmod 700 "$case_dir/bin/docker" "$case_dir/bin/age"
  export FAKE_DOCKER_STATE="$case_dir/docker-state"
  export FAKE_DOCKER_ROOT="$case_dir/docker-root"
  export FAKE_RECOVERY_ID=recovery-fixture
  export FAKE_DOCKER_MOUNT_MODE="$mount_mode"
  unset FAKE_DOCKER_FAIL_RESTORE FAKE_DOCKER_FAIL_CONTAINER_RM_ONCE
  unset FAKE_DOCKER_FAIL_VOLUME_RM_ONCE FAKE_DOCKER_PRESERVE_VOLUME FAKE_DOCKER_INTERRUPT_AFTER_CREATE
  if [ "$behavior" = restore-failure ]; then export FAKE_DOCKER_FAIL_RESTORE=1; fi
  if [ "$behavior" = retry ]; then
    export FAKE_DOCKER_FAIL_CONTAINER_RM_ONCE=1
    export FAKE_DOCKER_PRESERVE_VOLUME=1
  fi
  if [ "$behavior" = volume-retry ]; then
    export FAKE_DOCKER_FAIL_VOLUME_RM_ONCE=1
    export FAKE_DOCKER_PRESERVE_VOLUME=1
  fi
  if [ "$behavior" = interrupt ]; then export FAKE_DOCKER_INTERRUPT_AFTER_CREATE=1; fi
  export FAKE_DATABASE_PROOF="$case_dir/database-proof.json"
  export FAKE_DATABASE_DUMP="$case_dir/database.dump"
  export FAKE_UPLOADS_ARCHIVE="$case_dir/uploads.tar.gz"
  export POSTGRES_IMAGE=repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  if [ "$behavior" = collision ]; then
    collision_token=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    PATH="$case_dir/bin:$PATH" docker network create \
      --label com.meet-backend.beta-recovery/owner=restore \
      --label com.meet-backend.beta-recovery/recovery-id=recovery-fixture \
      --label com.meet-backend.beta-recovery/owner-token="$collision_token" \
      beta-recovery-recovery-fixture
    PATH="$case_dir/bin:$PATH" docker create \
      --name beta-recovery-postgres-recovery-fixture \
      --label com.meet-backend.beta-recovery/owner=restore \
      --label com.meet-backend.beta-recovery/recovery-id=recovery-fixture \
      --label com.meet-backend.beta-recovery/owner-token="$collision_token" \
      "$POSTGRES_IMAGE"
    printf 'pre-existing\n' >"$case_dir/docker-root/volumes/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/_data/sentinel"
    if PATH="$case_dir/bin:$PATH" bash "$script" \
      --artifact-dir "$case_dir/artifact" --recovery-id recovery-fixture \
      --output-dir "$case_dir/output" --identity "$case_dir/identity" \
      --sql-proof "$root/scripts/beta-recovery-database-proof.sql" \
      --media-script "$root/scripts/beta-recovery-media-proof.sh" \
      --temp-root "$case_dir/temp" --source-sha 0123456789abcdef0123456789abcdef01234567 \
      --repository NickolayMamonov/meet-backend-v3 --tooling-digest "$tooling" \
      --workflow-digest "$workflow_digest" --database-digest "$database_digest" \
      --media-digest "$media_digest"; then
      echo "same-name collision unexpectedly succeeded" >&2
      exit 1
    fi
    [ -e "$case_dir/docker-state/container" ] && [ -e "$case_dir/docker-state/network" ] &&
      [ -e "$case_dir/docker-state/volume" ] &&
      [ "$(cat "$case_dir/docker-state/container-owner-token")" = "$collision_token" ] &&
      [ "$(cat "$case_dir/docker-state/network-owner-token")" = "$collision_token" ] &&
      [ "$(cat "$case_dir/docker-root/volumes/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/_data/sentinel")" = pre-existing ] ||
      { echo "same-name collision resource was modified" >&2; exit 1; }
    return
  fi
  if [ "$behavior" = survivor ]; then
    survivor_token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    jq -cn --arg id recovery-fixture --arg token "$survivor_token" \
      '{schema:"meet-backend/beta-recovery-ownership/v1",recoveryId:$id,ownerToken:$token,
        containerName:"beta-recovery-postgres-recovery-fixture",networkName:"beta-recovery-recovery-fixture",
        containerAttempted:true,containerCreated:true,networkAttempted:true,networkCreated:true}' \
      >"$case_dir/temp/ownership.json"
    PATH="$case_dir/bin:$PATH" docker network create \
      --label com.meet-backend.beta-recovery/owner=restore \
      --label com.meet-backend.beta-recovery/recovery-id=recovery-fixture \
      --label com.meet-backend.beta-recovery/owner-token="$survivor_token" \
      beta-recovery-recovery-fixture
    PATH="$case_dir/bin:$PATH" docker create \
      --name beta-recovery-postgres-recovery-fixture \
      --label com.meet-backend.beta-recovery/owner=restore \
      --label com.meet-backend.beta-recovery/recovery-id=recovery-fixture \
      --label com.meet-backend.beta-recovery/owner-token="$survivor_token" \
      "$POSTGRES_IMAGE"
    [ ! -e "$case_dir/temp/volume.identity" ]
    PATH="$case_dir/bin:$PATH" bash "$script" --cleanup-survivors \
      --container beta-recovery-postgres-recovery-fixture \
      --network beta-recovery-recovery-fixture \
      --volume-identity "$case_dir/temp/volume.identity" \
      --ownership-marker "$case_dir/temp/ownership.json" --owner-token "$survivor_token" \
      --recovery-id recovery-fixture --docker-root "$case_dir/docker-root"
    [ ! -e "$case_dir/docker-state/container" ] && [ ! -e "$case_dir/docker-state/network" ] &&
      [ ! -e "$case_dir/docker-state/volume" ] &&
      [ ! -e "$case_dir/docker-root/volumes/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ] ||
      { echo "fresh-process cleanup left an owned survivor" >&2; exit 1; }
    return
  fi
  if [ "$behavior" = capacity ]; then
    PATH="$case_dir/bin:$PATH" bash "$script" \
      --capacity-only --artifact-dir "$case_dir/artifact" --recovery-id recovery-fixture \
      --output-dir "$case_dir/capacity-output" --temp-root "$case_dir/capacity-temp" \
      --docker-root "$case_dir/docker-root" --sql-proof "$root/scripts/beta-recovery-database-proof.sql" \
      --media-script "$root/scripts/beta-recovery-media-proof.sh" \
      --source-sha 0123456789abcdef0123456789abcdef01234567 \
      --repository NickolayMamonov/meet-backend-v3 --tooling-digest "$tooling" \
      --workflow-digest "$workflow_digest" --database-digest "$database_digest" \
      --media-digest "$media_digest"
    [ -d "$case_dir/capacity-output" ]
  fi
  if PATH="$case_dir/bin:$PATH" bash "$script" \
    --artifact-dir "$case_dir/artifact" --recovery-id recovery-fixture \
    --output-dir "$case_dir/output" --identity "$case_dir/identity" \
    --sql-proof "$root/scripts/beta-recovery-database-proof.sql" \
    --media-script "$root/scripts/beta-recovery-media-proof.sh" \
    --temp-root "$case_dir/temp" --source-sha 0123456789abcdef0123456789abcdef01234567 \
    --repository NickolayMamonov/meet-backend-v3 --tooling-digest "$tooling" \
    --workflow-digest "$workflow_digest" --database-digest "$database_digest" \
    --media-digest "$media_digest"; then
    actual_status=0
  else
    actual_status=$?
  fi
  [ "$actual_status" -eq "$expected_status" ] || {
    echo "restore fixture $name returned $actual_status, expected $expected_status" >&2
    exit 1
  }
  if [ "$behavior" = interrupt ]; then
    [ ! -e "$case_dir/temp/volume.identity" ] &&
      [ ! -e "$case_dir/docker-state/container" ] && [ ! -e "$case_dir/docker-state/network" ] &&
      [ ! -e "$case_dir/docker-state/volume" ] &&
      [ ! -e "$case_dir/docker-root/volumes/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ] ||
      { echo "interruption cleanup left an owned survivor" >&2; exit 1; }
    return
  fi
  [ ! -e "$case_dir/docker-state/container" ] && [ ! -e "$case_dir/docker-state/network" ] ||
    { echo "restore fixture $name left Docker resources" >&2; exit 1; }
  [ ! -e "$case_dir/docker-state/volume" ] ||
    { echo "restore fixture $name left anonymous volume state" >&2; exit 1; }
  [ ! -e "$case_dir/docker-root/volumes/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ] ||
    { echo "restore fixture $name left anonymous volume data" >&2; exit 1; }
  if [ "$expected_status" -eq 0 ]; then
    [ -s "$case_dir/output/restored-database-proof.json" ] &&
      [ -s "$case_dir/output/restored-media-proof.json" ] &&
      grep -Fxq cleanup_complete=true "$case_dir/output/restore-summary" &&
      jq -e 'keys|sort == ["anonymous","destination","readWrite","schema","type"]' \
        "$case_dir/output/mount-contract.json" >/dev/null
  fi
}

run_restore_fixture success 0 valid capacity
run_restore_fixture restore-failure 1 valid restore-failure
run_restore_fixture restore-retry 0 valid retry
run_restore_fixture restore-volume-retry 0 valid volume-retry
run_restore_fixture restore-bind 1 bind
run_restore_fixture restore-named 1 named
run_restore_fixture restore-duplicate 1 duplicate
run_restore_fixture restore-missing 1 missing
run_restore_fixture restore-unexpected 1 unexpected
run_restore_fixture restore-collision 1 valid collision
run_restore_fixture restore-interruption 137 valid interrupt
run_restore_fixture restore-interruption-retry 0 valid survivor

echo "beta recovery restore contract and archive fixtures passed"
