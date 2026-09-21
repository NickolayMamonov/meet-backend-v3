#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

filesystem_only=false
previous_image=
target_image=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --filesystem-only)
      [ "$filesystem_only" = false ] || exit 2
      filesystem_only=true
      shift
      ;;
    --previous-image)
      [ "$#" -ge 2 ] && [ -z "$previous_image" ] || exit 2
      previous_image=$2
      shift 2
      ;;
    --target-image)
      [ "$#" -ge 2 ] && [ -z "$target_image" ] || exit 2
      target_image=$2
      shift 2
      ;;
    *)
      echo "usage: $0 --filesystem-only | --previous-image IMAGE@sha256:DIGEST --target-image IMAGE@sha256:DIGEST" >&2
      exit 2
      ;;
  esac
done

if [ "$filesystem_only" = false ]; then
  [[ "$previous_image" =~ ^.+@sha256:[0-9a-f]{64}$ ]]
  [[ "$target_image" =~ ^.+@sha256:[0-9a-f]{64}$ ]]
  [ "$previous_image" != "$target_image" ]
  [[ "$previous_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  [[ "$target_image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  command -v docker >/dev/null 2>&1 || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  timeout 30s docker info >/dev/null 2>&1 || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  previous_id=$(timeout 30s docker image inspect "$previous_image" --format '{{.Id}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  target_id=$(timeout 30s docker image inspect "$target_image" --format '{{.Id}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  [ "$previous_id" != "$target_id" ] || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "PREREQUISITE_MISSING" >&2
  exit 77
fi

if [ "$filesystem_only" = false ]; then
  for command_name in docker curl jq flock python3 timeout; do
    command -v "$command_name" >/dev/null 2>&1 || {
      echo "PREREQUISITE_MISSING" >&2
      exit 77
    }
  done
  docker compose version >/dev/null 2>&1 || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }

  image_label() {
    timeout 30s docker image inspect "$1" \
      --format "$2"
  }

  version_supported() {
    timeout 30s python3 - "$1" <<'PY'
import re
import sys

match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", sys.argv[1])
raise SystemExit(
    0
    if match is not None and tuple(map(int, match.groups())) >= (1, 2, 0)
    else 1
)
PY
  }

  previous_revision=$(image_label "$previous_image" \
    '{{index .Config.Labels "org.opencontainers.image.revision"}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  previous_version=$(image_label "$previous_image" \
    '{{index .Config.Labels "org.opencontainers.image.version"}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  target_revision=$(image_label "$target_image" \
    '{{index .Config.Labels "org.opencontainers.image.revision"}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  target_version=$(image_label "$target_image" \
    '{{index .Config.Labels "org.opencontainers.image.version"}}') || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  [[ "$previous_revision" =~ ^[0-9a-f]{40}$ ]] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  [[ "$target_revision" =~ ^[0-9a-f]{40}$ ]] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  version_supported "$previous_version" ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  version_supported "$target_version" ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  [ "$(image_label "$previous_image" \
    '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
    "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  [ "$(image_label "$target_image" \
    '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
    "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  [ "$(image_label "$previous_image" '{{.Config.User}}')" = "10001:10001" ] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }
  [ "$(image_label "$target_image" '{{.Config.User}}')" = "10001:10001" ] ||
    { echo "PREREQUISITE_MISSING" >&2; exit 77; }

  postgres_image=$(
    sed -nE \
      's/^[[:space:]]*image:[[:space:]]*(postgres:16-alpine@sha256:[0-9a-f]{64})[[:space:]]*$/\1/p' \
      "$ROOT_DIR/docker-compose.production.yml"
  )
  [ -n "$postgres_image" ] || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  timeout 30s docker image inspect "$postgres_image" >/dev/null 2>&1 || {
    echo "PREREQUISITE_MISSING" >&2
    exit 77
  }
  timeout 30s python3 - "$ROOT_DIR/scripts/test-vps-provider-credential.py" \
    "$previous_image" "$target_image" <<'PY'
import json
import subprocess
import sys

helper, *images = sys.argv[1:]
for image in images:
    result = subprocess.run(
        ["docker", "image", "inspect", image],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    subprocess.run(
        ["python3", helper, "check-image"],
        check=True,
        input=result.stdout,
        text=True,
        stdout=subprocess.DEVNULL,
    )
PY

  matrix_fixture=$(mktemp -d /var/lib/meet-provider-image.XXXXXX)
  chmod 700 "$matrix_fixture"
  matrix_cleanup() {
    local status=$?
    trap - EXIT
    rm -r -- "$matrix_fixture"
    exit "$status"
  }
  trap matrix_cleanup EXIT

  run_image_case() (
    set -euo pipefail
    local case_name=$1
    local case_number=$2
    local rollback_run_key=$3
    local deploy_run_key=$4
    local provider_enabled=$5
    local case_root=/var/lib/meet-production
    local state_root=/var/lib/meet-test-vps-deploy/mee2-93-runtime-$case_name
    local case_log="$matrix_fixture/$case_name.log"
    local case_secret="RUNTIME_IMAGE_PRIVATE_SECRET_${case_name}_9f7d8d"
    local credential_email="runtime-image-$case_name@example.invalid"
    local app_port=$((18080 + case_number))
    local created_root=false
    local backend postgres observed
    local rollback_output rollback_status deploy_output deploy_status
    local rollback_capture="$matrix_fixture/$case_name-rollback.out"
    local deploy_capture="$matrix_fixture/$case_name-deploy.out"
    local previous_state target_state legacy_before legacy_after

    cleanup_case() {
      local status=$?
      local cleanup_status=0
      local pattern
      trap - EXIT
      set +e
      if [ "$created_root" = true ]; then
        timeout 300s docker compose -p meet-production \
          --project-directory "$case_root" \
          --env-file "$case_root/.env.production" \
          -f "$case_root/docker-compose.production.yml" \
          down --volumes --remove-orphans >>"$case_log" 2>&1 ||
          cleanup_status=1
        [ -z "$(timeout 30s docker ps -aq \
          --filter label=com.docker.compose.project=meet-production)" ] ||
          cleanup_status=1
        for resource in meet-production_default meet-production_postgres_data \
          meet-production_uploads_data; do
          if timeout 30s docker network inspect "$resource" >/dev/null 2>&1 ||
            timeout 30s docker volume inspect "$resource" >/dev/null 2>&1; then
            cleanup_status=1
          fi
        done
        for pattern in "$case_secret" "$credential_email" \
          '-----BEGIN PRIVATE KEY-----'; do
          if grep -R -F -n --binary-files=without-match "$pattern" \
            "$case_log" "$rollback_capture" "$deploy_capture" 2>/dev/null; then
            cleanup_status=1
          fi
        done
        rm -r -- "$case_root" "$state_root" || cleanup_status=1
        [ ! -e "$case_root" ] && [ ! -e "$state_root" ] ||
          cleanup_status=1
      fi
      [ "$status" -ne 0 ] || [ "$cleanup_status" -eq 0 ] ||
        status=1
      if [ "$status" -eq 0 ]; then
        printf 'image_runtime_cleanup case=%s containers=0 fixed_roots=0\\n' \
          "$case_name"
      fi
      exit "$status"
    }

    if [ -e "$case_root" ] || [ -L "$case_root" ] ||
      [ -e "$state_root" ] || [ -L "$state_root" ]; then
      echo "PREREQUISITE_MISSING: immutable runtime fixed root already exists" >&2
      exit 77
    fi
    if [ -n "$(timeout 30s docker ps -aq \
      --filter label=com.docker.compose.project=meet-production)" ]; then
      echo "PREREQUISITE_MISSING: meet-production containers already exist" >&2
      exit 77
    fi
    for resource in meet-production_default meet-production_postgres_data \
      meet-production_uploads_data; do
      if timeout 30s docker network inspect "$resource" >/dev/null 2>&1 ||
        timeout 30s docker volume inspect "$resource" >/dev/null 2>&1; then
        echo "PREREQUISITE_MISSING: fixed Compose resource already exists" >&2
        exit 77
      fi
    done

    trap cleanup_case EXIT
    install -d -m 700 "$case_root" "$state_root"
    created_root=true
    cp -- "$ROOT_DIR/docker-compose.production.yml" \
      "$case_root/docker-compose.production.yml"
    chmod 600 "$case_root/docker-compose.production.yml"
    cat >"$case_root/.env.production" <<EOF
APP_PORT=$app_port
BACKEND_MEMORY_LIMIT=768m
DOCKER_LOG_MAX_SIZE=10m
DOCKER_LOG_MAX_FILE=5
BACKEND_VERSION=$previous_version
BACKEND_REVISION=$previous_revision
BACKEND_IMAGE=$previous_image
DB_NAME=meet
DB_USERNAME=meet
DB_PASSWORD=runtime-db-password-$case_name
APP_JWT_SECRET=runtime-jwt-secret-$case_name-0123456789abcdef0123456789abcdef
APP_STORAGE_BASE_URL=http://127.0.0.1:$app_port/media
ADMIN_API_KEY=
APP_EMAIL_PROVIDER=smtp
APP_EMAIL_FROM=no-reply@example.invalid
APP_EMAIL_FROM_NAME=Meet
SPRING_MAIL_HOST=smtp.invalid
SPRING_MAIL_PORT=2525
SPRING_MAIL_USERNAME=runtime-smtp-user
SPRING_MAIL_PASSWORD=runtime-smtp-password
APP_EMAIL_CONNECT_TIMEOUT_MS=5000
APP_EMAIL_READ_TIMEOUT_MS=5000
APP_EMAIL_WRITE_TIMEOUT_MS=5000
APP_OTP_HMAC_CURRENT_KEY_ID=runtime-key
APP_OTP_HMAC_CURRENT_KEY_BASE64=cmVhbC1ydW50aW1lLWtleS1ieXRlcy1mb3ItdGVzdA==
APP_OTP_HMAC_PREVIOUS_KEY_ID=
APP_OTP_HMAC_PREVIOUS_KEY_BASE64=
APP_SMS_PROVIDER=disabled
APP_PUSH_PROVIDER_ENABLED=$provider_enabled
APP_PUSH_DISCOVERY_ENABLED=false
APP_PUSH_DISPATCH_ENABLED=false
APP_PUSH_DIAGNOSTIC_ENABLED=false
APP_PUSH_MAINTENANCE_ENABLED=false
APP_PUSH_PROJECT_ID=meeting-1d258
APP_PUSH_CREDENTIALS_FILE=$(
  if [ "$provider_enabled" = true ]; then
    printf '%s' /run/secrets/meet-firebase-service-account.json
  fi
)
INGESTION_ENABLED=false
INGESTION_CRON=
INGESTION_ZONE=
GEOCODER_ENABLED=false
LOCATIONIQ_KEY=
TIMEPAD_ENABLED=false
TIMEPAD_TOKEN=
TIMEPAD_CATEGORY_IDS=
TIMEPAD_KEYWORDS=
TIMEPAD_CITIES=
SPRINGDOC_API_DOCS_ENABLED=false
SPRINGDOC_SWAGGER_UI_ENABLED=false
EOF
    chmod 600 "$case_root/.env.production"
    if [ "$provider_enabled" = true ]; then
      install -d -m 700 "$case_root/credentials"
      cat >"$case_root/credentials/firebase-service-account.json" <<EOF
{"type":"service_account","project_id":"meeting-1d258","client_email":"$credential_email","client_id":"runtime-image-id","private_key_id":"runtime-image-key","private_key":"-----BEGIN PRIVATE KEY-----\n$case_secret\n-----END PRIVATE KEY-----","token_uri":"https://oauth2.example.invalid/token"}
EOF
      chown 0:10001 "$case_root/credentials/firebase-service-account.json"
      chmod 640 "$case_root/credentials/firebase-service-account.json"
    fi

    legacy_names=(
      31885558214-1-rollback-drill
      31886011287-1-rollback-drill
      31886542144-1-final-deploy
      31886542144-1-rollback-drill
      31887546557-1-final-deploy
      33076843662-1-final-deploy
      33076843662-1-rollback-drill
      35471104657-1-rollback-drill
    )
    legacy_digest() {
      local name path
      for name in "${legacy_names[@]}"; do
        path="$state_root/$name"
        find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l\n' | sort
        find "$path" -xdev -type f -exec sha256sum {} +
      done
    }
    for name in "${legacy_names[@]}"; do
      install -d -m 700 "$state_root/$name"
      printf 'legacy immutable-runtime bytes: %s\n' "$name" \
        >"$state_root/$name/opaque.bin"
      chmod 600 "$state_root/$name/opaque.bin"
    done
    legacy_before=$(legacy_digest)

    compose() {
      timeout 300s docker compose -p meet-production \
        --project-directory "$case_root" \
        --env-file "$case_root/.env.production" \
        -f "$case_root/docker-compose.production.yml" "$@"
    }
    check_capture_bound() {
      [ "$(wc -c <"$1")" -le 8388608 ]
    }
    compose up -d --wait --no-build --pull never >"$case_log" 2>&1
    check_capture_bound "$case_log"
    backend=$(compose ps -q backend)
    postgres=$(compose ps -q postgres)
    [ -n "$backend" ] && [ -n "$postgres" ]
    [ "$(docker inspect "$backend" --format '{{.Image}}')" = "$previous_id" ]
    [ "$(docker inspect "$postgres" --format '{{.State.Health.Status}}')" = healthy ]

    verify_case_runtime() {
      local expected_id=$1
      local expected_revision=$2
      local expected_version=$3
      local current_backend current_hash
      current_backend=$(compose ps -q backend)
      [ -n "$current_backend" ]
      current_hash=$(docker inspect "$current_backend" \
        --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
      timeout 90s bash -c '
        set -euo pipefail
        source "$1"
        verify_runtime_invariants "$2" "$3" "$4" "$5" "$6" "$7"
        verify_environment_matches_container "$2" "$3"
      ' _ "$ROOT_DIR/scripts/test-vps-runtime-invariants.sh" \
        "$case_root" "$ROOT_DIR/scripts/production-compose.sh" \
        "$expected_id" "$expected_revision" "$expected_version" \
        "$current_hash" >>"$case_log" 2>&1
    }

    observe_provider() {
      local current_backend
      current_backend=$(compose ps -q backend)
      docker inspect "$current_backend" |
        timeout 30s python3 "$ROOT_DIR/scripts/test-vps-provider-credential.py" observe
    }

    assert_provider_state() {
      local expected_enabled=$1
      observed=$(observe_provider)
      jq -e --argjson enabled "$expected_enabled" '
        type == "object" and .schemaVersion == 1 and
        .providerEnabled == $enabled and
        .credentialMountPresent == $enabled and
        .credentialMountReadOnly == $enabled and
        .outcome == "observed"
      ' <<<"$observed" >/dev/null
      printf 'provider_observed case=%s enabled=%s\n' \
        "$case_name" "$expected_enabled" >>"$case_log"
    }

    assert_terminal_state() {
      local state_path=$1
      local expected_outcome=$2
      local expected_enabled=$3
      jq -e --arg outcome "$expected_outcome" \
        --argjson enabled "$expected_enabled" \
        --arg run_key "${state_path##*/}" '
        .schemaVersion == 1 and .runKey == ($run_key
          | sub("-(rollback-drill|final-deploy)$"; "")) and
        .outcome == $outcome and .providerEnabled == $enabled and
        (.providerEnabled | type == "boolean")
      ' "$state_path/terminal.json" >/dev/null
      [ -f "$state_path/provider-owner.json" ]
      timeout 30s python3 "$ROOT_DIR/scripts/test-vps-provider-credential.py" \
        retention-list --state-root "$state_root" >/dev/null
    }

    scan_case_secrets() {
      local pattern container
      for pattern in "$case_secret" "$credential_email" \
        '-----BEGIN PRIVATE KEY-----'; do
        if grep -R -F -n --binary-files=without-match "$pattern" \
          "$case_log" "$state_root" "$case_root/.env.production" \
          "$case_root/docker-compose.production.yml" \
          "$case_root/active-compose.yml" \
          "$case_root/active-runtime.override.yml" 2>/dev/null; then
          echo "runtime fixture leaked synthetic credential material" >&2
          return 1
        fi
        for container in $(compose ps -q backend) $(compose ps -q postgres); do
          if timeout 30s docker logs "$container" 2>&1 |
            grep -F -- "$pattern" >/dev/null; then
            return 1
          fi
        done
      done
    }

    run_coordinator() {
      timeout 1200s env TEST_VPS_STATE_ROOT="$state_root" \
        bash "$ROOT_DIR/scripts/deploy-test-vps-provider-release.sh" \
        --root "$case_root" \
        --base-compose "$case_root/docker-compose.production.yml" \
        --image "$1" --revision "$2" --version "$3" \
        --run-key "$4" --mode "$5"
    }

    set +e
    run_coordinator "$target_image" "$target_revision" \
      "$target_version" "$rollback_run_key" rollback-drill \
      >"$rollback_capture" 2>&1
    rollback_status=$?
    set -e
    check_capture_bound "$rollback_capture"
    rollback_output=$(<"$rollback_capture")
    printf '%s\n' "$rollback_output" >>"$case_log"
    check_capture_bound "$case_log"
    [ "$rollback_status" -eq 86 ]
    grep -Fq 'candidate=ready' <<<"$rollback_output"
    grep -Fq 'rollback=completed previous_image_id=' <<<"$rollback_output"
    previous_state="$state_root/$rollback_run_key-rollback-drill"
    assert_terminal_state "$previous_state" rolled-back "$provider_enabled"
    verify_case_runtime "$previous_id" "$previous_revision" "$previous_version"
    assert_provider_state "$provider_enabled"
    [ "$(grep '^BACKEND_IMAGE=' "$case_root/.env.production")" = \
      "BACKEND_IMAGE=$previous_image" ]
    legacy_after=$(legacy_digest)
    [ "$legacy_before" = "$legacy_after" ]

    set +e
    run_coordinator "$target_image" "$target_revision" \
      "$target_version" "$deploy_run_key" deploy \
      >"$deploy_capture" 2>&1
    deploy_status=$?
    set -e
    check_capture_bound "$deploy_capture"
    deploy_output=$(<"$deploy_capture")
    printf '%s\n' "$deploy_output" >>"$case_log"
    check_capture_bound "$case_log"
    [ "$deploy_status" -eq 0 ]
    grep -Fq 'candidate=ready' <<<"$deploy_output"
    grep -Fq 'deployment=completed image_id=' <<<"$deploy_output"
    target_state="$state_root/$deploy_run_key-final-deploy"
    assert_terminal_state "$target_state" committed "$provider_enabled"
    backend=$(compose ps -q backend)
    [ "$(docker inspect "$backend" --format '{{.Image}}')" = "$target_id" ]
    verify_case_runtime "$target_id" "$target_revision" "$target_version"
    assert_provider_state "$provider_enabled"
    [ "$(grep '^BACKEND_IMAGE=' "$case_root/.env.production")" = \
      "BACKEND_IMAGE=$target_image" ]
    legacy_after=$(legacy_digest)
    [ "$legacy_before" = "$legacy_after" ]
    scan_case_secrets
    printf 'image_runtime case=%s previous_id=%s target_id=%s cleanup=pending\n' \
      "$case_name" "$previous_id" "$target_id"
  )

  run_image_case disabled 1 930000001-1 930000002-1 false
  run_image_case enabled 2 930000003-1 930000004-1 true
  trap - EXIT
  rm -r -- "$matrix_fixture"
fi

fixture=$(mktemp -d /var/lib/meet-provider-fixture.XXXXXX)
chmod 700 "$fixture"
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$fixture"
  exit "$status"
}
trap cleanup EXIT

fixture_log="$fixture/output.log"
fixture_secret=RUNTIME_FIXTURE_PRIVATE_SECRET_9f7d8d
if ! python3 - "$fixture" >"$fixture_log" 2>&1 <<'PY'
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import struct
import sys
import tempfile

fixture = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "provider_helper", pathlib.Path("scripts/test-vps-provider-credential.py")
)
assert spec is not None and spec.loader is not None
helper = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helper
spec.loader.exec_module(helper)

parent = fixture / "credentials"
parent.mkdir(mode=0o700)
os.chown(parent, 0, 0)
source = fixture / "predecessor.json"
account = {
    "type": "service_account",
    "project_id": helper.EXPECTED_PROJECT,
    "client_email": "runtime-fixture@example.invalid",
    "client_id": "runtime-fixture-id",
    "private_key_id": "runtime-fixture-key",
    "private_key": "-----BEGIN PRIVATE KEY-----\nRUNTIME_FIXTURE_PRIVATE_SECRET_9f7d8d\n-----END PRIVATE KEY-----",
    "token_uri": "https://oauth2.example.invalid/token",
}
source.write_text(json.dumps(account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)

helper.HOST_CREDENTIAL_PARENT = str(parent)
helper.HOST_CREDENTIAL_PATH = str(parent / "firebase-service-account.json")
helper.CONTAINER_CREDENTIAL_PATH = "/run/secrets/meet-firebase-service-account.json"
state = fixture / "state"
state.mkdir(mode=0o700)
os.chown(state, 0, 0)
marker = state / ".provider-transaction.current"

published_root = fixture / "published-states"
published_root.mkdir(mode=0o700)
os.chown(published_root, 0, 0)
helper._state_publish(str(published_root), "123456789-1", "final-deploy")
published_state = published_root / "123456789-1-final-deploy"
assert (published_state / helper.OWNER_MARKER).read_bytes() == helper._state_marker(
    "123456789-1", "final-deploy"
)
expect_collision = published_root / "456-1-final-deploy"
expect_collision.mkdir(mode=0o700)
os.chown(expect_collision, 0, 0)
try:
    helper._state_publish(str(published_root), "456-1", "final-deploy")
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("state publication accepted an invalid run key")

def prepare_marker(run_key: str) -> None:
    helper._write_private(
        str(marker),
        json.dumps(
            {
                "schemaVersion": 1,
                "runKey": run_key,
                "phase": "preparing",
                "providerEnabled": True,
                "durableDisposition": "none",
            },
            separators=(",", ":"),
        ).encode(),
        0o600,
    )

def cleanup_transaction(run_key: str, remove_destination: bool = True) -> None:
    marker.unlink(missing_ok=True)
    shutil.rmtree(parent / f".transaction-{run_key}", ignore_errors=True)
    if remove_destination:
        pathlib.Path(helper.HOST_CREDENTIAL_PATH).unlink(missing_ok=True)

def acl(entries: list[tuple[int, int, int]]) -> bytes:
    return struct.pack("<I", 2) + b"".join(
        struct.pack("<HHI", tag, permission, identifier)
        for tag, permission, identifier in entries
    )

def add_default_acl(path: pathlib.Path) -> None:
    os.setxattr(
        path,
        "system.posix_acl_default",
        acl(
            [
                (1, 7, 0xFFFFFFFF),
                (2, 4, 20002),
                (4, 5, 0xFFFFFFFF),
                (16, 5, 0xFFFFFFFF),
                (32, 5, 0xFFFFFFFF),
            ]
        ),
    )

def add_private_access_acl(path: pathlib.Path) -> None:
    os.setxattr(
        path,
        "system.posix_acl_access",
        acl(
            [
                (1, 0, 0xFFFFFFFF),
                (2, 4, 20002),
                (4, 0, 0xFFFFFFFF),
                (16, 0, 0xFFFFFFFF),
                (32, 0, 0xFFFFFFFF),
            ]
        ),
    )

def remove_acl(path: pathlib.Path, attribute: str) -> None:
    try:
        os.removexattr(path, attribute)
    except OSError as error:
        if error.errno != 61:
            raise

def expect_provider_error(action, category: str) -> None:
    try:
        action()
    except helper.ProviderError as error:
        assert error.category == category, error.category
    else:
        raise AssertionError(f"expected {category}")

def deny_unprivileged_read(path: pathlib.Path) -> None:
    child = os.fork()
    if child == 0:
        try:
            os.setgroups([])
            os.setgid(20002)
            os.setuid(20002)
            with path.open("rb"):
                os._exit(0)
        except OSError:
            os._exit(1)
    _, status = os.waitpid(child, 0)
    assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 1

def inspect(source_path: pathlib.Path) -> dict:
    return {
        "Config": {
            "Env": [
                "APP_PUSH_PROVIDER_ENABLED=true",
                "APP_PUSH_DISCOVERY_ENABLED=false",
                "APP_PUSH_DISPATCH_ENABLED=false",
                "APP_PUSH_DIAGNOSTIC_ENABLED=false",
                "APP_PUSH_MAINTENANCE_ENABLED=false",
                "APP_PUSH_PROJECT_ID=meeting-1d258",
                "APP_PUSH_CREDENTIALS_FILE=/run/secrets/meet-firebase-service-account.json",
            ]
        },
        "Mounts": [
            {"Type": "volume", "Destination": "/data/uploads"},
            {"Type": "tmpfs", "Destination": "/tmp"},
            {
                "Type": "bind",
                "Source": str(source_path),
                "Destination": "/run/secrets/meet-firebase-service-account.json",
                "RW": False,
            },
        ],
    }

predecessor = inspect(source)
add_default_acl(parent)
assert os.getxattr(parent, "system.posix_acl_default")
expect_provider_error(
    lambda: helper._acl_is_safe(str(parent)),
    "CREDENTIAL_INVALID",
)
expect_provider_error(
    lambda: helper._prepare(
        "default-acl-parent", str(state), "", json.dumps(predecessor).encode()
    ),
    "CREDENTIAL_INVALID",
)
remove_acl(parent, "system.posix_acl_default")
assert not (parent / ".transaction-default-acl-parent").exists()

prepare_marker("race-disappearance")
original_read_existing = helper._read_existing
race_removed = False

def remove_destination_before_read(path: str, source: bool = False):
    global race_removed
    if path == helper.HOST_CREDENTIAL_PATH and not source and not race_removed:
        race_removed = True
        pathlib.Path(path).unlink()
    return original_read_existing(path, source=source)

helper._read_existing = remove_destination_before_read
expect_provider_error(
    lambda: helper._prepare(
        "race-disappearance", str(state), "", json.dumps(predecessor).encode()
    ),
    "CREDENTIAL_INVALID",
)
helper._read_existing = original_read_existing
assert not pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert (parent / ".transaction-race-disappearance" / "snapshot").exists()
assert json.loads(marker.read_text())["durableDisposition"] == "none"
cleanup_transaction("race-disappearance")

prepare_marker("race-appearance")
original_link = helper.os.link

def create_raced_destination(source_path: str, destination_path: str, **kwargs):
    fd = os.open(destination_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o440)
    try:
        os.write(fd, source.read_bytes())
        os.fchown(fd, 0, 10001)
        os.fchmod(fd, 0o440)
    finally:
        os.close(fd)
    raise FileExistsError(17, "destination appeared", destination_path)

helper.os.link = create_raced_destination
expect_provider_error(
    lambda: helper._prepare(
        "race-appearance", str(state), "", json.dumps(predecessor).encode()
    ),
    "DURABLE_CONFLICT",
)
helper.os.link = original_link
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert (parent / ".transaction-race-appearance" / "publication").exists()
assert json.loads(marker.read_text())["durableDisposition"] == "none"
cleanup_transaction("race-appearance")

prepare_marker("source-drift")
helper._prepare("source-drift", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "source-drift",
            "phase": "prepared",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
changed_account = dict(account)
changed_account["client_id"] = "runtime-fixture-changed-id"
source.write_text(json.dumps(changed_account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)
expect_provider_error(
    lambda: helper._verify(
        "source-drift",
        "",
        json.dumps([predecessor, predecessor]).encode(),
        "predecessor",
        str(state),
    ),
    "CREDENTIAL_CHANGED",
)
source.write_text(json.dumps(account), encoding="utf-8")
os.chown(source, 0, 10001)
os.chmod(source, 0o640)
cleanup_transaction("source-drift")

prepare_marker("witness-removal")
helper._prepare("witness-removal", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "witness-removal",
            "phase": "verifying",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
(parent / ".transaction-witness-removal" / "publication").unlink()
candidate = inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))
expect_provider_error(
    lambda: helper._verify(
        "witness-removal",
        "",
        json.dumps([predecessor, candidate]).encode(),
        "candidate",
        str(state),
    ),
    "RECOVERY_REQUIRED",
)
cleanup_transaction("witness-removal")

prepare_marker("marker-drift")
helper._prepare("marker-drift", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "marker-drift",
            "phase": "prepared",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
expect_provider_error(
    lambda: helper._verify(
        "marker-drift",
        "",
        json.dumps([predecessor, candidate]).encode(),
        "candidate",
        str(state),
    ),
    "RECOVERY_REQUIRED",
)
cleanup_transaction("marker-drift")

prepare_marker("created")
helper._prepare("created", str(state), "", json.dumps(predecessor).encode())
assert json.loads(marker.read_text())["durableDisposition"] == "created"
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "created",
            "phase": "verifying",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
deny_unprivileged_read(parent / ".transaction-created" / "snapshot")
deny_unprivileged_read(parent / ".transaction-created" / "identity.json")
add_default_acl(parent / ".transaction-created")
expect_provider_error(
    lambda: helper._verify(
        "created",
        "",
        json.dumps([predecessor, inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))]).encode(),
        "candidate",
    ),
    "RECOVERY_REQUIRED",
)
remove_acl(parent / ".transaction-created", "system.posix_acl_default")
add_private_access_acl(parent / ".transaction-created" / "snapshot")
expect_provider_error(
    lambda: helper._verify(
        "created",
        "",
        json.dumps([predecessor, inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))]).encode(),
        "candidate",
    ),
    "RECOVERY_REQUIRED",
)
remove_acl(parent / ".transaction-created" / "snapshot", "system.posix_acl_access")
os.chmod(parent / ".transaction-created" / "snapshot", 0o600)
candidate = inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))
helper._verify(
    "created",
    "",
    json.dumps([predecessor, candidate]).encode(),
    "candidate",
)
helper._finish("created", str(state), "", "committed", json.dumps(candidate).encode())
marker.unlink()
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
assert not (parent / ".transaction-created").exists()

prepare_marker("reused")
helper._prepare("reused", str(state), "", json.dumps(predecessor).encode())
assert json.loads(marker.read_text())["durableDisposition"] == "reused"
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "reused",
            "phase": "finalizing",
            "providerEnabled": True,
            "durableDisposition": "reused",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
helper._finish("reused", str(state), "", "committed", json.dumps(candidate).encode())
marker.unlink()
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()

os.unlink(helper.HOST_CREDENTIAL_PATH)
prepare_marker("rollback")
helper._prepare("rollback", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "rollback",
            "phase": "rolling-back",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
helper._finish("rollback", str(state), "", "rolled-back", json.dumps(predecessor).encode())
assert not pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
marker.unlink()

prepare_marker("witness-tamper")
helper._prepare("witness-tamper", str(state), "", json.dumps(predecessor).encode())
marker.unlink()
helper._write_private(
    str(marker),
    json.dumps(
        {
            "schemaVersion": 1,
            "runKey": "witness-tamper",
            "phase": "finalizing",
            "providerEnabled": True,
            "durableDisposition": "created",
        },
        separators=(",", ":"),
    ).encode(),
    0o600,
)
os.chmod(parent / ".transaction-witness-tamper" / "publication", 0o600)
try:
    helper._finish(
        "witness-tamper",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    )
except helper.ProviderError as error:
    assert error.category == "RECOVERY_REQUIRED"
else:
    raise AssertionError("tampered publication witness was accepted")
cleanup_transaction("witness-tamper")

def prepare_finalizing(run_key: str) -> dict:
    prepare_marker(run_key)
    helper._prepare(run_key, str(state), "", json.dumps(predecessor).encode())
    marker.unlink()
    helper._write_private(
        str(marker),
        json.dumps(
            {
                "schemaVersion": 1,
                "runKey": run_key,
                "phase": "finalizing",
                "providerEnabled": True,
                "durableDisposition": "created",
            },
            separators=(",", ":"),
        ).encode(),
        0o600,
    )
    return inspect(pathlib.Path(helper.HOST_CREDENTIAL_PATH))

def finish_and_remove(run_key: str, candidate: dict) -> None:
    helper._finish(
        run_key,
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    )
    marker.unlink()
    assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).exists()
    cleanup_transaction(run_key)

candidate = prepare_finalizing("cleanup-hard-link")
hard_link = parent / "operator-hard-link"
os.link(helper.HOST_CREDENTIAL_PATH, hard_link)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-hard-link",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert hard_link.exists()
hard_link.unlink()
cleanup_transaction("cleanup-hard-link")

candidate = prepare_finalizing("cleanup-metadata")
os.chmod(helper.HOST_CREDENTIAL_PATH, 0o600)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-metadata",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
os.chmod(helper.HOST_CREDENTIAL_PATH, 0o440)
cleanup_transaction("cleanup-metadata")

candidate = prepare_finalizing("cleanup-replacement")
os.unlink(helper.HOST_CREDENTIAL_PATH)
replacement = parent / "operator-replacement"
replacement.write_bytes(b"operator replacement")
os.chown(replacement, 0, 10001)
os.chmod(replacement, 0o440)
os.rename(replacement, helper.HOST_CREDENTIAL_PATH)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-replacement",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).read_bytes() == b"operator replacement"
cleanup_transaction("cleanup-replacement")

candidate = prepare_finalizing("cleanup-symlink")
os.unlink(helper.HOST_CREDENTIAL_PATH)
os.symlink(source, helper.HOST_CREDENTIAL_PATH)
expect_provider_error(
    lambda: helper._finish(
        "cleanup-symlink",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
assert pathlib.Path(helper.HOST_CREDENTIAL_PATH).is_symlink()
cleanup_transaction("cleanup-symlink")

candidate = prepare_finalizing("cleanup-unlink-race")
original_unlink = helper.os.unlink

def reject_descriptor_unlink(path, **kwargs):
    if kwargs.get("dir_fd") is not None:
        raise OSError(11, "operator replacement race")
    return original_unlink(path, **kwargs)

helper.os.unlink = reject_descriptor_unlink
expect_provider_error(
    lambda: helper._finish(
        "cleanup-unlink-race",
        str(state),
        "",
        "committed",
        json.dumps(candidate).encode(),
    ),
    "RECOVERY_REQUIRED",
)
helper.os.unlink = original_unlink
finish_and_remove("cleanup-unlink-race", candidate)

for child in ("identity.json", "snapshot", "publication"):
    run_key = "cleanup-same-metadata-" + child.replace(".", "-")
    candidate = prepare_finalizing(run_key)
    tx = parent / (".transaction-" + run_key)
    original_witness = helper._child_witness
    replaced = [False]

    def replace_transaction_child(directory_fd, name, **kwargs):
        result = original_witness(directory_fd, name, **kwargs)
        if name == child and not replaced[0]:
            replacement = fixture / ("replacement-" + run_key)
            data = (tx / child).read_bytes()
            info = os.stat(tx / child, follow_symlinks=False)
            os.unlink(tx / child)
            replacement.write_bytes(data)
            os.chown(replacement, info.st_uid, info.st_gid)
            os.chmod(replacement, stat.S_IMODE(info.st_mode))
            os.rename(replacement, tx / child)
            replaced[0] = True
        return result

    helper._child_witness = replace_transaction_child
    expect_provider_error(
        lambda: helper._finish(
            run_key,
            str(state),
            "",
            "committed",
            json.dumps(candidate).encode(),
        ),
        "RECOVERY_REQUIRED",
    )
    helper._child_witness = original_witness
    assert (tx / child).exists()
    assert marker.exists()
    shutil.rmtree(tx)
    marker.unlink()
    pathlib.Path(helper.HOST_CREDENTIAL_PATH).unlink(missing_ok=True)

retention_root = fixture / "retention-root"
retention_root.mkdir(mode=0o700)
os.chown(retention_root, 0, 0)
for child in sorted(helper.RETENTION_CHILDREN - {"provider-owner.json", "terminal.json"}):
    retention_state = retention_root / "77-1-final-deploy"
    retention_state.mkdir(mode=0o700)
    os.chown(retention_state, 0, 0)
    for state_child in helper.RETENTION_CHILDREN:
        path = retention_state / state_child
        if state_child == "provider-owner.json":
            path.write_bytes(
                helper._state_marker("77-1", "final-deploy")
            )
        elif state_child == "terminal.json":
            path.write_bytes(
                b'{"schemaVersion":1,"runKey":"77-1","outcome":"committed","providerEnabled":false}'
            )
        else:
            path.write_bytes(("retention-" + state_child).encode())
        os.chown(path, 0, 0)
        os.chmod(path, 0o600)
    original_witness = helper._child_witness
    replaced = [False]

    def replace_retention_child(directory_fd, name, **kwargs):
        result = original_witness(directory_fd, name, **kwargs)
        if name == child and not replaced[0]:
            replacement = fixture / ("retention-replacement-" + child.replace(".", "-"))
            data = (retention_state / child).read_bytes()
            os.unlink(retention_state / child)
            replacement.write_bytes(data)
            os.chown(replacement, 0, 0)
            os.chmod(replacement, 0o600)
            os.rename(replacement, retention_state / child)
            replaced[0] = True
        return result

    helper._child_witness = replace_retention_child
    expect_provider_error(
        lambda: helper._retention_delete(
            str(retention_root),
            str(retention_state),
        ),
        "RECOVERY_REQUIRED",
    )
    helper._child_witness = original_witness
    quarantine = retention_root / ".provider-state.77-1-final-deploy.tmp"
    assert not retention_state.exists()
    assert quarantine.exists()
    shutil.rmtree(quarantine)

def retention_snapshot(path):
    snapshot = []
    for entry in sorted(path.rglob("*")):
        info = os.lstat(entry)
        data = entry.read_bytes() if stat.S_ISREG(info.st_mode) else None
        snapshot.append(
            (
                str(entry.relative_to(path)),
                info.st_mode,
                info.st_uid,
                info.st_gid,
                info.st_nlink,
                data,
            )
        )
    return snapshot

def valid_retention_state(name):
    path = retention_root / name
    path.mkdir(mode=0o700)
    os.chown(path, 0, 0)
    marker_path = path / "provider-owner.json"
    marker_path.write_bytes(helper._state_marker(*helper._state_parts(name)))
    terminal_path = path / "terminal.json"
    terminal_path.write_bytes(
        (
            (
                '{"schemaVersion":1,"runKey":"%s","outcome":"committed",'
                '"providerEnabled":false}'
            )
            % helper._state_parts(name)[0]
        ).encode()
    )
    for child in (marker_path, terminal_path):
        os.chown(child, 0, 0)
        os.chmod(child, 0o600)
    return path

def assert_direct_retention_refusal(path, **kwargs):
    before = retention_snapshot(path)
    quarantine = retention_root / (".provider-state." + path.name + ".tmp")
    quarantine_before = quarantine.exists()
    expect_provider_error(
        lambda: helper._retention_delete(
            str(retention_root),
            str(path),
            **kwargs,
        ),
        "RECOVERY_REQUIRED",
    )
    assert retention_snapshot(path) == before
    assert quarantine.exists() == quarantine_before

protected_state = valid_retention_state("88-1-final-deploy")
assert_direct_retention_refusal(
    protected_state,
    protected_states=[str(protected_state)],
)
shutil.rmtree(protected_state)

interlocked_state = valid_retention_state("89-1-final-deploy")
helper._write_private(
    str(retention_root / ".provider-transaction.current"),
    b"blocking",
    0o600,
)
assert_direct_retention_refusal(interlocked_state)
(retention_root / ".provider-transaction.current").unlink()

reserved = retention_root / ".provider-state.89-1-final-deploy.tmp"
reserved.mkdir(mode=0o700)
os.chown(reserved, 0, 0)
assert_direct_retention_refusal(interlocked_state)
shutil.rmtree(reserved)

parent_transaction = parent / ".transaction-retention-interlock"
parent_transaction.mkdir(mode=0o700)
os.chown(parent_transaction, 0, 0)
assert_direct_retention_refusal(interlocked_state)
shutil.rmtree(parent_transaction)
shutil.rmtree(interlocked_state)

malformed_marker = {
    "schemaVersion": True,
    "runKey": "boolean-marker",
    "phase": "preparing",
    "providerEnabled": True,
    "durableDisposition": "none",
}
helper._write_private(
    str(marker),
    json.dumps(malformed_marker, separators=(",", ":")).encode(),
    0o600,
)
marker_bytes = marker.read_bytes()
expect_provider_error(
    lambda: helper._marker(str(state), "boolean-marker"),
    "RECOVERY_REQUIRED",
)
assert marker.read_bytes() == marker_bytes
marker.unlink()
PY
then
  echo "provider runtime fixture failed" >&2
  sed -n '1,160p' "$fixture_log" >&2
  exit 1
fi
! grep -Fq "$fixture_secret" "$fixture_log" ||
  { echo "provider runtime fixture leaked private credential bytes" >&2; exit 1; }

python3 -B scripts/test-test-vps-provider-credential.py
echo "provider filesystem fixture passed: ACL/default-ACL rejection, unprivileged private-read denial, bounded parsing, no-follow publication, reuse and rollback cleanup; secret scan passed"
