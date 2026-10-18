#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

is_supported_test_vps_version() {
  local version=${1:-}
  local major minor patch
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    return 1
  IFS=. read -r major minor patch <<<"$version"
  (( major > 1 ||
    (major == 1 && (minor > 2 || (minor == 2 && patch >= 0))) ))
}

usage() {
  echo "usage: $0 --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill [--operation deploy|bootstrap-guard|forward-recover --rollout-domain initial-domain|timepad-first-transition --initial-proof-id ID --bootstrap-id ID --recovery-run-key KEY --recovery-incident ID --recovery-epoch N --recovery-binding-digest SHA256 --recovery-action retry-exact-candidate] [--closed-beta-safety --state-mode empty-closed|closed-beta-demo] [--public-url https://HOST]" >&2
  exit 2
}

fail() {
  echo "test VPS deployment failed: $1" >&2
  exit 1
}

verify_production_env_settings() {
  timeout 30s python3 - "$1" <<'PY'
import os
import re
import stat
import sys

path = sys.argv[1]
info = os.lstat(path)
if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
    raise SystemExit(1)
data = open(path, "rb").read(1024 * 1024 + 1)
if len(data) > 1024 * 1024:
    raise SystemExit(1)
try:
    text = data.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)

push_keys = {
    "APP_PUSH_PROVIDER_ENABLED",
    "APP_PUSH_DISCOVERY_ENABLED",
    "APP_PUSH_DISPATCH_ENABLED",
    "APP_PUSH_DIAGNOSTIC_ENABLED",
    "APP_PUSH_MAINTENANCE_ENABLED",
    "APP_PUSH_PROJECT_ID",
    "APP_PUSH_CREDENTIALS_FILE",
}
alternate = {
    "SPRING_APPLICATION_JSON",
    "SPRING_CONFIG_LOCATION",
    "SPRING_CONFIG_ADDITIONAL_LOCATION",
    "SPRING_CONFIG_IMPORT",
    "SPRING_CONFIG_NAME",
    "SPRING_CONFIG_DATA_LOCATION",
}
seen = set()
for raw in text.splitlines():
    line = raw.rstrip("\r")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", line)
    if match is None:
        raise SystemExit(1)
    key, value = match.groups()
    normalized = key.upper().replace("-", "_").replace(".", "_")
    if normalized in push_keys:
        if key != normalized or key in seen:
            raise SystemExit(1)
        seen.add(key)
    if normalized in alternate:
        raise SystemExit(1)
    if key in {"JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"}:
        lowered = value.lower()
        if any(
            token in lowered
            for token in (
                "app.push",
                "spring.application.json",
                "spring.config.location",
                "spring.config.additional-location",
                "spring.config.import",
                "spring.config.name",
                "spring.config.data.location",
            )
        ):
            raise SystemExit(1)
PY
}

verify_public_contract() {
  local public_url=${1:-}
  [ -n "$public_url" ] || return 0
  local meetings_probe actuator_status redirect_headers redirect_status
  meetings_probe=$(timeout 30s curl --silent --connect-timeout 5 \
    --max-time 15 --write-out $'\n%{http_code}' \
    "$public_url/meetings" 2>/dev/null |
    timeout 5s python3 -c '
import json
import sys

data = sys.stdin.buffer.read(8 * 1024 * 1024 + 64)
body, separator, status = data.rpartition(b"\n")
if not separator or len(body) > 8 * 1024 * 1024 or status != b"200":
    raise SystemExit(1)
try:
    value = json.loads(body.decode("utf-8"))
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, list):
    raise SystemExit(1)
print("meetings_status=200 meetings_array=true")
') || fail "public meetings probe failed"
  [ "$meetings_probe" = "meetings_status=200 meetings_array=true" ] ||
    fail "public meetings probe failed"
  actuator_status=$(curl --silent --show-error --connect-timeout 5 \
    --max-time 15 --output /dev/null --write-out '%{http_code}' \
    "$public_url/actuator" 2>/dev/null) || fail "public actuator probe failed"
  [ "$actuator_status" = 404 ] || fail "public actuator probe failed"
  redirect_headers=$(curl --silent --connect-timeout 5 --max-time 15 \
    --dump-header - --output /dev/null --write-out '%{http_code}' \
    "${public_url/https:\/\//http://}/meetings" 2>/dev/null) ||
    fail "public redirect probe failed"
  redirect_status=${redirect_headers: -3}
  case "$redirect_status" in 301|302|307|308) ;; *)
    fail "public redirect probe failed"
    ;;
  esac
  grep -Eiq '^location:[[:space:]]+https://' <<<"$redirect_headers" ||
    fail "public redirect probe failed"
  local missing_admin wrong_admin
  missing_admin=$(curl --silent --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'Content-Type: application/json' --data '{}' 2>/dev/null) ||
    fail "admin guard probe failed"
  wrong_admin=$(curl --silent --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' -X POST \
    "$public_url/admin/demo-catalog/bootstrap" \
    -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' \
    --data '{}' 2>/dev/null) || fail "admin guard probe failed"
  [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] ||
    fail "admin guard probe failed"
}

runtime_release_field_bounded() {
  timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_release_field "$2" "$3"
  ' _ "$runtime_helper" "$root" "$1"
}

configuration_file_identity() {
  timeout 30s python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

path = sys.argv[1]
try:
    if os.path.islink(path):
        raise OSError(40, "symlink")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
except OSError:
    raise SystemExit(1)
try:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit(1)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(fd, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    print(
        f"{info.st_dev}:{info.st_ino}:{info.st_mode}:{info.st_uid}:"
        f"{info.st_gid}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}:"
        f"{digest.hexdigest()}"
    )
finally:
    os.close(fd)
PY
}

snapshot_configuration() {
  local source snapshot identity
  for source in "$root/.env.production" "$base_compose"; do
    case "$source" in
      "$root/.env.production") snapshot="$state/config.env.production" ;;
      "$base_compose") snapshot="$state/config.base-compose.yml" ;;
      *) fail "PROVIDER_STATE_INVALID" ;;
    esac
    identity=$(configuration_file_identity "$source") ||
      fail "PROVIDER_STATE_INVALID"
    timeout 30s install -m 600 "$source" "$snapshot" ||
      fail "PROVIDER_STATE_INVALID"
    cmp -s "$source" "$snapshot" ||
      fail "PROVIDER_STATE_INVALID"
    [ "$(configuration_file_identity "$source")" = "$identity" ] ||
      fail "PROVIDER_STATE_INVALID"
    printf '%s\n' "$identity" >"$snapshot.identity"
    chmod 600 "$snapshot.identity"
  done
}

validate_configuration_boundary() {
  local expected_env=$1
  local source expected expected_identity expected_value
  [ -f "$expected_env" ] && [ ! -L "$expected_env" ] ||
    fail "PROVIDER_STATE_INVALID"
  for source in "$root/.env.production" "$base_compose"; do
    case "$source" in
      "$root/.env.production")
        expected=$expected_env
        case "$expected_env" in
          "$state/config.env.production") expected_identity="$state/config.env.production.identity" ;;
          "$state/config.env.target") expected_identity="$state/config.env.target.identity" ;;
          "$state/config.env.previous") expected_identity="$state/config.env.previous.identity" ;;
          *) fail "PROVIDER_STATE_INVALID" ;;
        esac
        ;;
      "$base_compose")
        expected="$state/config.base-compose.yml"
        expected_identity="$state/config.base-compose.yml.identity"
        ;;
      *) fail "PROVIDER_STATE_INVALID" ;;
    esac
    cmp -s "$source" "$expected" ||
      fail "PROVIDER_STATE_INVALID"
    [ -s "$expected_identity" ] ||
      fail "PROVIDER_STATE_INVALID"
    expected_value=$(<"$expected_identity")
    [ "$(configuration_file_identity "$source")" = "$expected_value" ] ||
      fail "PROVIDER_STATE_INVALID"
  done
}

make_environment_candidate() {
  timeout 30s python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import os
import pathlib
import re
import sys

source, destination, image, revision, version = sys.argv[1:]
data = pathlib.Path(source).read_bytes().decode("utf-8")
replacements = {
    "BACKEND_IMAGE": image,
    "BACKEND_REVISION": revision,
    "BACKEND_VERSION": version,
}
seen = set()
lines = []
for line in data.splitlines(keepends=True):
    match = re.match(r"^(BACKEND_IMAGE|BACKEND_REVISION|BACKEND_VERSION)=", line)
    if match:
        key = match.group(1)
        if key in seen:
            raise SystemExit(1)
        seen.add(key)
        line_without_ending = line.rstrip("\r\n")
        line_ending = line[len(line_without_ending):]
        lines.append(f"{key}={replacements[key]}{line_ending}")
    else:
        lines.append(line)
if seen != set(replacements):
    raise SystemExit(1)
path = pathlib.Path(destination)
fd = os.open(
    path,
    os.O_WRONLY
    | os.O_CREAT
    | os.O_EXCL
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_BINARY", 0),
    0o600,
)
try:
    os.write(fd, "".join(lines).encode("utf-8"))
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

active_file_identity() {
  local file=$1
  configuration_file_identity "$file"
}

snapshot_active_file() {
  local file=$1
  local name=$2
  local identity
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || fail "PROVIDER_STATE_INVALID"
    identity=$(active_file_identity "$file") || fail "PROVIDER_STATE_INVALID"
    printf '%s\n' "$identity" >"$state/previous-active-$name.identity"
    timeout 30s install -m 600 "$file" "$state/previous-active-$name.yml" ||
      fail "PROVIDER_STATE_INVALID"
    cmp -s "$file" "$state/previous-active-$name.yml" ||
      fail "PROVIDER_STATE_INVALID"
    [ "$(active_file_identity "$file")" = "$identity" ] ||
      fail "PROVIDER_STATE_INVALID"
    : >"$state/had-active-$name"
  fi
}

validate_active_files_before_writers() {
  local name file expected actual
  for name in compose runtime; do
    if [ -e "$state/had-active-$name" ]; then
      case "$name" in
        compose) file=$active_compose ;;
        runtime) file=$active_runtime ;;
        *) fail "PROVIDER_STATE_INVALID" ;;
      esac
      expected=$(<"$state/previous-active-$name.identity")
      actual=$(active_file_identity "$file") ||
        fail "PROVIDER_STATE_INVALID"
      [ "$actual" = "$expected" ] || fail "PROVIDER_STATE_INVALID"
      cmp -s "$file" "$state/previous-active-$name.yml" ||
        fail "PROVIDER_STATE_INVALID"
    else
      case "$name" in
        compose) file=$active_compose ;;
        runtime) file=$active_runtime ;;
        *) fail "PROVIDER_STATE_INVALID" ;;
      esac
      [ ! -e "$file" ] && [ ! -L "$file" ] ||
        fail "PROVIDER_STATE_INVALID"
    fi
  done
}

record_candidate_active_file() {
  local file=$1
  local name=$2
  local identity
  [ -f "$file" ] && [ ! -L "$file" ] ||
    fail "RECOVERY_REQUIRED"
  timeout 30s install -m 600 "$file" \
    "$state/candidate-active-$name.yml" ||
    fail "RECOVERY_REQUIRED"
  identity=$(active_file_identity "$file") || fail "RECOVERY_REQUIRED"
  printf '%s\n' "$identity" >"$state/candidate-active-$name.identity"
}

restore_active_file() {
  local file=$1
  local name=$2
  if ! timeout 30s python3 - "$file" "$state" "$name" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys

file_path, state, name = sys.argv[1:]
parent, basename = os.path.split(file_path)
if not parent or not basename or "/" in basename:
    raise SystemExit(1)

def read_private(path):
    if os.path.islink(path):
        raise SystemExit(1)
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        return os.read(fd, 1024 * 1024 * 16)
    finally:
        os.close(fd)

def identity(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode):
        raise SystemExit(1)
    digest = hashlib.sha256()
    offset = 0
    while offset < info.st_size:
        chunk = os.pread(fd, min(1024 * 1024, info.st_size - offset), offset)
        if not chunk:
            raise SystemExit(1)
        digest.update(chunk)
        offset += len(chunk)
    return (
        f"{info.st_dev}:{info.st_ino}:{info.st_mode}:{info.st_uid}:"
        f"{info.st_gid}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}:"
        f"{digest.hexdigest()}"
    )

def open_current(directory_fd):
    info = os.stat(basename, dir_fd=directory_fd, follow_symlinks=False)
    if stat.S_ISLNK(info.st_mode):
        raise OSError(40, "symlink")
    return os.open(
        basename,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory_fd,
    )

parent_fd = os.open(
    parent,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    fcntl.flock(parent_fd, fcntl.LOCK_EX)
    previous_exists = os.path.exists(os.path.join(state, f"had-active-{name}"))
    previous_bytes = read_private(
        os.path.join(state, f"previous-active-{name}.yml")
    ) if previous_exists else b""
    candidate_identity_path = os.path.join(
        state, f"candidate-active-{name}.identity"
    )
    candidate_bytes_path = os.path.join(state, f"candidate-active-{name}.yml")
    candidate_identity = read_private(candidate_identity_path).decode().strip() \
        if os.path.exists(candidate_identity_path) else ""
    candidate_bytes = read_private(candidate_bytes_path) \
        if os.path.exists(candidate_bytes_path) else b""

    try:
        current_fd = open_current(parent_fd)
    except FileNotFoundError:
        current_fd = None
    if previous_exists:
        if current_fd is None:
            raise SystemExit(1)
        try:
            current_identity = identity(current_fd)
            os.lseek(current_fd, 0, os.SEEK_SET)
            current_bytes = os.read(current_fd, 16 * 1024 * 1024)
        finally:
            os.close(current_fd)
        if current_identity == read_private(
            os.path.join(state, f"previous-active-{name}.identity")
        ).decode().strip():
            if current_bytes != previous_bytes:
                raise SystemExit(1)
            raise SystemExit(0)
        if not candidate_identity or current_identity != candidate_identity:
            raise SystemExit(1)
        if current_bytes != candidate_bytes:
            raise SystemExit(1)
        replacement = previous_bytes
    else:
        if current_fd is None:
            raise SystemExit(0)
        try:
            current_identity = identity(current_fd)
            os.lseek(current_fd, 0, os.SEEK_SET)
            current_bytes = os.read(current_fd, 16 * 1024 * 1024)
        finally:
            os.close(current_fd)
        if not candidate_identity or current_identity != candidate_identity:
            raise SystemExit(1)
        if current_bytes != candidate_bytes:
            raise SystemExit(1)
        os.unlink(basename, dir_fd=parent_fd)
        os.fsync(parent_fd)
        raise SystemExit(0)

    temporary = f".{basename}.rollback.{os.getpid()}"
    temp_fd = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=parent_fd,
    )
    try:
        view = memoryview(replacement)
        while view:
            written = os.write(temp_fd, view)
            view = view[written:]
        os.fsync(temp_fd)
        os.fchmod(temp_fd, 0o600)
    finally:
        os.close(temp_fd)
    os.replace(
        temporary,
        basename,
        src_dir_fd=parent_fd,
        dst_dir_fd=parent_fd,
    )
    os.fsync(parent_fd)
finally:
    os.close(parent_fd)
PY
  then
    echo "RECOVERY_REQUIRED" >&2
    return 1
  fi
}

provider_release_main() {
root=
base_compose=
image=
revision=
version=
run_key=
mode=
operation=deploy
operation_set=false
rollout_domain=
initial_proof_id=
bootstrap_id=
recovery_run_key=
recovery_incident=
recovery_epoch=
recovery_binding_digest=
recovery_action=
closed_beta_safety=false
public_url=
state_mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] && [ -z "$root" ] || usage; root=$2; shift 2 ;;
    --base-compose) [ "$#" -ge 2 ] && [ -z "$base_compose" ] || usage; base_compose=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] && [ -z "$image" ] || usage; image=$2; shift 2 ;;
    --revision) [ "$#" -ge 2 ] && [ -z "$revision" ] || usage; revision=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] && [ -z "$version" ] || usage; version=$2; shift 2 ;;
    --run-key) [ "$#" -ge 2 ] && [ -z "$run_key" ] || usage; run_key=$2; shift 2 ;;
    --mode) [ "$#" -ge 2 ] && [ -z "$mode" ] || usage; mode=$2; shift 2 ;;
    --operation)
      [ "$#" -ge 2 ] && [ "$operation_set" = false ] || usage
      operation=$2
      operation_set=true
      shift 2
      ;;
    --rollout-domain)
      [ "$#" -ge 2 ] && [ -z "$rollout_domain" ] || usage
      rollout_domain=$2
      shift 2
      ;;
    --initial-proof-id)
      [ "$#" -ge 2 ] && [ -z "$initial_proof_id" ] || usage
      initial_proof_id=$2
      shift 2
      ;;
    --bootstrap-id)
      [ "$#" -ge 2 ] && [ -z "$bootstrap_id" ] || usage
      bootstrap_id=$2
      shift 2
      ;;
    --recovery-run-key)
      [ "$#" -ge 2 ] && [ -z "$recovery_run_key" ] || usage
      recovery_run_key=$2
      shift 2
      ;;
    --recovery-incident)
      [ "$#" -ge 2 ] && [ -z "$recovery_incident" ] || usage
      recovery_incident=$2
      shift 2
      ;;
    --recovery-epoch)
      [ "$#" -ge 2 ] && [ -z "$recovery_epoch" ] || usage
      recovery_epoch=$2
      shift 2
      ;;
    --recovery-binding-digest)
      [ "$#" -ge 2 ] && [ -z "$recovery_binding_digest" ] || usage
      recovery_binding_digest=$2
      shift 2
      ;;
    --recovery-action)
      [ "$#" -ge 2 ] && [ -z "$recovery_action" ] || usage
      recovery_action=$2
      shift 2
      ;;
    --closed-beta-safety)
      [ "$closed_beta_safety" = false ] || usage
      closed_beta_safety=true
      shift
      ;;
    --state-mode)
      [ "$#" -ge 2 ] && [ -z "$state_mode" ] || usage
      state_mode=$2
      shift 2
      ;;
    --public-url)
      [ "$#" -ge 2 ] && [ -z "$public_url" ] || usage
      public_url=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ "$root" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$root" != *..* ]] || usage
[[ "$base_compose" =~ ^/[A-Za-z0-9._/-]+$ ]] &&
  [[ "$base_compose" != *..* ]] || usage
[[ "$image" =~ ^ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$ ]] ||
  usage
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  usage
is_supported_test_vps_version "$version" ||
  fail "target version must be at least v1.2.0"
[[ "$run_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
case "$mode" in deploy|rollback-drill) ;; *) usage ;; esac
case "$operation" in deploy|bootstrap-guard|forward-recover) ;; *) usage ;; esac
case "$rollout_domain" in ""|initial-domain|timepad-first-transition) ;; *) usage ;; esac
[[ -z "$initial_proof_id" || "$initial_proof_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
  usage
[[ -z "$bootstrap_id" || "$bootstrap_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] ||
  usage
[[ -z "$recovery_run_key" || "$recovery_run_key" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  usage
[[ -z "$recovery_incident" || "$recovery_incident" =~ ^[A-Fa-f0-9-]{16,64}$ ]] ||
  usage
[[ -z "$recovery_epoch" || "$recovery_epoch" =~ ^(0|[1-9][0-9]{0,19})$ ]] ||
  usage
[[ -z "$recovery_binding_digest" || "$recovery_binding_digest" =~ ^[0-9a-f]{64}$ ]] ||
  usage
case "$recovery_action" in ""|retry-exact-candidate) ;; *) usage ;; esac
case "$operation" in
  deploy)
    [ -z "$bootstrap_id" ] && [ -z "$recovery_run_key" ] &&
      [ -z "$recovery_incident" ] && [ -z "$recovery_epoch" ] &&
      [ -z "$recovery_binding_digest" ] &&
      [ -z "$recovery_action" ] || usage
    [ -n "$rollout_domain" ] || usage
    if [ "$rollout_domain" = timepad-first-transition ]; then
      [ -n "$initial_proof_id" ] || usage
    else
      [ -z "$initial_proof_id" ] || usage
    fi
    ;;
  bootstrap-guard)
    [ "$mode" = deploy ] && [ -z "$rollout_domain" ] &&
      [ -n "$initial_proof_id" ] && [ -n "$bootstrap_id" ] &&
      [ -z "$recovery_run_key" ] && [ -z "$recovery_incident" ] &&
      [ -z "$recovery_epoch" ] && [ -z "$recovery_binding_digest" ] &&
      [ -z "$recovery_action" ] || usage
    ;;
  forward-recover)
    [ "$mode" = deploy ] && [ -z "$rollout_domain" ] &&
      [ -n "$recovery_run_key" ] && [ -n "$recovery_incident" ] &&
      [ -n "$recovery_epoch" ] && [ -n "$recovery_binding_digest" ] &&
      [ "$recovery_action" = retry-exact-candidate ] &&
      [ -z "$bootstrap_id" ] && [ -z "$initial_proof_id" ] || usage
    ;;
esac
if [ "$operation" = deploy ] && [ "$rollout_domain" = timepad-first-transition ] &&
  [ "$mode" = rollback-drill ]; then
  fail "ROLLBACK_DRILL_UNSAFE"
fi
if [ -n "$public_url" ]; then
  [[ "$public_url" =~ ^https://[^/]+$ ]] || usage
fi
if [ "$closed_beta_safety" = true ]; then
  case "$state_mode" in empty-closed|closed-beta-demo) ;; *) usage ;; esac
elif [ -n "$state_mode" ]; then
  usage
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
timepad_helper=$script_dir/test_vps_timepad_state.py
timepad_contract=$script_dir/test-vps-timepad-release-contracts.json
command -v python3 >/dev/null 2>&1 && [ -f "$timepad_helper" ] &&
  [ ! -L "$timepad_helper" ] && [ -f "$timepad_contract" ] &&
  [ ! -L "$timepad_contract" ] || fail "TIMEPAD_GUARD_UNAVAILABLE"
if [ "${TIMEPAD_WORKER_MODE:-controller-worker}" != fail-closed-worker ]; then
  timeout 15s python3 "$timepad_helper" check-contract \
    --contract "$timepad_contract" >/dev/null ||
    fail "TIMEPAD_CONTRACT_INVALID"
fi
for command_name in docker jq python3 timeout; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "$command_name is required"
done
[ "$(id -u)" -eq 0 ] || fail "the test VPS deploy must run as root"
if [ "${TIMEPAD_WORKER_MODE:-controller-worker}" != fail-closed-worker ]; then
  for command_name in curl flock; do
    command -v "$command_name" >/dev/null 2>&1 || fail "$command_name is required"
  done
  timeout_status=0
  timeout_status=$(command timeout 1s sh -c 'sleep 2' >/dev/null 2>&1; echo "$?")
  [ "$timeout_status" -eq 124 ] || fail "timeout capability is unavailable"
  [ -d "$root" ] || fail "deployment root is unavailable"
  [ -s "$root/.env.production" ] || fail "existing production environment is unavailable"
  [ -s "$root/docker-compose.production.yml" ] ||
    fail "existing production Compose file is unavailable"
  [ -s "$base_compose" ] || fail "reviewed target Compose file is unavailable"
  verify_production_env_settings "$root/.env.production" || fail "PROVIDER_STATE_INVALID"
fi

compose_script=$script_dir/production-compose.sh
update_script=$script_dir/update-production-release.sh
runtime_helper=$script_dir/test-vps-runtime-invariants.sh
safety_hook=$script_dir/verify-test-vps-closed-beta-state.sh
provider_helper=$script_dir/test-vps-provider-credential.py
if [ "${TIMEPAD_WORKER_MODE:-controller-worker}" != fail-closed-worker ]; then
  [ -x "$compose_script" ] || fail "reviewed Compose wrapper is unavailable"
  [ -x "$update_script" ] || fail "reviewed release updater is unavailable"
  [ -r "$runtime_helper" ] || fail "runtime invariant helper is unavailable"
  [ -f "$provider_helper" ] && [ ! -L "$provider_helper" ] && [ -r "$provider_helper" ] ||
    fail "provider credential helper is unavailable"
  command timeout 30s python3 "$provider_helper" check >/dev/null || fail "PREREQUISITE_MISSING"
  # shellcheck source=/dev/null
  source "$runtime_helper"
fi

supervisor_enabled=false
recovery_admission_only=false
supervisor_client() {
  command timeout 10s python3 "$script_dir/test_vps_timepad_supervisor.py" \
    client --root "$state_root" "$@"
}
supervisor_cancel_exit() {
  local status=$1 reason=${2:-EXIT}
  trap - EXIT
  trap '' TERM INT HUP
  if [ "$status" -ne 0 ]; then
    [ "$status" -ne 86 ] || reason=DRILL
    # Notify before closing the private channel. Socket EOF can otherwise
    # reach the event loop before waitpid exposes the initiating exit status.
    # Only the supervisor may drain writers and dispatch a cleanup worker.
    supervisor_client cancel "$reason" "$status" >/dev/null 2>&1 || :
  fi
  exit "$status"
}
supervisor_publish_lease() {
  [ "$supervisor_enabled" = true ] || return 0
  local grant lease snapshot revision attempt publication digest grant_id
  grant=$(supervisor_client grant lease-publish 10) || return 1
  lease=$(mktemp "$state_root/.timepad-execution.$TIMEPAD_ATTEMPT.XXXXXX") ||
    return 1
  snapshot=$(supervisor_client lease) || {
      rm -f -- "$lease"
      return 1
    }
  # CLI output ends with a newline; the state helper accepts canonical lease
  # bytes only. Command substitution removes that transport delimiter.
  printf '%s' "$snapshot" >"$lease" || {
    rm -f -- "$lease"
    return 1
  }
  chmod 600 "$lease" || {
    rm -f -- "$lease"
    return 1
  }
  revision=$(jq -er '.revision | numbers' "$lease") || {
    rm -f -- "$lease"
    return 1
  }
  attempt=$(jq -er '.attempt | strings | select(test("^[a-f0-9]{32}$"))' \
    "$lease") || {
      rm -f -- "$lease"
      return 1
    }
  [ "$attempt" = "$TIMEPAD_ATTEMPT" ] || {
    rm -f -- "$lease"
    return 1
  }
  publication=$(command timeout 10s python3 "$timepad_helper" publish-lease \
    --root "$state_root" --lease "$lease" --deploy-lock-fd 9) || {
      rm -f -- "$lease"
      return 1
    }
  digest=$(jq -er '.digest | strings | select(test("^[a-f0-9]{64}$"))' \
    <<<"$publication") || {
      rm -f -- "$lease"
      return 1
    }
  [ "$(jq -er '.revision | numbers' <<<"$publication")" = "$revision" ] ||
    {
      rm -f -- "$lease"
      return 1
    }
  grant_id=$(jq -er '.grantId | strings' <<<"$grant") || {
    rm -f -- "$lease"
    return 1
  }
  supervisor_client complete "$grant_id" >/dev/null || {
    rm -f -- "$lease"
    return 1
  }
  supervisor_client lease-ack "$revision" "$digest" >/dev/null || {
    rm -f -- "$lease"
    return 1
  }
  rm -f -- "$lease"
}
supervisor_complete() {
  [ "$supervisor_enabled" = true ] ||
    fail "EXECUTION_SUPERVISOR_REQUIRED"
  supervisor_client prepare-terminal >/dev/null ||
    fail "EXECUTION_TERMINAL_PREPARE_FAILED"
  supervisor_publish_lease || fail "EXECUTION_LEASE_PUBLICATION_FAILED"
  supervisor_client terminal 0 --outcome "$1" >/dev/null ||
    fail "EXECUTION_TERMINAL_ACK_FAILED"
}
recovery_retry_runtime_refusal() {
  if [ "$supervisor_enabled" = true ]; then
    supervisor_client cancel RECOVERY_RETRY_RUNTIME_FAILED 1 >/dev/null 2>&1 || :
  fi
  fail "RECOVERY_RETRY_RUNTIME_FAILED"
}
supervisor_register_recovery() {
  local grant grant_id deadline publication lease_revision digest
  local current container inspection global_ids compose_ids runtime_evidence=
  local registration_result
  local -a evidence_args=()
  grant=$(supervisor_client grant recovery-registration 30) || {
    [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
      echo "fixture_timepad_guard=SUPERVISOR_GRANT_REFUSED" >&2
    return 1
  }
  grant_id=$(jq -er '.grantId | strings' <<<"$grant") || {
    [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
      echo "fixture_timepad_guard=SUPERVISOR_GRANT_INVALID" >&2
    return 1
  }
  deadline=$(jq -er '.endNs | numbers' <<<"$grant") || {
    [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
      echo "fixture_timepad_guard=SUPERVISOR_DEADLINE_INVALID" >&2
    return 1
  }
  current=$(command timeout 5s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') || {
      [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
        echo "fixture_timepad_guard=RECOVERY_CURRENT_READ_FAILED" >&2
      return 1
    }
  if jq -e '.executionAttempt != null and
    (.phase != "COMMITTED" and .phase != "ROLLED_BACK" and .phase != "READY")' \
    <<<"$current" >/dev/null; then
    command timeout 5s python3 "$timepad_helper" authorize-recovery \
      --root "$state_root" --authorization "$state_root/timepad-recovery-authorization.json" \
      --deploy-lock-fd 9 >/dev/null || {
        [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
          echo "fixture_timepad_guard=RECOVERY_AUTHORIZATION_REFUSED" >&2
        return 1
      }
    jq -e --arg run "$recovery_run_key" --arg incident "${recovery_incident,,}" \
      --arg epoch "$recovery_epoch" --arg binding "$recovery_binding_digest" \
      --arg repository "${image##*@sha256:}" --arg revision "$revision" --arg version "$version" '
      .runId == $run and .incidentId == $incident and
      (.operationEpoch | tostring) == $epoch and .evidenceDigest == $binding and
      .target.tuple.repositoryDigest == $repository and
      .target.tuple.revision == $revision and .target.tuple.version == $version
    ' <<<"$current" >/dev/null || {
      [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
        echo "fixture_timepad_guard=RECOVERY_SELECTOR_MISMATCH" >&2
      return 1
    }
    container=$(jq -er '.containerId | strings | select(test("^[a-f0-9]{64}$"))' \
      <<<"$current") || {
        [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
          echo "fixture_timepad_guard=RECOVERY_CONTAINER_INVALID" >&2
        return 1
      }
    inspection=$(command timeout 5s docker inspect "$container") || {
      [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
        echo "fixture_timepad_guard=RECOVERY_INSPECTION_FAILED" >&2
      return 1
    }
    global_ids=$(command timeout 5s docker ps --all --quiet \
      --filter label=com.docker.compose.project=meet-production \
      --filter label=com.docker.compose.service=backend) || {
        [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
          echo "fixture_timepad_guard=RECOVERY_DOCKER_INVENTORY_FAILED" >&2
        return 1
      }
    compose_ids=$(command timeout 5s bash -c '
      set -euo pipefail
      source "$1"
      runtime_compose "$2" "$3" ps -aq backend
    ' _ "$runtime_helper" "$root" "$compose_script") || {
      [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
        echo "fixture_timepad_guard=RECOVERY_COMPOSE_INVENTORY_FAILED" >&2
      return 1
    }
    runtime_evidence=$(jq -cn --argjson inspection "$inspection" \
      --arg global "$global_ids" --arg compose "$compose_ids" '
      {inspection:$inspection,backendInventory:($global | split("\n")),
       composeInventory:($compose | split("\n"))}
    ') || {
      [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" != 1 ] ||
        echo "fixture_timepad_guard=RECOVERY_EVIDENCE_ENCODE_FAILED" >&2
      return 1
    }
    evidence_args=(--runtime-evidence)
  fi
  registration_result=$(command timeout 30s python3 "$timepad_helper" register-recovery \
    --root "$state_root" --contract "$timepad_contract" --deploy-lock-fd 9 \
    --run-id "$recovery_run_key" --incident-id "${recovery_incident,,}" \
    --epoch "$recovery_epoch" --binding-digest "$recovery_binding_digest" \
    --repository-digest "${image##*@sha256:}" --revision "$revision" --version "$version" \
    --execution-attempt "$TIMEPAD_ATTEMPT" --execution-grant "$grant_id" \
    --deadline-ns "$deadline" "${evidence_args[@]}" <<<"$runtime_evidence" 2>&1) || {
      if [ "${TIMEPAD_FIXTURE_DIAGNOSTICS:-}" = 1 ] &&
        [[ "$registration_result" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        echo "fixture_timepad_guard=$registration_result" >&2
      fi
      return 1
    }
  publication=$registration_result
  jq -e --arg attempt "$TIMEPAD_ATTEMPT" '
    .attempt == $attempt and .revision == 0 and
    (.digest | type == "string" and test("^[a-f0-9]{64}$"))
  ' <<<"$publication" >/dev/null || return 1
  lease_revision=$(jq -er '.revision | numbers' <<<"$publication") || return 1
  digest=$(jq -er '.digest | strings' <<<"$publication") || return 1
  supervisor_client complete "$grant_id" >/dev/null || return 1
  supervisor_client lease-ack "$lease_revision" "$digest" >/dev/null || return 1
}
supervisor_timeout() {
  local options=() local_bound executable wait_name grant grant_id end_ns bounded status
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kill-after=*|--signal=*|--preserve-status|--foreground|--verbose)
        options+=("$1")
        shift ;;
      -k|-s|--kill-after|--signal)
        [ "$#" -ge 2 ] || return 2
        options+=("$1" "$2")
        shift 2 ;;
      *) break ;;
    esac
  done
  [ "$#" -ge 2 ] || return 2
  local_bound=$1
  shift
  executable=${1##*/}
  case "$executable" in
    docker) wait_name=docker ;;
    curl) wait_name=curl ;;
    bash|sh) wait_name=runtime ;;
    python3)
      if [ "${2:-}" = "$provider_helper" ]; then
        wait_name=provider
      elif [ "${2:-}" = "$timepad_helper" ]; then
        wait_name="state-publish"
      else
        wait_name=preflight
      fi
      ;;
    *) wait_name=preflight ;;
  esac
  if [ "${recovery_admission_only:-false}" = true ]; then
    case "$executable:${2:-}" in
      docker:image) [ "${3:-}" = inspect ] || return 1 ;;
      docker:inspect|docker:ps) ;;
      bash:*-runtime-invariants.sh) ;;
      bash:-c) ;; # Fixed read-only inventory wrapper in recovery_backend_inventory.
      jq:-er)
        [ "$#" -eq 7 ] && [ "$3" = --arg ] && [ "$4" = run ] &&
          [ "$5" = "$recovery_run_key" ] && [ "$7" = "$provider_pointer" ] || return 1
        ;;
      python3:"$timepad_helper")
        case "${3:-}" in read-state|authorize-recovery) ;; *) return 1 ;; esac ;;
      python3:"$provider_helper")
        case "${3:-}" in check-image|live-resume|absence-resume|runtime-request-proof) ;; *) return 1 ;; esac ;;
      python3:-) ;; # Fixed controller's bounded private-input stat validation.
      *) return 1 ;;
    esac
    wait_name=recovery-admission
  elif [ "${TIMEPAD_WORKER_MODE:-controller-worker}" = rollback-worker ]; then
    # Reconstruction and daemon proof are still required. Admission is
    # read-only: no config/provider/state writer can enter under this grant.
    [ "$executable:${2:-}:${3:-}" = "python3:$timepad_helper:rollback-admission" ] ||
      return 1
    wait_name=rollback-admission
  fi
  if [ "${TIMEPAD_WORKER_MODE:-controller-worker}" = fail-closed-worker ]; then
    case "$executable:${2:-}" in
      python3:"$timepad_helper")
        case "${3:-}" in
          read-state) wait_name=cleanup-stop ;;
          retain-unresolved|advance) wait_name=cleanup-publish ;;
          *) return 1 ;;
        esac
        ;;
      python3:"$provider_helper")
        [ "${3:-}" = runtime-request-proof ] || return 1
        wait_name=cleanup-stop
        ;;
      docker:inspect|docker:stop) wait_name=cleanup-stop ;;
      docker:update)
        [ "${3:-}" = --restart=no ] || return 1
        wait_name=cleanup-stop
        ;;
      *) return 1 ;;
    esac
  fi
  grant=$(supervisor_client grant "$wait_name" "${local_bound%s}") || return 124
  grant_id=$(jq -er '.grantId | strings' <<<"$grant") || return 1
  end_ns=$(jq -er '.endNs | numbers' <<<"$grant") || return 1
  if [ "$executable" = python3 ] && [ "${2:-}" = "$provider_helper" ]; then
    # The private socket grants authority; the helper independently checks the
    # same durable lease and absolute deadline under inherited FD9.
    case "${3:-}" in
      prepare|verify|finish|prepare-finalization|finish-committed-resume|\
      live-resume|absence-resume|prepare-transition-proof|runtime-request-proof|state-publish|\
      retention-list|retention-check|retention-delete)
        set -- "$@" --execution-attempt "$TIMEPAD_ATTEMPT" \
          --execution-grant "$grant_id" --deadline-ns "$end_ns"
        ;;
    esac
  elif [ "$executable" = python3 ] && [ "${2:-}" = "$timepad_helper" ]; then
    case "${3:-}" in
      bootstrap|publish-state|prepare|advance|adopt-recovery|claim-rollback|retain-unresolved|stop-owned-child|rollback-admission)
        set -- "$@" --execution-attempt "$TIMEPAD_ATTEMPT" \
          --execution-grant "$grant_id" --deadline-ns "$end_ns"
        ;;
    esac
  fi
  bounded=$(command timeout 3s python3 - "$end_ns" <<'PY'
import sys
import time

remaining = (int(sys.argv[1]) - time.monotonic_ns()) / 1_000_000_000
if remaining <= 0:
    raise SystemExit(1)
print(f"{remaining:.9f}s")
PY
  ) || {
    supervisor_client complete "$grant_id" >/dev/null || :
    return 124
  }
  if command timeout "${options[@]}" "$bounded" "$@"; then
    status=0
  else
    status=$?
  fi
  supervisor_client complete "$grant_id" >/dev/null || return 1
  return "$status"
}

fail_closed_owned_backend() {
  # Entry is private and runs only after the supervisor's ECHILD proof. The
  # incident must already bind this attempt; rejected recovery selectors must
  # never gain stop authority merely by entering the cleanup role.
  local current container image_id config_hash inspection
  current=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') || return 1
  jq -e --arg attempt "$TIMEPAD_ATTEMPT" '
    .executionAttempt == $attempt and
    (.phase == "CUTOVER_POSSIBLE" or .phase == "VERIFYING" or
     .phase == "COMMITTING" or .phase == "RECOVERY_REQUIRED" or
     .phase == "FORWARD_RECOVERING" or .phase == "ROLLING_BACK") and
    (.containerId | type == "string" and test("^[a-f0-9]{64}$")) and
    (.configHash | type == "string" and test("^[a-f0-9]{64}$"))
  ' <<<"$current" >/dev/null || return 1
  container=$(jq -er '.containerId' <<<"$current") || return 1
  image_id=$(jq -er '.target.tuple.platformImageId' <<<"$current") || return 1
  config_hash=$(jq -er '.configHash' <<<"$current") || return 1
  inspection=$(timeout 10s docker inspect "$container" 2>/dev/null) || return 1
  jq -e --arg id "$container" --arg image "sha256:$image_id" --arg hash "$config_hash" '
    type == "array" and length == 1 and .[0].Id == $id and .[0].Image == $image and
    .[0].Config.Labels["com.docker.compose.project"] == "meet-production" and
    .[0].Config.Labels["com.docker.compose.service"] == "backend" and
    .[0].Config.Labels["com.docker.compose.config-hash"] == $hash
  ' <<<"$inspection" >/dev/null || return 1
  timeout 10s docker update --restart=no "$container" >/dev/null 2>&1 || return 1
  timeout 20s docker stop --time 10 "$container" >/dev/null 2>&1 || return 1
  inspection=$(timeout 10s docker inspect "$container" 2>/dev/null) || return 1
  jq -e --arg id "$container" --arg image "sha256:$image_id" --arg hash "$config_hash" '
    type == "array" and length == 1 and .[0].Id == $id and .[0].Image == $image and
    .[0].Config.Labels["com.docker.compose.project"] == "meet-production" and
    .[0].Config.Labels["com.docker.compose.service"] == "backend" and
    .[0].Config.Labels["com.docker.compose.config-hash"] == $hash and
    .[0].State.Running == false and .[0].HostConfig.RestartPolicy.Name == "no"
  ' <<<"$inspection" >/dev/null || return 1
  # Suppression/stop is bounded best effort, not daemon-request quiescence.
  # No terminal acknowledgment, rollback, provider cleanup or lease clearing is
  # authorized until that separate evidence is implemented.
  return 1
}

fail_closed_publish_unresolved() {
  timeout 10s python3 "$timepad_helper" retain-unresolved \
    --root "$state_root" --deploy-lock-fd 9 >/dev/null
}

fail_closed_retry_refusal() {
  local current lease container inspection state run_key state_suffix
  lease=$(supervisor_client lease) || return 1
  jq -e '.operation == "forward-recover" and
    .firstFailure == "RECOVERY_RETRY_RUNTIME_FAILED" and .firstStatus == 1' \
    <<<"$lease" >/dev/null || return 1
  current=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') || return 1
  jq -e --arg attempt "$TIMEPAD_ATTEMPT" '
    .executionAttempt == $attempt and .phase == "VERIFYING" and .ownedChild == null and
    .runtimeRequest.lifecycle == "completed" and .runtimeRequest.operation == "start" and
    .runtimeRequest.executionAttempt == $attempt and
    .runtimeRequest.containerId == .containerId
  ' <<<"$current" >/dev/null || return 1
  container=$(jq -er '.containerId' <<<"$current") || return 1
  run_key=$(jq -er '.runId' <<<"$current") || return 1
  state=$(jq -er --arg root "$state_root/" '$root + .ownedRun' <<<"$current") || return 1
  state_suffix=${state#"$state_root/$run_key-"}
  inspection=$(timeout 10s docker inspect "$container") || return 1
  jq -e --arg id "$container" \
    --arg image "sha256:$(jq -er '.target.tuple.platformImageId' <<<"$current")" \
    --arg hash "$(jq -er '.configHash' <<<"$current")" '
    type == "array" and length == 1 and .[0].Id == $id and .[0].Image == $image and
    .[0].Config.Labels["com.docker.compose.project"] == "meet-production" and
    .[0].Config.Labels["com.docker.compose.service"] == "backend" and
    .[0].Config.Labels["com.docker.compose.config-hash"] == $hash and
    .[0].HostConfig.RestartPolicy.Name == "no"
  ' <<<"$inspection" >/dev/null || return 1
  timepad_runtime_mutate stop "$container" || return 1
  supervisor_client prepare-terminal >/dev/null || return 1
  supervisor_publish_lease || return 1
  supervisor_client terminal 1 >/dev/null || return 1
}

rollback_worker_admission() {
  timeout 15s python3 "$timepad_helper" rollback-admission \
    --root "$state_root" --deploy-lock-fd 9 >/dev/null ||
    fail "ROLLBACK_NOT_ADMITTED"
  # State compatibility and kernel ECHILD do not prove an interrupted Docker
  # request has completed. Keep mutation closed until daemon/config/provider
  # reconstruction is implemented and independently verified.
  fail "ROLLBACK_RUNTIME_QUIESCENCE_REQUIRED"
}

docker_image_inspect() {
  timeout 30s docker image inspect "$@" 2>/dev/null
}

docker_container_inspect() {
  timeout 30s docker inspect "$@" 2>/dev/null
}

runtime_image_id_bounded() {
  timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_image_id "$2" "$3"
  ' _ "$runtime_helper" "$root" "$compose_script"
}

runtime_environment_bounded() {
  timeout 60s bash -c '
    set -euo pipefail
    source "$1"
    verify_environment_matches_container "$2" "$3"
  ' _ "$runtime_helper" "$root" "$compose_script"
}

runtime_invariants_bounded() {
  timeout 60s bash -c '
    set -euo pipefail
    source "$1"
    verify_runtime_invariants "$2" "$3" "$4" "$5" "$6" "$7"
  ' _ "$runtime_helper" "$root" "$compose_script" "$1" "$2" "$3" "$4"
}

recovery_t0_ns=
recovery_work_end_ns=
recovery_hard_end_ns=
recovery_budget_arm() {
  [ -n "$recovery_t0_ns" ] && return 0
  if [ "$supervisor_enabled" = true ]; then
    local lease
    lease=$(supervisor_client lease) || fail "RECOVERY_REQUIRED"
    if [ "$(jq -er '.lifecycle | strings' <<<"$lease")" = registered ] &&
      [ "${recovery_admission_only:-false}" != true ]; then
      supervisor_client arm >/dev/null || fail "EXECUTION_SUPERVISOR_ARM_FAILED"
      supervisor_publish_lease || fail "EXECUTION_LEASE_PUBLICATION_FAILED"
      lease=$(supervisor_client lease) || fail "RECOVERY_REQUIRED"
    fi
    jq -e --arg attempt "$TIMEPAD_ATTEMPT" '
      .attempt == $attempt and .t0Ns != null and .workEndNs != null and
      .hardEndNs != null
    ' <<<"$lease" >/dev/null || fail "RECOVERY_REQUIRED"
    recovery_t0_ns=$(jq -er '.t0Ns | numbers' <<<"$lease") ||
      fail "RECOVERY_REQUIRED"
    recovery_work_end_ns=$(jq -er '.workEndNs | numbers' <<<"$lease") ||
      fail "RECOVERY_REQUIRED"
    recovery_hard_end_ns=$(jq -er '.hardEndNs | numbers' <<<"$lease") ||
      fail "RECOVERY_REQUIRED"
    return 0
  fi
  recovery_t0_ns=$(command timeout 2s python3 -B -c \
    'import time; print(time.monotonic_ns())') || fail "RECOVERY_REQUIRED"
  [[ "$recovery_t0_ns" =~ ^[0-9]+$ ]] || fail "RECOVERY_REQUIRED"
  recovery_work_end_ns=$((recovery_t0_ns + 540000000000))
  recovery_hard_end_ns=$((recovery_t0_ns + 600000000000))
}

recovery_monotonic_now() {
  command timeout 2s python3 -B -c 'import time; print(time.monotonic_ns())'
}

recovery_work_check() {
  [ -n "$recovery_work_end_ns" ] || return 0
  local now
  now=$(recovery_monotonic_now) || return 1
  [[ "$now" =~ ^[0-9]+$ ]] && (( now < recovery_work_end_ns ))
}

recovery_deadline_check() {
  [ -n "$recovery_hard_end_ns" ] || return 0
  local now
  now=$(recovery_monotonic_now) || fail "RECOVERY_REQUIRED"
  [[ "$now" =~ ^[0-9]+$ ]] && (( now < recovery_hard_end_ns )) ||
    fail "RECOVERY_REQUIRED"
  recovery_work_check || fail "RECOVERY_REQUIRED"
}

recovery_health_deadline() {
  local duration_seconds=$1 now end
  [[ "$duration_seconds" =~ ^[1-9][0-9]{0,2}$ ]] || return 1
  now=$(recovery_monotonic_now) || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  end=$((now + duration_seconds * 1000000000))
  if [ -n "$recovery_work_end_ns" ] &&
    (( recovery_work_end_ns < end )); then
    end=$recovery_work_end_ns
  fi
  printf '%s' "$end"
}

recovery_health_window_open() {
  local end_ns=$1 now
  now=$(recovery_monotonic_now) || return 1
  [[ "$now" =~ ^[0-9]+$ ]] && (( now < end_ns )) &&
    recovery_work_check
}

timeout() {
  if [ "$supervisor_enabled" = true ]; then
    supervisor_timeout "$@"
    return
  fi
  local -a options=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kill-after=*|--signal=*|--preserve-status|--foreground|--verbose)
        options+=("$1")
        shift
        ;;
      -k|-s)
        [ "$#" -ge 2 ] || return 125
        options+=("$1" "$2")
        shift 2
        ;;
      *) break ;;
    esac
  done
  [ "$#" -ge 2 ] || return 125
  local local_duration=$1
  shift
  if [ -z "$recovery_t0_ns" ]; then
    command timeout "${options[@]}" "$local_duration" "$@"
    return $?
  fi
  [[ "$local_duration" =~ ^([0-9]+)(s)?$ ]] || return 125
  local duration_ns=$((BASH_REMATCH[1] * 1000000000))
  local end_ns=$recovery_work_end_ns now remaining seconds nanoseconds effective
  [ "${timepad_cleanup_mode:-false}" = true ] && end_ns=$recovery_hard_end_ns
  now=$(recovery_monotonic_now) || return 125
  [[ "$now" =~ ^[0-9]+$ ]] || return 125
  remaining=$((end_ns - now))
  (( remaining > 0 )) || return 124
  if (( remaining < duration_ns )); then
    seconds=$((remaining / 1000000000))
    nanoseconds=$((remaining % 1000000000))
    printf -v effective '%d.%09ds' "$seconds" "$nanoseconds"
  else
    effective=$local_duration
  fi
  command timeout "${options[@]}" "$effective" "$@"
}

recovery_backend_inventory() {
  local global_ids compose_ids
  global_ids=$(timeout 30s docker ps --all --quiet \
    --filter label=com.docker.compose.project=meet-production \
    --filter label=com.docker.compose.service=backend) || return 1
  compose_ids=$(timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" ps -aq backend
  ' _ "$runtime_helper" "$root" "$compose_script") || return 1
  [ "$global_ids" = "$compose_ids" ] || return 1
  printf '%s' "$global_ids"
}

recovery_absent_candidate() {
  local inventory image_json configuration active name expected ids created
  # A failed inspect is not absence evidence. Both complete inventories must
  # succeed and agree, and the immutable original receipt must admit creation.
  inventory=$(recovery_backend_inventory) ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  [ -z "$inventory" ] || fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  validate_configuration_boundary "$state/config.env.target"
  for name in compose runtime; do
    case "$name" in compose) active=$active_compose ;; runtime) active=$active_runtime ;; esac
    validate_timepad_input "$state/candidate-active-$name.identity" 4096 ||
      fail "RECOVERY_CONFIGURATION_MISMATCH"
    expected=$(<"$state/candidate-active-$name.identity")
    [ "$(active_file_identity "$active")" = "$expected" ] &&
      cmp -s "$active" "$state/candidate-active-$name.yml" ||
      fail "RECOVERY_CONFIGURATION_MISMATCH"
  done
  cmp -s "$active_compose" "$state/config.base-compose.yml" &&
    cmp -s "$active_runtime" "$state/target-runtime.override.yml" ||
    fail "RECOVERY_CONFIGURATION_MISMATCH"
  image_json=$(timeout 30s docker image inspect "$image" 2>/dev/null) ||
    fail "RECOVERY_TARGET_IMAGE_REQUIRED"
  configuration=$(env -i PATH="$PATH" HOME=/root COMPOSE_PROJECT_NAME=meet-production \
    BACKEND_IMAGE="$image" BACKEND_VERSION="$version" BACKEND_REVISION="$revision" \
    timeout 30s docker compose --project-directory "$root" \
      --env-file "$state/config.env.target" \
      -f "$state/config.base-compose.yml" -f "$state/target-runtime.override.yml" \
      config --format json 2>/dev/null) || fail "RECOVERY_CONFIGURATION_MISMATCH"
  jq -cn --slurpfile authority "$recovery_authorization" \
    --argjson inspection "$image_json" --argjson configuration "$configuration" '
    {schema:"meet-backend/test-vps-provider-absence-resume/v1",
     authorization:$authority[0],imageInspection:$inspection,
     targetConfiguration:$configuration,backendInventory:[]}' |
    timeout 30s python3 "$provider_helper" absence-resume \
      --run-key "$recovery_run_key" --state-root "$state_root" \
      --state-kind "$recovery_state_suffix" --deploy-lock-fd 9 >/dev/null ||
    fail "RECOVERY_PROVIDER_ABSENCE_PROOF_REQUIRED"
  # Consume the one-use budget before releasing any migration-capable child.
  # An unbound create-intent is deliberately unresolved on crash re-entry.
  timepad_advance FORWARD_RECOVERING EXACT_IMAGE_REPLACEMENT
  timepad_advance FORWARD_RECOVERING "" "" "" "" "" replacement-create-intent
  if [ "${supervisor_enabled:-false}" = true ]; then
    trap 'supervisor_cancel_exit "$?"' EXIT
  else
    trap 'status=$?; trap - EXIT; complete_owned_child true || status=1; exit "$status"' EXIT
  fi
  trap 'trap "" TERM INT HUP; exit 143' TERM INT HUP
  inventory=$(recovery_backend_inventory) ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  [ -z "$inventory" ] || fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  run_owned_child FORWARD_RECOVERING timeout --kill-after=5s 240s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" "${@:4}"
  ' _ "$runtime_helper" "$root" "$compose_script" \
    up --no-start --no-deps --no-build --pull never --force-recreate backend \
    >/dev/null || fail "RECOVERY_REPLACEMENT_CREATE_FAILED"
  ids=$(recovery_backend_inventory) || fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  [[ "$ids" =~ ^[a-f0-9]{64}$ ]] && [ "$ids" != "$recovery_container" ] ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  created=$(timeout 30s docker inspect "$ids") ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  jq -e --arg id "$ids" --arg image "$recovery_target_id" --arg hash "$recovery_hash" '
    length == 1 and .[0].Id == $id and .[0].Image == $image and
    .[0].State.Running == false and
    .[0].Config.Labels["com.docker.compose.project"] == "meet-production" and
    .[0].Config.Labels["com.docker.compose.service"] == "backend" and
    .[0].Config.Labels["com.docker.compose.config-hash"] == $hash
  ' <<<"$created" >/dev/null || fail "RECOVERY_REPLACEMENT_IDENTITY_MISMATCH"
  timeout 15s docker update --restart=no "$ids" >/dev/null ||
    fail "RECOVERY_REPLACEMENT_POLICY_FAILED"
  [ "$(timeout 30s docker inspect "$ids" \
    --format '{{.HostConfig.RestartPolicy.Name}}')" = no ] ||
    fail "RECOVERY_REPLACEMENT_POLICY_FAILED"
  timepad_advance FORWARD_RECOVERING "" "$ids" "" "" "" replacement-container-authorized
  recovery_container=$ids
  recovery_phase=FORWARD_RECOVERING
  recovery_substep=replacement-container-authorized
  recovery_state=$(timeout 15s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') ||
    fail "GUARD_STATE_LOST"
}

runtime_guarded_invariants_bounded() {
  timeout 60s env TIMEPAD_STATE_HELPER="$timepad_helper" \
    TIMEPAD_STATE_ROOT="$state_root" DEPLOY_LOCK_FD=9 \
    bash -c '
      set -euo pipefail
      source "$1"
      verify_guarded_runtime_invariants "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
    ' _ "$runtime_helper" "$root" "$compose_script" \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

timepad_binding_for_image() {
  local image_ref=$1 image_id=$2 image_revision=$3 image_version=$4
  local domain=$5 repository_digest=${image_ref##*@sha256:}
  timeout 15s jq -ce \
    --arg repository "$repository_digest" \
    --arg platform "${image_id#sha256:}" \
    --arg revision "$image_revision" --arg version "$image_version" \
    --arg domain "$domain" '
      ([.images[]? | {id,tuple,domain}]
       + [.initialDomain[]? | {id,tuple,domain:"initial"}])
      | map(select(
          .tuple.repositoryDigest == $repository and
          .tuple.platformImageId == $platform and
          .tuple.revision == $revision and .tuple.version == $version and
          ($domain == "any" or
           ($domain == "initial" and .domain == "initial") or
           ($domain == "transition" and .domain != "initial"))
        ))
      | if length == 1 then .[0] else error("image binding is not unique") end
    ' "$timepad_contract"
}

timepad_advance() {
  local phase=$1 reason=${2:-} container_id=${3:-} config_hash=${4:-}
  local terminal_receipt=${5:-} witness_digest=${6:-} commit_substep=${7:-}
  local finalization_digest=${8:-} owned_child_json='' latest_attempt_id=${10:-}
  local child_change=false
  if [ "$#" -ge 9 ]; then
    child_change=true
    owned_child_json=$9
  fi
  local changes_file=$state/.timepad-changes.json
  [ ! -e "$changes_file" ] && [ ! -L "$changes_file" ] ||
    fail "GUARD_STATE_LOST"
  umask 077
  jq -cn --arg reason "$reason" --arg container "$container_id" \
    --arg hash "$config_hash" --arg receipt "$terminal_receipt" \
    --arg witness "$witness_digest" --arg substep "$commit_substep" \
    --arg finalization "$finalization_digest" \
    --arg attempt "$latest_attempt_id" --argjson child_change "$child_change" \
    --argjson child "${owned_child_json:-null}" '
      {changes:
        ((if $reason == "" then {} else {reason:$reason} end) +
         (if $container == "" then {} else {containerId:$container} end) +
         (if $hash == "" then {} else {configHash:$hash} end) +
         (if $receipt == "" then {} else {terminalReceipt:$receipt} end) +
         (if $witness == "" then {} else {commitWitnessDigest:$witness} end) +
         (if $finalization == "" then {} else
           {providerFinalizationDigest:$finalization} end) +
         (if $substep == "" then {} else {commitSubstep:$substep} end) +
         (if $child_change then {ownedChild:$child} else {} end) +
         (if $attempt == "" then {} else {latestAttemptId:$attempt} end))}
    ' >"$changes_file"
  chmod 600 "$changes_file"
  timeout 15s python3 "$timepad_helper" advance \
    --root "$state_root" --phase "$phase" --changes "$changes_file" \
    --deploy-lock-fd 9 >/dev/null || {
      rm -f -- "$changes_file"
      fail "GUARD_STATE_LOST"
    }
  rm -f -- "$changes_file"
}

timepad_claim_rollback() {
  timeout 15s python3 "$timepad_helper" claim-rollback \
    --root "$state_root" --deploy-lock-fd 9 >/dev/null ||
    fail "ROLLBACK_NOT_ADMITTED"
}

timepad_request_publish() {
  local request=$1 current phase changes=$state/.timepad-request-changes.json
  current=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') || return 1
  phase=$(jq -er '.phase' <<<"$current") || return 1
  [ ! -e "$changes" ] && [ ! -L "$changes" ] || return 1
  (umask 077; set -o noclobber
    jq -cn --argjson request "$request" '{changes:{runtimeRequest:$request}}' >"$changes") ||
    return 1
  timeout 15s python3 "$timepad_helper" advance --root "$state_root" \
    --phase "$phase" --changes "$changes" --deploy-lock-fd 9 >/dev/null || {
      rm -f -- "$changes"
      return 1
    }
  rm -f -- "$changes"
}

timepad_request_begin() {
  local operation=$1 child=${2:-} expected_container=$3 current request nonce
  current=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') || return 1
  nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$nonce" =~ ^[a-f0-9]{32}$ ]] || return 1
  request=$(jq -ce --arg operation "$operation" --arg nonce "$nonce" \
    --arg attempt "$TIMEPAD_ATTEMPT" --arg child "$child" \
    --arg container "$expected_container" '
    select(.executionAttempt == $attempt and .containerId == $container) |
    {nonce:$nonce,sequence:((.runtimeRequest.sequence // 0) + 1),
     executionAttempt:$attempt,operation:$operation,containerId:.containerId,
     imageId:.target.tuple.platformImageId,configHash:.configHash,
     childAttemptId:(if $child == "" then null else $child end),
     lifecycle:"intent",responseId:null,completionDigest:null}
  ' <<<"$current") || return 1
  timepad_request_publish "$request"
}

timepad_request_acknowledge() {
  local response=$1 current request
  current=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') || return 1
  request=$(jq -ce --arg response "$response" '
    .runtimeRequest | select(.lifecycle == "intent" and .containerId == $response) |
    .lifecycle="acknowledged" | .responseId=$response
  ' <<<"$current") || return 1
  timepad_request_publish "$request"
}

timepad_request_complete() {
  local current request container inspection proof digest nonce
  current=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9 | jq -ce '.current') || return 1
  request=$(jq -ce '.runtimeRequest | select(.lifecycle == "acknowledged")' \
    <<<"$current") || return 1
  container=$(jq -er '.containerId' <<<"$request") || return 1
  nonce=$(jq -er '.nonce' <<<"$request") || return 1
  inspection=$(timeout 15s docker inspect "$container") || return 1
  proof=$(jq -cn --arg nonce "$nonce" --argjson inspection "$inspection" \
    '{requestNonce:$nonce,inspection:$inspection}' |
    timeout 15s python3 "$provider_helper" runtime-request-proof \
      --run-key "$run_key" --state-root "$state_root" \
      --state-kind "$state_suffix" --deploy-lock-fd 9) || return 1
  digest=$(jq -er --arg nonce "$nonce" '
    select(.requestNonce == $nonce) |
    .completionDigest | strings | select(test("^[a-f0-9]{64}$"))
  ' <<<"$proof") || return 1
  request=$(jq -ce --arg digest "$digest" \
    '.lifecycle="completed" | .completionDigest=$digest' <<<"$request") || return 1
  timepad_request_publish "$request"
}

timepad_runtime_mutate() {
  local operation=$1 container=$2 response
  shift 2
  timepad_request_begin "$operation" "" "$container" || return 1
  case "$operation" in
    suppress) response=$(timeout 15s docker update --restart=no "$container") || return 1 ;;
    restore-policy) response=$(timeout 15s docker update --restart=unless-stopped "$container") || return 1 ;;
    stop) response=$(timeout 30s docker stop --time 10 "$container") || return 1 ;;
    *) return 1 ;;
  esac
  [ "$#" -eq 0 ] && [ "$response" = "$container" ] || return 1
  timepad_request_acknowledge "$response" && timepad_request_complete
}

owned_child_pid=
owned_child_fifo=
owned_child_phase=
owned_child_attempt=
owned_child_wait_status=0
owned_child_response=
owned_child_grant=
next_owned_child_attempt() {
  local state_json
  state_json=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9) || return 1
  timeout 5s python3 - "$state_json" <<'PY'
import json
import re
import sys

current = json.loads(sys.argv[1])["current"]
incident = current["incidentId"]
latest = current["latestAttemptId"]
if not isinstance(incident, str) or re.fullmatch(r"[a-f0-9]{32}", incident) is None:
    raise SystemExit(1)
sequence = 0
if latest is not None:
    match = re.fullmatch(re.escape(incident) + r":([1-9][0-9]{0,19})", latest)
    if match is None:
        raise SystemExit(1)
    sequence = int(match.group(1))
if sequence >= (1 << 64) - 1:
    raise SystemExit(1)
print(f"{incident}:{sequence + 1}")
PY
}
complete_owned_child() {
  [ -n "$owned_child_pid" ] || return 0
  local cancel=${1:-false} status=0 reaped_json state_json child_json stop_pid stop_status=0
  state_json=$(timeout 10s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9) || return 1
  child_json=$(jq -c '.current.ownedChild' <<<"$state_json") || return 1
  if [ "$child_json" != null ]; then
    [ "$(jq -er '.pid' <<<"$child_json")" = "$owned_child_pid" ] &&
      [ "$(jq -er '.attemptId' <<<"$child_json")" = "$owned_child_attempt" ] ||
      return 1
  fi
  if [ "$cancel" = true ] && [ "$child_json" != null ]; then
    # Run the stopper concurrently with wait: the controller must reap the
    # group leader before Linux can report that its process group disappeared.
    timeout --kill-after=2s 15s python3 "$timepad_helper" stop-owned-child \
      --root "$state_root" --deploy-lock-fd 9 --term-grace-seconds 5 \
      >/dev/null &
    stop_pid=$!
  fi
  wait "$owned_child_pid" || status=$?
  if [ -n "${stop_pid:-}" ]; then
    wait "$stop_pid" || stop_status=$?
    [ "$stop_status" -eq 0 ] || return 1
  fi
  if [ "$child_json" = null ]; then
    # A waiter whose capture/publication failed never received the gate token.
    # Its bounded read expires without executing the command.
    [ "$cancel" = true ] || return 1
  else
    timeout 5s python3 "$timepad_helper" stop-owned-child \
      --root "$state_root" --deploy-lock-fd 9 --term-grace-seconds 0 \
      >/dev/null || return 1
    if [ -n "${owned_child_response:-}" ] && [ "$status" -eq 0 ]; then
      # Only an exact synchronous daemon response can acknowledge the intent.
      # Client death/nonzero/timeout leaves it unresolved even if inspect agrees.
      local response
      response=$(<"$owned_child_response")
      timepad_request_acknowledge "$response" && timepad_request_complete || return 1
    fi
    reaped_json=$(jq -ce '.lifecycle="reaped"' <<<"$child_json") ||
      return 1
    timepad_advance "$owned_child_phase" "" "" "" "" "" "" "" \
      "$reaped_json" "$owned_child_attempt" || return 1
    timepad_advance "$owned_child_phase" "" "" "" "" "" "" "" \
      null "$owned_child_attempt" || return 1
  fi
  [ -z "$owned_child_fifo" ] || rm -f -- "$owned_child_fifo"
  [ -z "${owned_child_response:-}" ] || rm -f -- "$owned_child_response"
  if [ -n "${owned_child_grant:-}" ]; then
    supervisor_client complete "$owned_child_grant" >/dev/null || return 1
  fi
  owned_child_pid=
  owned_child_fifo=
  owned_child_phase=
  owned_child_attempt=
  owned_child_response=
  owned_child_grant=
  owned_child_wait_status=$status
}
run_owned_child() {
  local phase=$1 attempt_id token fifo command_digest child_json
  local released_json grant handshake_grant noclobber_was_set=false
  shift
  [ "$#" -gt 0 ] || fail "OWNED_CHILD_INVALID"
  # This slice admits exact-container synchronous start only. Compose creation
  # needs its own positively correlated daemon completion before this gate can
  # be widened; an empty inventory or client exit cannot supply that proof.
  [ "$#" -eq 6 ] && [ "$1" = timeout ] && [ "$2" = --kill-after=5s ] &&
    [ "$3" = 30s ] && [ "$4" = docker ] && [ "$5" = start ] &&
    [[ "$6" =~ ^[a-f0-9]{64}$ ]] || fail "RUNTIME_REQUEST_CORRELATION_REQUIRED"
  attempt_id=$(next_owned_child_attempt) || fail "OWNED_CHILD_INVALID"
  [[ "$attempt_id" =~ ^[a-f0-9]{32}:[1-9][0-9]{0,19}$ ]] ||
    fail "OWNED_CHILD_INVALID"
  token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$token" =~ ^[0-9a-f]{32}$ ]] || fail "OWNED_CHILD_INVALID"
  command_digest=$(printf '%s\0' "$@" | sha256sum | awk '{print $1}')
  [[ "$command_digest" =~ ^[0-9a-f]{64}$ ]] || fail "OWNED_CHILD_INVALID"
  fifo=$state/.child-handshake-$attempt_id
  [ ! -e "$fifo" ] && [ ! -L "$fifo" ] || fail "OWNED_CHILD_INVALID"
  mkfifo -m 600 -- "$fifo" || fail "OWNED_CHILD_INVALID"
  owned_child_fifo=$fifo
  owned_child_phase=$phase
  owned_child_response=$state/.runtime-response-$attempt_id
  [ ! -e "$owned_child_response" ] && [ ! -L "$owned_child_response" ] ||
    fail "OWNED_CHILD_INVALID"
  grant=$(supervisor_client grant child-handshake 5) || fail "OWNED_CHILD_GRANT_REQUIRED"
  handshake_grant=$(jq -er '.grantId' <<<"$grant") || fail "OWNED_CHILD_GRANT_REQUIRED"
  umask 077
  case $- in *C*) noclobber_was_set=true ;; esac
  set -o noclobber
  setsid bash -c '
    set -euo pipefail
    exec {gate_fd}<>"$1"
    IFS= read -r -t 5 gate <&"$gate_fd" || exit 125
    exec {gate_fd}>&-
    [ "$gate" = "$2" ] || exit 125
    shift 2
    set +e
    "$@" | python3 -c '"'"'
import re
import sys
data = sys.stdin.buffer.read(66)
if re.fullmatch(rb"[a-f0-9]{64}\n", data) is None:
    raise SystemExit(1)
sys.stdout.buffer.write(data)
'"'"'
    statuses=("${PIPESTATUS[@]}")
    [ "${statuses[0]}" -eq 0 ] || exit "${statuses[0]}"
    exit "${statuses[1]}"
  ' _ "$fifo" "$token" "$@" >"$owned_child_response" &
  owned_child_pid=$!
  [ "$noclobber_was_set" = true ] || set +o noclobber
  child_json=
  for ((attempt = 0; attempt < 10; attempt++)); do
    child_json=$(timeout 1s python3 "$timepad_helper" capture-child \
      --pid "$owned_child_pid" --command-digest "$command_digest" \
      --attempt-id "$attempt_id" 2>/dev/null) && break
    sleep 0.02
  done
  [ -n "$child_json" ] ||
    fail "OWNED_CHILD_CAPTURE_FAILED"
  jq -e --argjson pid "$owned_child_pid" --arg digest "$command_digest" \
    --arg attempt "$attempt_id" '
      .pid == $pid and .processGroup == $pid and
      .commandDigest == $digest and .attemptId == $attempt
    ' <<<"$child_json" >/dev/null || fail "OWNED_CHILD_CAPTURE_FAILED"
  owned_child_attempt=$attempt_id
  timepad_advance "$phase" "" "" "" "" "" "" "" \
    "$child_json" "$attempt_id" || fail "OWNED_CHILD_CAPTURE_FAILED"
  timepad_request_begin start "$attempt_id" "$6" || fail "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED"
  supervisor_client complete "$handshake_grant" >/dev/null ||
    fail "OWNED_CHILD_GRANT_REQUIRED"
  grant=$(supervisor_client grant docker 30) || fail "OWNED_CHILD_GRANT_REQUIRED"
  owned_child_grant=$(jq -er '.grantId' <<<"$grant") || fail "OWNED_CHILD_GRANT_REQUIRED"
  released_json=$(jq -ce '.lifecycle="released"' <<<"$child_json") ||
    fail "OWNED_CHILD_CAPTURE_FAILED"
  timepad_advance "$phase" "" "" "" "" "" "" "" \
    "$released_json" "$attempt_id" || fail "OWNED_CHILD_CAPTURE_FAILED"
  local handshake_fd
  exec {handshake_fd}<>"$fifo"
  printf '%s\n' "$token" >&"$handshake_fd"
  exec {handshake_fd}>&-
  complete_owned_child || fail "OWNED_CHILD_QUIESCENCE_UNCONFIRMED"
  return "$owned_child_wait_status"
}

write_provider_marker() {
  local phase=$1
  local disposition=$2
  local temporary="$state_root/.provider-transaction.$run_key.tmp"
  case "$phase" in preparing|prepared|applying|verifying|rolling-back|finalizing) ;; *)
    fail "RECOVERY_REQUIRED"
    ;;
  esac
  case "$disposition" in none|created|reused) ;; *) fail "RECOVERY_REQUIRED" ;; esac
  if [ "$phase" = preparing ]; then
    [ ! -e "$provider_pointer" ] && [ ! -L "$provider_pointer" ] ||
      fail "RECOVERY_REQUIRED"
  fi
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || fail "RECOVERY_REQUIRED"
  umask 077
  printf '{"schemaVersion":1,"runKey":"%s","phase":"%s","providerEnabled":%s,"durableDisposition":"%s"}\n' \
    "$run_key" "$phase" "$provider_enabled" "$disposition" >"$temporary"
  chmod 600 "$temporary"
  timeout 30s python3 - "$temporary" "$state_root" <<'PY'
import os
import sys

for path, directory in ((sys.argv[1], False), (sys.argv[2], True)):
    flags = os.O_RDONLY | (os.O_DIRECTORY if directory else 0)
    fd = os.open(path, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
  timeout 30s mv -f -- "$temporary" "$provider_pointer"
  timeout 30s python3 - "$state_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

timepad_commit_witness() {
  local witness=$state/timepad-commit-witness.json state_json epoch incident digest
  local expected
  state_json=$(timeout 15s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9) || fail "GUARD_STATE_LOST"
  epoch=$(jq -er '.current.operationEpoch | numbers' <<<"$state_json") ||
    fail "GUARD_STATE_LOST"
  incident=$(jq -er '.current.incidentId | strings' <<<"$state_json") ||
    fail "GUARD_STATE_LOST"
  expected=$(jq -cn --arg incident "$incident" --arg container "$candidate_container" \
    --arg hash "$target_hash" --arg image "$target_id" \
    --arg revision "$revision" --arg version "$version" \
    --argjson epoch "$epoch" --argjson provider_enabled "$provider_enabled" \
    '{schema:"meet-backend/test-vps-timepad-commit-witness/v1",
      operationEpoch:$epoch,incidentId:$incident,containerId:$container,
      configHash:$hash,imageId:$image,revision:$revision,version:$version,
      providerEnabled:$provider_enabled}') || fail "GUARD_STATE_LOST"
  if [ -e "$witness" ] || [ -L "$witness" ]; then
    [ -f "$witness" ] && [ ! -L "$witness" ] &&
      [ "$(stat -c '%u:%a:%h' -- "$witness")" = 0:600:1 ] &&
      [ "$(stat -c '%s' -- "$witness")" -le 4096 ] ||
      fail "GUARD_STATE_LOST"
    printf '%s' "$expected" | cmp -s - "$witness" ||
      fail "GUARD_STATE_LOST"
  else
    umask 077
    printf '%s' "$expected" >"$witness"
    chmod 600 "$witness"
  fi
  timeout 15s python3 - "$witness" "$state" <<'PY'
import os
import sys

for path, directory in ((sys.argv[1], False), (sys.argv[2], True)):
    fd = os.open(path, os.O_RDONLY | (os.O_DIRECTORY if directory else 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
  digest=$(sha256sum "$witness" | awk '{print $1}')
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "GUARD_STATE_LOST"
  printf '%s' "$digest"
}

timepad_prepare_transition() {
  local target_binding=$1 predecessor_binding=$2 transition_id=$3
  local incident_id evidence_file admission_file output
  incident_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [[ "$incident_id" =~ ^[0-9a-f]{32}$ ]] || fail "GUARD_STATE_LOST"
  evidence_file=$state/.timepad-prepare.json
  admission_file=$state/.timepad-admission.json
  [ ! -e "$evidence_file" ] && [ ! -L "$evidence_file" ] &&
    [ ! -e "$admission_file" ] && [ ! -L "$admission_file" ] ||
    fail "GUARD_STATE_LOST"
  jq -cn --arg root_id "$(jq -er '.rootId | strings' "$timepad_contract")" \
    --arg target_id "$(jq -er '.id | strings' <<<"$target_binding")" \
    --arg predecessor_id "$(jq -er '.id | strings' <<<"$predecessor_binding")" \
    --arg predecessor_container_id "$previous_container" \
    --arg transition_id "$transition_id" --arg operation "$mode" \
    --arg run_id "$run_key" --arg incident "$incident_id" \
    --arg owned_run "$(basename "$state")" \
    --arg tooling_digest "$(sha256sum "${BASH_SOURCE[0]}" "$runtime_helper" \
      "$timepad_helper" "$timepad_contract" | sha256sum | awk '{print $1}')" \
    --argjson target "$(jq -c '.tuple' <<<"$target_binding")" \
    --argjson predecessor "$(jq -c '.tuple' <<<"$predecessor_binding")" '
      {rootId:$root_id,targetId:$target_id,predecessorId:$predecessor_id,
       predecessorContainerId:$predecessor_container_id,
       transitionId:(if $transition_id == "" then null else $transition_id end),
       target:$target,predecessor:$predecessor,operation:$operation,
       runId:$run_id,incidentId:$incident,ownedRun:$owned_run,
       toolingDigest:$tooling_digest}
    ' >"$evidence_file"
  chmod 600 "$evidence_file"
  jq -c '{rootId,targetId,predecessorId,transitionId,target,predecessor}' \
    "$evidence_file" >"$admission_file"
  chmod 600 "$admission_file"
  output=$(timeout 15s python3 "$timepad_helper" admit \
    --root "$state_root" --contract "$timepad_contract" \
    --evidence "$admission_file" --deploy-lock-fd 9 2>/dev/null) ||
    fail "TIMEPAD_ADMISSION_REFUSED"
  admission_disposition=$(jq -er \
    '.disposition | select(. == "legacy-no-transition" or . == "pre-barrier-only" or . == "post-barrier-compatible")' \
    <<<"$output") || fail "TIMEPAD_ADMISSION_REFUSED"
  if [ "$admission_disposition" = legacy-no-transition ]; then
    rm -f -- "$evidence_file" "$admission_file"
    return 0
  fi
  timepad_admitted=true
}

timepad_publish_prepared_transition() {
  [ "$timepad_admitted" = true ] || return 0
  recovery_budget_arm
  local evidence_file=$state/.timepad-prepare.json
  local admission_file=$state/.timepad-admission.json
  local proof_input proof_output proof_digest grant grant_id deadline output
  proof_input=$(jq -cn --slurpfile evidence "$evidence_file" \
    --argjson predecessor_inspection "$previous_inspect" \
    --argjson image_inspection "$target_image_inspect" \
    --argjson target_configuration "$target_config" '
      {schema:"meet-backend/test-vps-timepad-prepared-input/v1",
       evidence:$evidence[0],predecessorInspection:$predecessor_inspection,
       imageInspection:$image_inspection,targetConfiguration:$target_configuration}
    ') || fail "PROVIDER_STATE_INVALID"
  if [ "$supervisor_enabled" = true ]; then
    grant=$(supervisor_client grant provider 30) ||
      fail "PROVIDER_STATE_INVALID"
    grant_id=$(jq -er '.grantId | strings' <<<"$grant") ||
      fail "PROVIDER_STATE_INVALID"
    deadline=$(jq -er '.endNs | numbers' <<<"$grant") ||
      fail "PROVIDER_STATE_INVALID"
    proof_output=$(printf '%s' "$proof_input" |
      command timeout 30s python3 "$provider_helper" prepare-transition-proof \
        --run-key "$run_key" --state-root "$state_root" \
        --state-kind "$state_suffix" --deploy-lock-fd 9 \
        --execution-attempt "$TIMEPAD_ATTEMPT" --execution-grant "$grant_id" \
        --deadline-ns "$deadline") || {
          supervisor_client complete "$grant_id" >/dev/null || :
          fail "PROVIDER_STATE_INVALID"
        }
    supervisor_client complete "$grant_id" >/dev/null ||
      fail "PROVIDER_STATE_INVALID"
  else
    proof_output=$(printf '%s' "$proof_input" |
      timeout 30s python3 "$provider_helper" prepare-transition-proof \
        --run-key "$run_key" --state-root "$state_root" \
        --state-kind "$state_suffix" --deploy-lock-fd 9) ||
      fail "PROVIDER_STATE_INVALID"
  fi
  proof_digest=$(jq -er \
    '.preparedProofDigest | strings | select(test("^[a-f0-9]{64}$"))' \
    <<<"$proof_output") || fail "PROVIDER_STATE_INVALID"
  jq -e --arg digest "$proof_digest" '.preparedProofDigest=$digest' \
    "$evidence_file" >"$state/.timepad-prepare.next" ||
    fail "PROVIDER_STATE_INVALID"
  chmod 600 "$state/.timepad-prepare.next"
  mv -f -- "$state/.timepad-prepare.next" "$evidence_file"
  output=$(timeout 15s python3 "$timepad_helper" prepare \
    --root "$state_root" --contract "$timepad_contract" \
    --evidence "$evidence_file" --deploy-lock-fd 9 2>/dev/null) ||
    fail "TIMEPAD_ADMISSION_REFUSED"
  jq -e --arg disposition "$admission_disposition" '
    .admission == $disposition and .result == "PREPARED" and
    (.epoch | type == "number" and . > 0)
  ' <<<"$output" >/dev/null || fail "GUARD_STATE_LOST"
  prepared_timepad=true
  rm -f -- "$evidence_file" "$admission_file"
}

state_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
timepad_helper=$script_dir/test_vps_timepad_state.py
timepad_contract=$script_dir/test-vps-timepad-release-contracts.json
active_compose=/var/lib/meet-production/active-compose.yml
active_runtime=/var/lib/meet-production/active-runtime.override.yml
smtp_pointer=$state_root/.smtp-transaction.current
provider_pointer=$state_root/.provider-transaction.current
state_suffix=final-deploy
[ "$mode" = rollback-drill ] && state_suffix=rollback-drill
state=$state_root/$run_key-$state_suffix
if [ ! -e "$state_root" ] && [ ! -L "$state_root" ]; then
  [ "${TIMEPAD_WORKER_MODE:-controller-worker}" != fail-closed-worker ] ||
    fail "QUIESCENCE_UNCONFIRMED"
  install -d -m 700 "$state_root"
fi
[ -d "$state_root" ] && [ ! -L "$state_root" ] ||
  fail "DEPLOY_LOCK_INVALID"
umask 077
if [ -z "${TIMEPAD_WORKER_MODE:-}" ]; then
  exec 9>>"$state_root/.deploy.lock"
  flock -n 9 || fail "another test VPS deployment is active"
else
  case "$TIMEPAD_WORKER_MODE" in
    controller-worker|rollback-worker|fail-closed-worker|retention-worker) ;;
    *) fail "PRIVATE_WORKER_REQUIRED" ;;
  esac
  [ -e /proc/self/fd/9 ] || fail "PRIVATE_WORKER_REQUIRED"
fi
if [ "${TIMEPAD_WORKER_MODE:-controller-worker}" != fail-closed-worker ]; then
  timeout 15s python3 "$timepad_helper" lock-check \
    --root "$state_root" --deploy-lock-fd 9 >/dev/null ||
    fail "DEPLOY_LOCK_INVALID"
fi
if [ -n "${TIMEPAD_WORKER_MODE:-}" ]; then
  supervisor_enabled=true
  trap 'supervisor_cancel_exit "$?"' EXIT
  if [ "$TIMEPAD_WORKER_MODE" = controller-worker ] && [ "$operation" = forward-recover ]; then
    supervisor_register_recovery || fail "RECOVERY_REGISTRATION_REFUSED"
    recovery_admission_only=true
  else
    supervisor_publish_lease || fail "EXECUTION_LEASE_PUBLICATION_FAILED"
  fi
  if [ "$TIMEPAD_WORKER_MODE" = fail-closed-worker ]; then
    if fail_closed_retry_refusal; then
      # Cleanup succeeded; the supervisor still returns the initiating failure.
      trap - EXIT
      exit 0
    fi
    fail_closed_owned_backend || :
    fail_closed_publish_unresolved || :
    fail "QUIESCENCE_UNCONFIRMED"
  fi
  if [ "$TIMEPAD_WORKER_MODE" = rollback-worker ]; then
    rollback_worker_admission
  fi
fi
validate_timepad_input() {
  timeout 10s python3 - "$1" "$2" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
limit = int(sys.argv[2])
try:
    info = os.lstat(path)
except OSError:
    raise SystemExit(1)
if (
    not stat.S_ISREG(info.st_mode)
    or info.st_uid != 0
    or info.st_nlink != 1
    or stat.S_IMODE(info.st_mode) != 0o600
    or info.st_size > limit
):
    raise SystemExit(1)
PY
}
if [ "$operation" = bootstrap-guard ]; then
  bootstrap_authority=$state_root/timepad-bootstrap-authority.json
  bootstrap_observed=$state_root/timepad-bootstrap-observed.json
  validate_timepad_input "$bootstrap_authority" 32768 ||
    fail "BOOTSTRAP_AUTHORITY_REQUIRED"
  validate_timepad_input "$bootstrap_observed" 32768 ||
    fail "BOOTSTRAP_EVIDENCE_REQUIRED"
  jq -e --arg id "$bootstrap_id" '.bootstrapId == $id' \
    "$bootstrap_authority" >/dev/null ||
    fail "BOOTSTRAP_AUTHORITY_MISMATCH"
  recovery_budget_arm
  bootstrap_result=$(timeout 30s python3 "$timepad_helper" bootstrap \
    --root "$state_root" --authority "$bootstrap_authority" \
    --observed "$bootstrap_observed" --deploy-lock-fd 9 2>/dev/null) ||
    fail "BOOTSTRAP_EVIDENCE_INVALID"
  jq -e '
    .outcome as $outcome |
    ($outcome == "bootstrapped" or $outcome == "already-initialized") and
    (.epoch == 0) and (.originDigest | test("^[a-f0-9]{64}$"))
  ' \
    <<<"$bootstrap_result" >/dev/null || fail "BOOTSTRAP_EVIDENCE_INVALID"
  supervisor_complete "$(jq -er '.outcome' <<<"$bootstrap_result")"
  exit 0
fi
if [ "$operation" = forward-recover ]; then
  recovery_budget_arm
  recovery_authorization=$state_root/timepad-recovery-authorization.json
  validate_timepad_input "$recovery_authorization" 32768 ||
    fail "RECOVERY_AUTHORIZATION_REQUIRED"
  recovery_result=$(timeout 30s python3 "$timepad_helper" authorize-recovery \
    --root "$state_root" --authorization "$recovery_authorization" \
    --deploy-lock-fd 9 2>/dev/null) || fail "RECOVERY_AUTHORIZATION_INVALID"
  state_result=$(timeout 15s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9) || fail "GUARD_STATE_LOST"
  jq -e --arg run "$recovery_run_key" --arg incident "$recovery_incident" \
    --arg epoch "$recovery_epoch" --arg binding "$recovery_binding_digest" '
      .current as $s |
      $s.runId == $run and $s.incidentId == ($incident | ascii_downcase) and
      ($s.operationEpoch | tostring) == $epoch and
      $s.evidenceDigest == $binding
    ' <<<"$state_result" >/dev/null || fail "RECOVERY_SELECTOR_MISMATCH"
  jq -e '.outcome == "authorized" or .outcome == "already-completed"' \
    <<<"$recovery_result" >/dev/null || fail "RECOVERY_AUTHORIZATION_INVALID"
  recovery_state=$(jq -ce '.current' <<<"$state_result") ||
    fail "GUARD_STATE_LOST"
  recovery_phase=$(jq -er '.phase | strings' <<<"$recovery_state") ||
    fail "GUARD_STATE_LOST"
  if [[ "$recovery_phase" = COMMITTED || "$recovery_phase" = VERIFYING ||
    "$recovery_phase" = COMMITTING ]]; then
    jq -e '.operation == "deploy"' <<<"$recovery_state" >/dev/null ||
      fail "RECOVERY_OPERATION_REFUSED"
  fi
  recovery_owned_run=$(jq -er '.ownedRun | strings' <<<"$recovery_state") ||
    fail "GUARD_STATE_LOST"
  case "$recovery_owned_run" in
    "$recovery_run_key-final-deploy") recovery_state_suffix=final-deploy ;;
    "$recovery_run_key-rollback-drill") recovery_state_suffix=rollback-drill ;;
    *) fail "RECOVERY_SELECTOR_MISMATCH" ;;
  esac
  recovery_state_dir=$state_root/$recovery_owned_run
  [ -d "$recovery_state_dir" ] && [ ! -L "$recovery_state_dir" ] ||
    fail "GUARD_STATE_LOST"
  state=$recovery_state_dir

  # Recovery is deliberately dispatched before retention, state publication,
  # configuration updates, or Compose creation. The durable container binding
  # is the only runtime identity accepted here; Compose selection is merely a
  # consistency check after that identity has been inspected.
  recovery_target_id=$(docker_image_inspect "$image" --format '{{.Id}}') ||
    fail "RECOVERY_SELECTOR_MISMATCH"
  recovery_image_inspect=$(docker_image_inspect "$image") ||
    fail "RECOVERY_SELECTOR_MISMATCH"
  [ "$(docker_image_inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$revision" ] &&
    [ "$(docker_image_inspect "$image" \
      --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$version" ] &&
    [ "$(docker_image_inspect "$image" \
      --format '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
      "https://github.com/NickolayMamonov/meet-backend-v3" ] &&
    [ "$(docker_image_inspect "$image" --format '{{.Config.User}}')" = 10001:10001 ] ||
    fail "RECOVERY_SELECTOR_MISMATCH"
  printf '%s' "$recovery_image_inspect" |
    timeout 30s python3 "$provider_helper" check-image >/dev/null ||
    fail "RECOVERY_SELECTOR_MISMATCH"
  jq -e --arg image "${recovery_target_id#sha256:}" \
    --arg repository "${image##*@sha256:}" --arg revision "$revision" \
    --arg version "$version" '
      .target != null and
      .target.tuple.platformImageId == $image and
      .target.tuple.repositoryDigest == $repository and
      .target.tuple.revision == $revision and
      .target.tuple.version == $version
    ' <<<"$recovery_state" >/dev/null || fail "RECOVERY_SELECTOR_MISMATCH"
  [ ! -e "$smtp_pointer" ] && [ ! -L "$smtp_pointer" ] ||
    fail "RECOVERY_REQUIRED"

  recovery_container=$(jq -er '.containerId // empty' <<<"$recovery_state") ||
    recovery_container=
  recovery_hash=$(jq -er '.configHash // empty' <<<"$recovery_state") ||
    recovery_hash=
  recovery_commit_digest=$(jq -er '.commitWitnessDigest // empty' \
    <<<"$recovery_state") || recovery_commit_digest=
  recovery_finalization_digest=$(jq -er '.providerFinalizationDigest // empty' \
    <<<"$recovery_state") || recovery_finalization_digest=
  recovery_substep=$(jq -er '.commitSubstep // empty' \
    <<<"$recovery_state") || recovery_substep=
  case "$recovery_phase" in
    COMMITTED|VERIFYING|COMMITTING|RECOVERY_REQUIRED|FORWARD_RECOVERING|\
    CUTOVER_POSSIBLE|ROLLING_BACK) ;;
    PREPARED)
      # No target binding exists before cutover; it cannot be inferred from
      # Compose labels or from an interrupted predecessor rollback.
      fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
      ;;
    *) fail "RECOVERY_PHASE_REFUSED" ;;
  esac
  # Intent without a daemon receipt remains unknown, even after client exit,
  # ECHILD, or agreeing inventories. Read-only provider/runtime admission must
  # precede lease arming, adoption, owned-child stop and every retry writer.
  jq -e '.runtimeRequest != null and
    (.runtimeRequest.lifecycle == "completed" or .runtimeRequest.lifecycle == "acknowledged")' \
    <<<"$recovery_state" >/dev/null ||
    fail "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED"
  if [ "$recovery_phase" = COMMITTED ]; then
    jq -e '.ownedChild == null' <<<"$recovery_state" >/dev/null ||
      fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  fi
  if [ "$recovery_phase" = COMMITTED ]; then
    [ ! -e "$provider_pointer" ] && [ ! -L "$provider_pointer" ] ||
      fail "RECOVERY_TERMINAL_RECEIPT_MISMATCH"
    recovery_pointer_phase=absent
  else
    if [ -e "$provider_pointer" ] || [ -L "$provider_pointer" ]; then
      validate_timepad_input "$provider_pointer" 4096 ||
        fail "RECOVERY_PROVIDER_MARKER_INVALID"
      recovery_pointer_identity=$(configuration_file_identity "$provider_pointer") ||
        fail "RECOVERY_PROVIDER_MARKER_INVALID"
      recovery_pointer_phase=$(timeout 5s jq -er \
        --arg run "$recovery_run_key" \
        '. | select(.schemaVersion == 1 and .runKey == $run) |
         .phase | strings' "$provider_pointer") ||
        fail "RECOVERY_PROVIDER_MARKER_INVALID"
      recovery_disposition=$(timeout 5s jq -er \
        --arg run "$recovery_run_key" \
        '. | select(.schemaVersion == 1 and .runKey == $run) |
         .durableDisposition | strings | select(. == "none" or . == "created" or . == "reused")' \
        "$provider_pointer") || fail "RECOVERY_PROVIDER_MARKER_INVALID"
      recovery_pointer_enabled=$(timeout 5s jq -er \
        --arg run "$recovery_run_key" \
        '. | select(.schemaVersion == 1 and .runKey == $run) |
         .providerEnabled | booleans | tostring' "$provider_pointer") ||
        fail "RECOVERY_PROVIDER_MARKER_INVALID"
      case "$recovery_phase:$recovery_pointer_phase" in
        CUTOVER_POSSIBLE:prepared|CUTOVER_POSSIBLE:applying|\
        CUTOVER_POSSIBLE:verifying|ROLLING_BACK:prepared|\
        ROLLING_BACK:applying|ROLLING_BACK:verifying|ROLLING_BACK:rolling-back|\
        VERIFYING:verifying|VERIFYING:finalizing|COMMITTING:verifying|\
        COMMITTING:finalizing|\
        RECOVERY_REQUIRED:verifying|RECOVERY_REQUIRED:finalizing|\
        FORWARD_RECOVERING:verifying|FORWARD_RECOVERING:finalizing) ;;
        *) fail "RECOVERY_PROVIDER_MARKER_INVALID" ;;
      esac
    else
      recovery_pointer_phase=absent
      [ -n "$recovery_finalization_digest" ] &&
        [ -n "$recovery_commit_digest" ] &&
        { [ "$recovery_phase" = COMMITTING ] ||
          [ "$recovery_phase" = RECOVERY_REQUIRED ] ||
          [ "$recovery_phase" = FORWARD_RECOVERING ]; } ||
        fail "RECOVERY_PROVIDER_MARKER_INVALID"
      recovery_disposition=
      recovery_pointer_enabled=
    fi
  fi
  [[ "$recovery_container" =~ ^[a-f0-9]{12,64}$ ]] &&
    [[ "$recovery_hash" =~ ^[0-9a-f]{64}$ ]] ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  [ "$recovery_substep" != replacement-create-intent ] ||
    fail "RECOVERY_REPLACEMENT_CREATE_UNRESOLVED"
  if ! recovery_inspect=$(timeout 30s docker inspect "$recovery_container" 2>/dev/null); then
    # The exact-container slice cannot correlate Compose create responses yet.
    # Preserve the one-use replacement intent gate; absence is not completion.
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  fi
  [ "$(timeout 30s docker inspect "$recovery_container" \
    --format '{{.Image}}')" = "$recovery_target_id" ] &&
    [ "$(jq -er '.[0].Config.Labels["com.docker.compose.project"] // ""' \
      <<<"$recovery_inspect")" = meet-production ] &&
    [ "$(jq -er '.[0].Config.Labels["com.docker.compose.service"] // ""' \
      <<<"$recovery_inspect")" = backend ] &&
    [ "$(timeout 30s docker inspect "$recovery_container" \
      --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')" = \
      "$recovery_hash" ] ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  recovery_compose_ids=$(timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" ps -aq backend
  ' _ "$runtime_helper" "$root" "$compose_script") ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  [ "$recovery_compose_ids" = "$recovery_container" ] ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  recovery_actual_image=$(jq -er '.[0].Image | strings' <<<"$recovery_inspect") ||
    fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
  recovery_live_stage=admission
  [ "$recovery_actual_image" = "$recovery_target_id" ] &&
    recovery_live_stage=runtime
  if ! jq -e '.ownedChild == null' <<<"$recovery_state" >/dev/null; then
    recovery_live_stage=quiescence
  fi
  recovery_live_proof() {
    jq -c --slurpfile authority "$recovery_authorization" \
      --arg stage "$recovery_live_stage" '
      if type == "array" and length == 1 and
        ($authority | length) == 1 and
        ($authority[0] | type == "object")
      then
        {schema:"meet-backend/test-vps-provider-live-resume/v1",
         authorization:$authority[0],inspection:.,stage:$stage}
      else error("invalid recovery evidence")
      end
      ' <<<"$recovery_inspect" |
      timeout 30s python3 "$provider_helper" live-resume \
        --run-key "$recovery_run_key" --state-root "$state_root" \
        --state-kind "$recovery_state_suffix" --deploy-lock-fd 9
  }
  recovery_live_result=$(recovery_live_proof) ||
    {
      if [ "$recovery_phase" = ROLLING_BACK ]; then
        fail "PROVIDER_REPAIR_REQUIRED"
      fi
      fail "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED"
    }
  recovery_live_outcome=$(jq -er \
    '.outcome | select(. == "already-completed" or . == "finalization-only" or . == "retry-exact-candidate")' \
    <<<"$recovery_live_result") || fail "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED"
  validate_configuration_boundary "$state/config.env.target"
  recovery_request_proof=
  if [ "$(jq -er '.runtimeRequest.lifecycle' <<<"$recovery_state")" = acknowledged ]; then
    recovery_request_nonce=$(jq -er '.runtimeRequest.nonce' <<<"$recovery_state") ||
      fail "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED"
    recovery_request_proof=$(jq -cn --arg nonce "$recovery_request_nonce" \
      --argjson inspection "$recovery_inspect" '{requestNonce:$nonce,inspection:$inspection}' |
      timeout 15s python3 "$provider_helper" runtime-request-proof \
        --run-key "$recovery_run_key" --state-root "$state_root" \
        --state-kind "$recovery_state_suffix" --deploy-lock-fd 9) ||
      fail "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED"
  fi
  recovery_admission_only=false
  supervisor_client arm >/dev/null || fail "EXECUTION_SUPERVISOR_ARM_FAILED"
  supervisor_publish_lease || fail "EXECUTION_LEASE_PUBLICATION_FAILED"
  if [ "$recovery_phase" != COMMITTED ]; then
    adoption_args=()
    if [ -n "$recovery_request_proof" ]; then
      adoption_args=(--request-nonce "$recovery_request_nonce" --completion-digest \
        "$(jq -er '.completionDigest' <<<"$recovery_request_proof")")
    fi
    timeout 15s python3 "$timepad_helper" adopt-recovery \
      --root "$state_root" --contract "$timepad_contract" --deploy-lock-fd 9 \
      "${adoption_args[@]}" >/dev/null || fail "RECOVERY_ADOPTION_REFUSED"
  fi
  recovery_child=$(jq -c '.ownedChild' <<<"$recovery_state") ||
    fail "GUARD_STATE_LOST"
  if [ "$recovery_child" != null ]; then
    # Only after read-only authority, contract and provider/SMTP admission may
    # the state helper stop its positively identified owned group. Publication
    # proves absence again; a missing leader alone never authorizes clearing.
    timeout --kill-after=2s 15s python3 "$timepad_helper" stop-owned-child \
      --root "$state_root" --deploy-lock-fd 9 --term-grace-seconds 5 >/dev/null ||
      fail "OWNED_CHILD_QUIESCENCE_UNCONFIRMED"
    recovery_child=$(jq -ce '.lifecycle="reaped"' <<<"$recovery_child") ||
      fail "GUARD_STATE_LOST"
    timepad_advance "$recovery_phase" "" "" "" "" "" "" "" "$recovery_child"
    timepad_advance "$recovery_phase" "" "" "" "" "" "" "" null
    recovery_inspect=$(timeout 30s docker inspect "$recovery_container" 2>/dev/null) ||
      fail "RECOVERY_OWNERSHIP_PROOF_REQUIRED"
    recovery_live_stage=runtime
    recovery_live_result=$(recovery_live_proof) ||
      fail "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED"
    recovery_live_outcome=$(jq -er \
      '.outcome | select(. == "finalization-only" or . == "retry-exact-candidate")' \
      <<<"$recovery_live_result") || fail "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED"
    validate_configuration_boundary "$state/config.env.target"
  fi
  recovery_running=$(jq -er '.[0].State.Running | booleans | tostring' <<<"$recovery_inspect") ||
    fail "RECOVERY_REQUIRED"
  recovery_health=$(jq -er '.[0].State.Health.Status // "none"' \
    <<<"$recovery_inspect") || fail "RECOVERY_REQUIRED"
  recovery_restart=$(jq -er '.[0].HostConfig.RestartPolicy.Name' \
    <<<"$recovery_inspect") || fail "RECOVERY_REQUIRED"

  if [ "$recovery_phase" = COMMITTED ]; then
    [ "$recovery_live_outcome" = already-completed ] ||
      fail "RECOVERY_TERMINAL_RECEIPT_MISMATCH"
    [ "$recovery_running" = true ] && [ "$recovery_health" = healthy ] &&
      [ "$recovery_restart" = unless-stopped ] ||
      fail "RECOVERY_TERMINAL_RUNTIME_MISMATCH"
    runtime_invariants_bounded "$recovery_target_id" "$revision" "$version" \
      "$recovery_hash" >/dev/null 2>&1 ||
      fail "RECOVERY_TERMINAL_RUNTIME_MISMATCH"
    runtime_environment_bounded >/dev/null 2>&1 ||
      fail "RECOVERY_TERMINAL_RUNTIME_MISMATCH"
    (verify_public_contract "$public_url") ||
      fail "RECOVERY_TERMINAL_RUNTIME_MISMATCH"
    recovery_receipt=$(printf '%s' "$recovery_inspect" |
      timeout 30s python3 "$provider_helper" finish-committed-resume \
        --run-key "$recovery_run_key" --state-root "$state_root" \
        --state-kind "$recovery_state_suffix" --deploy-lock-fd 9) ||
      fail "RECOVERY_TERMINAL_RECEIPT_MISMATCH"
    recovery_receipt_digest=$(printf '%s' "$recovery_receipt" |
      sha256sum | awk '{print $1}')
    [ "$recovery_receipt_digest" = \
      "$(jq -er '.terminalReceipt | strings' <<<"$recovery_state")" ] ||
      fail "RECOVERY_TERMINAL_RECEIPT_MISMATCH"
    supervisor_complete already-completed
    exit 0
  fi

  recovery_retry_needed=false
  if [ "$recovery_running" = true ] && [ "$recovery_health" = healthy ] &&
    [ "$recovery_phase" != CUTOVER_POSSIBLE ] &&
    [ "$recovery_phase" != ROLLING_BACK ]; then
    if [ -z "$recovery_finalization_digest" ]; then
      [ "$recovery_restart" = no ] || fail "RECOVERY_RUNTIME_MISMATCH"
      [ "$recovery_live_outcome" = finalization-only ] ||
        fail "RECOVERY_PROVIDER_LIVE_PROOF_REQUIRED"
    else
      case "$recovery_substep:$recovery_restart" in
        provider-cleanup:no|terminal-policy-intent:no|\
        terminal-policy-intent:unless-stopped|policy-restored:no|\
        policy-restored:unless-stopped|\
        replacement-container-authorized:no|replacement-provider-cleanup:no|\
        replacement-terminal-policy-intent:no|\
        replacement-terminal-policy-intent:unless-stopped|\
        replacement-policy-restored:no|replacement-policy-restored:unless-stopped) ;;
        *) fail "RECOVERY_RUNTIME_MISMATCH" ;;
      esac
    fi
  elif [ "$recovery_live_outcome" = retry-exact-candidate ] &&
    [[ "$recovery_phase" =~ ^(CUTOVER_POSSIBLE|ROLLING_BACK|VERIFYING|COMMITTING|RECOVERY_REQUIRED|FORWARD_RECOVERING)$ ]]; then
    recovery_retry_needed=true
    case "$recovery_substep:$recovery_restart" in
      provider-cleanup:no|terminal-policy-intent:no|\
      terminal-policy-intent:unless-stopped|policy-restored:no|\
      policy-restored:unless-stopped|\
      replacement-container-authorized:no|replacement-provider-cleanup:no|\
      replacement-terminal-policy-intent:no|\
      replacement-terminal-policy-intent:unless-stopped|\
      replacement-policy-restored:no|replacement-policy-restored:unless-stopped|\
      :no) ;;
      *) fail "RECOVERY_RUNTIME_MISMATCH" ;;
    esac
  else
    fail "RECOVERY_RETRY_REQUIRES_QUIESCENCE"
  fi

  recovery_finalization_started=true
  on_recovery_exit() {
    local status=$?
    if [ "${supervisor_enabled:-false}" = true ]; then
      supervisor_cancel_exit "$status"
    fi
    trap - EXIT
    trap '' TERM INT HUP
    if [ -n "$owned_child_pid" ]; then
      complete_owned_child true || {
        echo "test VPS deployment failed: OWNED_CHILD_QUIESCENCE_UNCONFIRMED" >&2
        exit 1
      }
    fi
    if [ "$status" -ne 0 ] && [ "$recovery_finalization_started" = true ]; then
      local live_inspect live_image live_hash live_project live_service
      live_inspect=$(timeout 30s docker inspect "$recovery_container" 2>/dev/null) ||
        live_inspect=
      if [ -n "$live_inspect" ]; then
        live_image=$(jq -r '.[0].Image // ""' <<<"$live_inspect")
        live_hash=$(jq -r \
          '.[0].Config.Labels["com.docker.compose.config-hash"] // ""' \
          <<<"$live_inspect")
        live_project=$(jq -r \
          '.[0].Config.Labels["com.docker.compose.project"] // ""' \
          <<<"$live_inspect")
        live_service=$(jq -r \
          '.[0].Config.Labels["com.docker.compose.service"] // ""' \
          <<<"$live_inspect")
        if [ "$live_image" = "$recovery_target_id" ] &&
          [ "$live_hash" = "$recovery_hash" ] &&
          [ "$live_project" = meet-production ] &&
          [ "$live_service" = backend ]; then
          timeout 15s docker update --restart=no "$recovery_container" \
            >/dev/null 2>&1 || :
          timeout 30s docker stop --time 10 "$recovery_container" \
            >/dev/null 2>&1 || :
          [ "$(timeout 30s docker inspect "$recovery_container" \
            --format '{{.State.Running}}' 2>/dev/null)" = false ] || {
            echo "test VPS deployment failed: QUIESCENCE_UNCONFIRMED" >&2
          }
        else
          echo "test VPS deployment failed: QUIESCENCE_UNCONFIRMED" >&2
        fi
      else
        echo "test VPS deployment failed: QUIESCENCE_UNCONFIRMED" >&2
      fi
    fi
    exit "$status"
  }
  trap on_recovery_exit EXIT
  trap 'trap "" TERM INT HUP; exit 143' TERM INT HUP

  state=$recovery_state_dir
  run_key=$recovery_run_key
  state_suffix=$recovery_state_suffix
  candidate_container=$recovery_container
  target_id=$recovery_target_id
  target_hash=$recovery_hash
  recovery_replacement=false
  case "$recovery_substep" in replacement-*) recovery_replacement=true ;; esac
  provider_enabled=$(jq -er '.[0].Config.Env |
    map(select(startswith("APP_PUSH_PROVIDER_ENABLED="))) |
    if length == 1 then .[0] | split("=")[1] | ascii_downcase == "true"
    else false end | tostring' <<<"$recovery_inspect") ||
    fail "RECOVERY_RUNTIME_MISMATCH"
  if [ "$recovery_phase" != COMMITTED ]; then
    if [ "$recovery_pointer_phase" != absent ]; then
      [ "$recovery_pointer_enabled" = "$provider_enabled" ] ||
        fail "RECOVERY_PROVIDER_MARKER_INVALID"
    fi
  fi
  recovery_finalization_started=true
  if [ "$recovery_retry_needed" = false ]; then
    case "$recovery_phase" in
      RECOVERY_REQUIRED|FORWARD_RECOVERING)
        timepad_advance FORWARD_RECOVERING EXACT_HEALTHY_RUNTIME_FINALIZATION
        if [ -n "$recovery_finalization_digest" ]; then
          timepad_advance COMMITTING
          recovery_phase=COMMITTING
        else
          timepad_advance VERIFYING
          recovery_phase=VERIFYING
        fi
        ;;
    esac
    recovery_epoch_value=$(jq -er '.operationEpoch | numbers' \
      <<<"$recovery_state") || fail "GUARD_STATE_LOST"
    if [ "$recovery_restart" = no ]; then
      runtime_guarded_invariants_bounded "$recovery_target_id" "$revision" \
        "$version" "$recovery_hash" "$recovery_container" "$recovery_epoch_value" \
        >/dev/null 2>&1 || fail "RECOVERY_RUNTIME_MISMATCH"
    else
      runtime_invariants_bounded "$recovery_target_id" "$revision" "$version" \
        "$recovery_hash" >/dev/null 2>&1 ||
        fail "RECOVERY_RUNTIME_MISMATCH"
    fi
    runtime_environment_bounded >/dev/null 2>&1 ||
      fail "RECOVERY_RUNTIME_MISMATCH"
    (verify_public_contract "$public_url") || fail "RECOVERY_RUNTIME_MISMATCH"
  fi
  if [ "$recovery_retry_needed" = true ]; then
    timepad_advance FORWARD_RECOVERING EXACT_IMAGE_RETRY
    [ "$recovery_restart" = no ] ||
      timepad_runtime_mutate suppress "$candidate_container" \
        >/dev/null || fail "RECOVERY_RETRY_QUIESCE_FAILED"
    if [ "$recovery_running" = true ]; then
      timepad_runtime_mutate stop "$candidate_container" \
        >/dev/null || fail "RECOVERY_RETRY_QUIESCE_FAILED"
    fi
    [ "$(timeout 30s docker inspect "$candidate_container" \
      --format '{{.State.Running}}')" = false ] ||
      fail "RECOVERY_RETRY_QUIESCE_FAILED"
    [ "$(timeout 30s docker inspect "$candidate_container" \
      --format '{{.HostConfig.RestartPolicy.Name}}')" = no ] ||
      fail "RECOVERY_RETRY_QUIESCE_FAILED"
    run_owned_child FORWARD_RECOVERING timeout --kill-after=5s 30s docker start \
      "$candidate_container" >/dev/null || fail "RECOVERY_RETRY_START_FAILED"
    recovery_deadline=$(recovery_health_deadline 180) ||
      fail "RECOVERY_RETRY_HEALTH_FAILED"
    while recovery_health_window_open "$recovery_deadline"; do
      recovery_deadline_check
      recovery_health=$(timeout 30s docker inspect "$candidate_container" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') ||
        fail "RECOVERY_RETRY_HEALTH_FAILED"
      case "$recovery_health" in
        healthy) break ;;
        starting) sleep 2 ;;
        *) fail "RECOVERY_RETRY_HEALTH_FAILED" ;;
      esac
    done
    [ "$recovery_health" = healthy ] || fail "RECOVERY_RETRY_HEALTH_FAILED"
    recovery_inspect=$(timeout 30s docker inspect "$candidate_container") ||
      fail "RECOVERY_RETRY_IDENTITY_FAILED"
    [ "$(jq -er '.[0].Id | strings' <<<"$recovery_inspect")" = "$candidate_container" ] &&
      [ "$(jq -er '.[0].Image | strings' <<<"$recovery_inspect")" = "$recovery_target_id" ] &&
      [ "$(jq -er '.[0].Config.Labels["com.docker.compose.config-hash"] | strings' \
        <<<"$recovery_inspect")" = "$recovery_hash" ] &&
      [ "$(jq -er '.[0].State.Running' <<<"$recovery_inspect")" = true ] &&
      [ "$(jq -er '.[0].HostConfig.RestartPolicy.Name' \
        <<<"$recovery_inspect")" = no ] ||
      fail "RECOVERY_RETRY_IDENTITY_FAILED"
    if [ -n "$recovery_finalization_digest" ]; then
      timepad_advance COMMITTING
      recovery_phase=COMMITTING
    else
      timepad_advance VERIFYING
      write_provider_marker verifying "$recovery_disposition"
      recovery_pointer_phase=verifying
      recovery_pointer_identity=$(configuration_file_identity "$provider_pointer") ||
        fail "RECOVERY_PROVIDER_MARKER_INVALID"
      recovery_phase=VERIFYING
      recovery_substep=
    fi
    recovery_epoch_value=$(jq -er '.operationEpoch | numbers' \
      <<<"$recovery_state") || fail "GUARD_STATE_LOST"
    runtime_guarded_invariants_bounded "$recovery_target_id" "$revision" \
      "$version" "$recovery_hash" "$candidate_container" "$recovery_epoch_value" \
      >/dev/null 2>&1 || recovery_retry_runtime_refusal
    runtime_environment_bounded >/dev/null 2>&1 ||
      recovery_retry_runtime_refusal
    (verify_public_contract "$public_url") ||
      recovery_retry_runtime_refusal
    recovery_running=true
    recovery_health=healthy
    recovery_restart=no
  fi
  if [ -z "$recovery_finalization_digest" ]; then
    [ "$recovery_phase" = VERIFYING ] || fail "RECOVERY_WITNESS_REQUIRED"
  else
    [ -n "$recovery_commit_digest" ] || fail "RECOVERY_WITNESS_REQUIRED"
  fi
  if [ -z "$recovery_finalization_digest" ]; then
    recovery_commit_digest=$(timepad_commit_witness)
    recovery_finalization=$(printf '%s' "$recovery_inspect" |
      timeout 30s python3 "$provider_helper" prepare-finalization \
        --run-key "$run_key" --state-root "$state_root" \
        --state-kind "$state_suffix" --deploy-lock-fd 9) ||
      fail "RECOVERY_WITNESS_REQUIRED"
    recovery_finalization_digest=$(jq -er \
      '.providerFinalizationDigest | strings | select(test("^[0-9a-f]{64}$"))' \
      <<<"$recovery_finalization") || fail "RECOVERY_WITNESS_REQUIRED"
    timepad_advance COMMITTING "" "$candidate_container" "$target_hash" "" \
      "$recovery_commit_digest" provider-cleanup "$recovery_finalization_digest"
    recovery_phase=COMMITTING
    recovery_substep=provider-cleanup
  elif [ "$recovery_phase" != COMMITTING ]; then
    timepad_advance FORWARD_RECOVERING EXACT_HEALTHY_RUNTIME_FINALIZATION
    if [ "$recovery_replacement" = true ]; then
      timepad_advance COMMITTING
    else
      timepad_advance COMMITTING "" "" "" "" "" provider-cleanup
    fi
  fi
  if [ "$recovery_pointer_phase" = verifying ]; then
    recovery_pointer_tmp=$state_root/.provider-transaction.$run_key.tmp
    [ ! -e "$recovery_pointer_tmp" ] && [ ! -L "$recovery_pointer_tmp" ] ||
      fail "RECOVERY_PROVIDER_MARKER_INVALID"
    umask 077
    (set -o noclobber
      jq -cn --arg run "$run_key" --arg disposition "$recovery_disposition" \
        --argjson enabled "$provider_enabled" \
        '{schemaVersion:1,runKey:$run,phase:"finalizing",
          providerEnabled:$enabled,durableDisposition:$disposition}' \
        >"$recovery_pointer_tmp") || fail "RECOVERY_PROVIDER_MARKER_INVALID"
    chmod 600 "$recovery_pointer_tmp"
    timeout 15s python3 - "$recovery_pointer_tmp" "$state_root" <<'PY'
import os
import sys

for path, directory in ((sys.argv[1], False), (sys.argv[2], True)):
    fd = os.open(path, os.O_RDONLY | (os.O_DIRECTORY if directory else 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
PY
    [ "$(configuration_file_identity "$provider_pointer")" = \
      "$recovery_pointer_identity" ] ||
      fail "RECOVERY_PROVIDER_MARKER_INVALID"
    timeout 15s mv -f -- "$recovery_pointer_tmp" "$provider_pointer" ||
      fail "RECOVERY_PROVIDER_MARKER_INVALID"
    timeout 15s python3 - "$state_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  fi
  recovery_receipt=$(printf '%s' "$recovery_inspect" |
    timeout 30s python3 "$provider_helper" finish-committed-resume \
      --run-key "$run_key" --state-root "$state_root" \
      --state-kind "$state_suffix" --deploy-lock-fd 9) ||
    fail "RECOVERY_PROVIDER_FINALIZATION_FAILED"
  if [ "$recovery_replacement" = true ]; then
    case "$recovery_substep" in
      replacement-container-authorized)
        timepad_advance COMMITTING "" "" "" "" "" replacement-provider-cleanup
        timepad_advance COMMITTING "" "" "" "" "" replacement-terminal-policy-intent
        ;;
      replacement-provider-cleanup)
        timepad_advance COMMITTING "" "" "" "" "" replacement-terminal-policy-intent
        ;;
      replacement-terminal-policy-intent|replacement-policy-restored) ;;
      *) fail "RECOVERY_SUBSTEP_INVALID" ;;
    esac
  else
    case "$recovery_substep" in
      provider-cleanup)
        timepad_advance COMMITTING "" "" "" "" "" terminal-policy-intent
        ;;
      "")
        fail "RECOVERY_SUBSTEP_INVALID"
        ;;
      terminal-policy-intent|policy-restored) ;;
      *) fail "RECOVERY_SUBSTEP_INVALID" ;;
    esac
  fi
  if [ "$recovery_restart" = no ]; then
    timepad_runtime_mutate restore-policy "$candidate_container" \
      >/dev/null || fail "RECOVERY_POLICY_RESTORE_FAILED"
  fi
  [ "$(timeout 30s docker inspect "$candidate_container" \
    --format '{{.HostConfig.RestartPolicy.Name}}')" = unless-stopped ] ||
    fail "RECOVERY_POLICY_RESTORE_FAILED"
  [ "$(timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" ps -q backend
  ' _ "$runtime_helper" "$root" "$compose_script")" = "$candidate_container" ] ||
    fail "RECOVERY_RUNTIME_MISMATCH"
  runtime_invariants_bounded "$target_id" "$revision" "$version" \
    "$target_hash" >/dev/null 2>&1 ||
    fail "RECOVERY_RUNTIME_MISMATCH"
  runtime_environment_bounded >/dev/null 2>&1 ||
    fail "RECOVERY_RUNTIME_MISMATCH"
  (verify_public_contract "$public_url") || fail "RECOVERY_RUNTIME_MISMATCH"
  recovery_receipt_digest=$(printf '%s' "$recovery_receipt" |
    sha256sum | awk '{print $1}')
  if [ "$recovery_replacement" = true ]; then
    [ "$recovery_substep" = replacement-policy-restored ] ||
      timepad_advance COMMITTING "" "" "" "" "" replacement-policy-restored
    timepad_advance COMMITTED "" "" "" "$recovery_receipt_digest" "" \
      replacement-policy-restored
  else
    [ "$recovery_substep" = policy-restored ] ||
      timepad_advance COMMITTING "" "" "" "" "" policy-restored
    timepad_advance COMMITTED "" "" "" "$recovery_receipt_digest" "" \
      policy-restored
  fi
  echo "schema_guard=committed"
  echo "operation_outcome=deployment-completed"
  exit 0
fi
# Rollback reconstruction and daemon quiescence are not yet integrated.
# Do not allow an ordinary deploy to reach its first writer.
fail "EXECUTION_CONTROLLER_LIFECYCLE_UNAVAILABLE"
if [ "$closed_beta_safety" = true ]; then
  [ -f "$safety_hook" ] && [ ! -L "$safety_hook" ] && [ -x "$safety_hook" ] ||
    fail "closed-beta safety hook is unavailable"
fi

# This is intentionally an existence/type-only interlock.  SMTP tooling owns
# parsing, recovery, terminal publication, and cleanup of every object class.
if [ -e "$smtp_pointer" ] || [ -L "$smtp_pointer" ]; then
  fail "SMTP transaction is active; reconcile it with the SMTP tooling first"
fi
if [ -e "$provider_pointer" ] || [ -L "$provider_pointer" ]; then
  fail "RECOVERY_REQUIRED"
fi
timeout 30s python3 "$provider_helper" retention-check \
  --state-root "$state_root" --deploy-lock-fd 9 >/dev/null ||
  fail "RECOVERY_REQUIRED"

timeout 30s python3 "$provider_helper" state-publish \
  --state-root "$state_root" \
  --run-key "$run_key" \
  --state-kind "$state_suffix" --deploy-lock-fd 9 >/dev/null ||
  fail "RECOVERY_REQUIRED"

compose() {
  timeout 30s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" "${@:4}"
  ' _ "$runtime_helper" "$root" "$compose_script" "$@" 2>/dev/null
}

compose_up() {
  timeout 240s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" "${@:4}"
  ' _ "$runtime_helper" "$root" "$compose_script" "$@" 2>/dev/null
}

previous_image=$(runtime_release_field_bounded BACKEND_IMAGE) ||
  fail "PROVIDER_STATE_INVALID"
previous_version=$(runtime_release_field_bounded BACKEND_VERSION) ||
  fail "PROVIDER_STATE_INVALID"
previous_revision=$(runtime_release_field_bounded BACKEND_REVISION) ||
  fail "PROVIDER_STATE_INVALID"
[[ "$previous_revision" =~ ^[0-9a-f]{40}$ ]] ||
  fail "running revision is malformed"
[[ "$previous_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  fail "running version is malformed"
is_supported_test_vps_version "$previous_version" ||
  fail "predecessor version must be at least v1.2.0"
previous_id=$(runtime_image_id_bounded) ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$previous_image" --format '{{.Id}}')" = "$previous_id" ] ||
  fail "PROVIDER_STATE_INVALID"
previous_container=$(compose ps -q backend)
[ -n "$previous_container" ] || fail "predecessor backend is unavailable"
previous_runtime_hash=$(docker_container_inspect "$previous_container" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') ||
  fail "PROVIDER_STATE_INVALID"
[[ "$previous_runtime_hash" =~ ^[0-9a-f]{64}$ ]]
runtime_invariants_bounded "$previous_id" "$previous_revision" \
  "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 ||
  fail "PROVIDER_STATE_INVALID"
runtime_environment_bounded >/dev/null 2>&1 ||
  fail "running container does not match the current production environment"
previous_inspect=$(docker_container_inspect "$previous_container" 2>/dev/null) ||
  fail "PROVIDER_STATE_INVALID"
provider_observed=$(printf '%s' "$previous_inspect" |
  timeout 30s python3 "$provider_helper" observe) ||
  fail "PROVIDER_STATE_INVALID"
jq -e '
  type == "object" and .schemaVersion == 1 and
  (.providerEnabled | type == "boolean") and
  (.credentialMountPresent | type == "boolean") and
  (.credentialMountReadOnly | type == "boolean") and
  (.outcome == "observed")
' <<<"$provider_observed" >/dev/null || fail "PROVIDER_STATE_INVALID"
provider_enabled=$(jq -r '.providerEnabled' <<<"$provider_observed")

# Register the transaction before creating any private snapshot or identity
# file.  An interrupted pre-marker snapshot is otherwise indistinguishable
# from an abandoned ordinary run directory to retention.
write_provider_marker preparing none

snapshot_configuration
validate_configuration_boundary "$state/config.env.production"
printf '%s\n' "$previous_image" >"$state/previous-image"
printf '%s\n' "$previous_id" >"$state/previous-image-id"
printf '%s\n' "$previous_revision" >"$state/previous-revision"
printf '%s\n' "$previous_version" >"$state/previous-version"
printf '%s\n' "$previous_runtime_hash" >"$state/previous-runtime-config-hash"
if [ -e "$active_compose" ]; then
  [ -s "$active_compose" ] || fail "active Compose file is empty"
fi
if [ -e "$active_runtime" ]; then
  [ -s "$active_runtime" ] || fail "active runtime override is empty"
fi
snapshot_active_file "$active_compose" compose
snapshot_active_file "$active_runtime" runtime

run_safety_hook() {
  local phase=$1
  local expected_image=$2
  local expected_id=$3
  local expected_revision=$4
  local expected_version=$5
  local expected_runtime_hash=$6
  local output=$state/$phase.json
  [ "$closed_beta_safety" = true ] || return 0
  [ ! -e "$output" ] && [ ! -L "$output" ] ||
    fail "closed-beta $phase evidence already exists"
  safety_args=(
    --phase "$phase"
    --root "$root"
    --compose-script "$compose_script"
    --state-dir "$state"
    --expected-image "$expected_image"
    --expected-image-id "$expected_id"
    --expected-revision "$expected_revision"
    --expected-version "$expected_version"
    --expected-runtime-hash "$expected_runtime_hash"
    --state-mode "$state_mode"
  )
  if [ -n "$public_url" ]; then
    safety_args+=(--public-url "$public_url")
  fi
  timeout 60s "$safety_hook" "${safety_args[@]}" \
    --output "$output" >/dev/null 2>&1 ||
    fail "RECOVERY_REQUIRED"
  [ -f "$output" ] && [ ! -L "$output" ] && [ -s "$output" ] ||
    fail "closed-beta $phase evidence is unavailable"
  chmod 600 "$output"
  if [ "$phase" = final ] && [ -n "$public_url" ]; then
    timeout 60s "$script_dir/verify-test-vps-assets.sh" \
      --public-url "$public_url" \
      --output "$state/frozen-assets.json" >/dev/null 2>&1 ||
      fail "RECOVERY_REQUIRED"
    curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
      --proto '=https' --tlsv1.2 \
      "$public_url/meetings" | jq -e 'type == "array"' >/dev/null
    [ "$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --proto '=https' --tlsv1.2 \
      -o /dev/null -w '%{http_code}' "$public_url/actuator")" = 404 ] ||
      fail "Actuator is not private"
    headers=$(mktemp)
    trap 'rm -f -- "$headers"' RETURN
    curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --proto '=http' \
      -D "$headers" -o /dev/null "${public_url/https:\/\//http://}/meetings"
    grep -Eiq '^location: https://' "$headers" ||
      fail "HTTP does not redirect to HTTPS"
    rm -f -- "$headers"
    missing_admin=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --output /dev/null \
      --write-out '%{http_code}' -X POST \
      "$public_url/admin/demo-catalog/bootstrap" \
      -H 'Content-Type: application/json' --data '{}')
    wrong_admin=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
      --output /dev/null \
      --write-out '%{http_code}' -X POST \
      "$public_url/admin/demo-catalog/bootstrap" \
      -H 'X-Admin-Key: wrong' -H 'Content-Type: application/json' --data '{}')
    [ "$missing_admin" = 403 ] && [ "$wrong_admin" = 403 ] ||
      fail "admin guard did not reject unauthenticated requests"
  fi
}

write_terminal_record() {
  local outcome=$1
  local terminal="$state/terminal.json"
  [ "$outcome" = committed ] || [ "$outcome" = rolled-back ] ||
    fail "RECOVERY_REQUIRED"
  umask 077
  timeout 30s jq -cn --arg run_key "$run_key" --arg outcome "$outcome" \
    --argjson enabled "$provider_enabled" \
    '{schemaVersion:1,runKey:$run_key,outcome:$outcome,providerEnabled:$enabled}' \
    >"$terminal"
  chmod 600 "$terminal"
  timeout 30s python3 - "$terminal" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
}

provider_finish() {
  local outcome=$1
  local inspection=$2
  write_provider_marker finalizing \
    "${durable_disposition:-none}"
  if [ "$prepared_timepad" = true ] && [ "$outcome" = committed ]; then
    printf '%s' "$inspection" |
      timeout 30s python3 "$provider_helper" finish-committed-resume \
        --run-key "$run_key" --state-root "$state_root" \
        --state-kind "$state_suffix" --deploy-lock-fd 9 >/dev/null ||
      fail "RECOVERY_REQUIRED"
  else
    printf '%s' "$inspection" |
      timeout 30s python3 "$provider_helper" finish \
        --run-key "$run_key" --state-root "$state_root" \
        --outcome "$outcome" --deploy-lock-fd 9 >/dev/null ||
      fail "RECOVERY_REQUIRED"
    write_terminal_record "$outcome"
    timeout 30s rm -f -- "$provider_pointer" || fail "RECOVERY_REQUIRED"
    timeout 30s python3 - "$state_root" <<'PY'
import os
import sys

fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  fi
  timeout 30s jq -cn --argjson enabled "$provider_enabled" --arg outcome "$outcome" \
    '{schemaVersion:1,providerEnabled:$enabled,credentialMountPresent:$enabled,
      credentialMountReadOnly:$enabled,outcome:$outcome}'
}

guarded_candidate_start() {
  local ids id_count candidate_json candidate_image running restart status deadline candidate_id
  recovery_work_check || fail "RECOVERY_REQUIRED"
  local predecessor_current predecessor_state predecessor_restart
  predecessor_current=$(compose ps -q backend) || fail "RECOVERY_REQUIRED"
  [ "$predecessor_current" = "$previous_container" ] || fail "RECOVERY_REQUIRED"
  predecessor_state=$(docker_container_inspect "$previous_container") ||
    fail "RECOVERY_REQUIRED"
  [ "$(docker_container_inspect "$previous_container" \
    --format '{{.Image}}')" = "$previous_id" ] &&
    [ "$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' \
      <<<"$predecessor_state")" = meet-production ] &&
    [ "$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // ""' \
      <<<"$predecessor_state")" = backend ] &&
    [ "$(docker_container_inspect "$previous_container" \
      --format '{{.State.Running}}')" = true ] ||
    fail "RECOVERY_REQUIRED"
  timeout 15s docker update --restart=no "$previous_container" >/dev/null ||
    fail "RECOVERY_REQUIRED"
  predecessor_restart=$(docker_container_inspect "$previous_container" \
    --format '{{.HostConfig.RestartPolicy.Name}}') || fail "RECOVERY_REQUIRED"
  [ "$predecessor_restart" = no ] || fail "RECOVERY_REQUIRED"
  timeout 30s docker stop --time 10 "$previous_container" >/dev/null ||
    fail "RECOVERY_REQUIRED"
  [ "$(docker_container_inspect "$previous_container" \
    --format '{{.State.Running}}')" = false ] || fail "RECOVERY_REQUIRED"

  unsafe_cutover_latch=true
  timepad_advance CUTOVER_POSSIBLE CUTOVER_ACKNOWLEDGED
  local fence_state fence_phase fence_epoch
  fence_state=$(timeout 15s python3 "$timepad_helper" read-state \
    --root "$state_root" --deploy-lock-fd 9) || fail "GUARD_STATE_LOST"
  fence_phase=$(jq -er '.current.phase | strings' <<<"$fence_state") ||
    fail "GUARD_STATE_LOST"
  fence_epoch=$(jq -er '.current.operationEpoch | numbers' <<<"$fence_state") ||
    fail "GUARD_STATE_LOST"
  [ "$fence_phase" = CUTOVER_POSSIBLE ] &&
    [ "$fence_epoch" -gt 0 ] &&
    [ "$(jq -er '.current.predecessorDisposition | strings' \
      <<<"$fence_state")" = "$admission_disposition" ] ||
    fail "GUARD_STATE_LOST"
  [ "$(jq -er '.current.containerId // ""' <<<"$fence_state")" = "" ] ||
    fail "GUARD_STATE_LOST"
  echo "schema_guard=cutover-possible"
  run_owned_child CUTOVER_POSSIBLE timeout --kill-after=5s 240s bash -c '
    set -euo pipefail
    source "$1"
    runtime_compose "$2" "$3" "${@:4}"
  ' _ "$runtime_helper" "$root" "$compose_script" \
    up --no-start --no-deps --no-build --pull never \
    --force-recreate backend >/dev/null
  ids=$(compose ps -aq backend) || fail "RECOVERY_REQUIRED"
  mapfile -t candidate_ids <<<"$ids"
  id_count=0
  candidate_container=
  for candidate_id in "${candidate_ids[@]}"; do
    if [ -n "$candidate_id" ]; then
      candidate_container=$candidate_id
      id_count=$((id_count + 1))
    fi
  done
  [ "$id_count" -eq 1 ] &&
    [[ "$candidate_container" =~ ^[a-f0-9]{12,64}$ ]] ||
    fail "RECOVERY_REQUIRED"
  candidate_json=$(docker_container_inspect "$candidate_container") ||
    fail "RECOVERY_REQUIRED"
  candidate_image=$(docker_container_inspect "$candidate_container" \
    --format '{{.Image}}') || fail "RECOVERY_REQUIRED"
  running=$(docker_container_inspect "$candidate_container" \
    --format '{{.State.Running}}') || fail "RECOVERY_REQUIRED"
  target_hash=$(docker_container_inspect "$candidate_container" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') ||
    fail "RECOVERY_REQUIRED"
  [ "$candidate_image" = "$target_id" ] && [ "$running" = false ] &&
    [[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] ||
    fail "RECOVERY_REQUIRED"
  [ "$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' \
    <<<"$candidate_json")" = meet-production ] &&
    [ "$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // ""' \
      <<<"$candidate_json")" = backend ] ||
    fail "RECOVERY_REQUIRED"
  timeout 15s docker update --restart=no "$candidate_container" >/dev/null ||
    fail "RECOVERY_REQUIRED"
  restart=$(docker_container_inspect "$candidate_container" \
    --format '{{.HostConfig.RestartPolicy.Name}}') || fail "RECOVERY_REQUIRED"
  [ "$restart" = no ] || fail "RECOVERY_REQUIRED"
  timepad_advance VERIFYING CANDIDATE_IDENTITY_PERSISTED \
    "$candidate_container" "$target_hash"
  run_owned_child VERIFYING timeout --kill-after=5s 30s docker start "$candidate_container" \
    >/dev/null || fail "RECOVERY_REQUIRED"
  deadline=$(recovery_health_deadline 180) || fail "RECOVERY_REQUIRED"
  while recovery_health_window_open "$deadline"; do
    recovery_deadline_check
    status=$(docker_container_inspect "$candidate_container" \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}') ||
      fail "RECOVERY_REQUIRED"
    case "$status" in
      healthy) return 0 ;;
      starting) sleep 2 ;;
      *) fail "RECOVERY_REQUIRED" ;;
    esac
  done
  fail "RECOVERY_REQUIRED"
}

mutation_started=false
credential_prepared=false
rollback_complete=false
updater_started=false
updater_completed=false
cleanup_inspect=
unsafe_cutover_latch=false
prepared_timepad=false
timepad_admitted=false
admission_disposition=unknown
candidate_container=
failure_signal=
failure_dispatch_active=false
timepad_cleanup_mode=false
dispatch_failure() {
  [ "$failure_dispatch_active" = false ] || return 1
  failure_dispatch_active=true
  recovery_budget_arm || return 1
  local work_available=true
  if ! recovery_work_check; then
    work_available=false
    timepad_cleanup_mode=true
  fi
  if [ -n "$failure_signal" ]; then
    echo "test VPS deployment interrupted by $failure_signal" >&2
  fi
  if [ "$unsafe_cutover_latch" = true ]; then
    local state_json phase disposition owned_container owned_inspect
    state_json=$(timeout 15s python3 "$timepad_helper" read-state \
      --root "$state_root" --deploy-lock-fd 9 2>/dev/null) || {
        # The local ID is populated only after Compose returned one exact
        # stopped candidate and its project/service/image/config were checked.
        # If durable state is unreadable, never infer ownership from Compose's
        # current selection; quiesce only that already-proved candidate.
        if [[ "$candidate_container" =~ ^[a-f0-9]{12,64}$ ]]; then
          owned_inspect=$(docker_container_inspect "$candidate_container" \
            2>/dev/null) || owned_inspect=
          if [ -n "$owned_inspect" ] &&
            [ "$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' \
              <<<"$owned_inspect" 2>/dev/null)" = meet-production ] &&
            [ "$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // ""' \
              <<<"$owned_inspect" 2>/dev/null)" = backend ] &&
            [ "$(jq -r '.[0].Image // ""' <<<"$owned_inspect" 2>/dev/null)" = "$target_id" ] &&
            [ "$(jq -r '.[0].Config.Labels["com.docker.compose.config-hash"] // ""' \
              <<<"$owned_inspect" 2>/dev/null)" = "$target_hash" ]; then
            timeout 15s docker update --restart=no "$candidate_container" \
              >/dev/null 2>&1 || :
            timeout 30s docker stop --time 10 "$candidate_container" \
              >/dev/null 2>&1 || :
          fi
        fi
        echo "test VPS deployment failed: GUARD_STATE_LOST" >&2
        return 1
      }
    phase=$(jq -er '.current.phase | strings' <<<"$state_json") || return 1
    disposition=$(jq -er '.current.predecessorDisposition // ""' \
      <<<"$state_json") || return 1
    case "$phase" in COMMITTED|ROLLED_BACK) return 0 ;; esac
    if [[ "$phase" = CUTOVER_POSSIBLE || "$phase" = VERIFYING ]] &&
      [ "$disposition" = post-barrier-compatible ] &&
      [ "$rollback_complete" = false ] && [ "$work_available" = true ]; then
      rollback || return 1
      return 0
    fi
    if [[ "$phase" = CUTOVER_POSSIBLE || "$phase" = VERIFYING ]] &&
      [ "$disposition" = post-barrier-compatible ] &&
      [ "$work_available" = false ]; then
      timepad_advance RECOVERY_REQUIRED WORK_BUDGET_EXHAUSTED || :
    fi
    owned_container=$(jq -er '.current.containerId // ""' \
      <<<"$state_json") || owned_container=
    if [ -n "$owned_container" ] && [ -n "$candidate_container" ] &&
      [ "$owned_container" != "$candidate_container" ]; then
      echo "test VPS deployment failed: GUARD_STATE_LOST" >&2
      return 1
    fi
    [ -n "$owned_container" ] || owned_container=$candidate_container
    if [[ "$owned_container" =~ ^[a-f0-9]{12,64}$ ]]; then
      owned_inspect=$(docker_container_inspect "$owned_container" 2>/dev/null) ||
        owned_inspect=
      if [ -n "$owned_inspect" ] &&
        [ "$(jq -r '.[0].Config.Labels["com.docker.compose.project"] // ""' \
          <<<"$owned_inspect" 2>/dev/null)" = meet-production ] &&
        [ "$(jq -r '.[0].Config.Labels["com.docker.compose.service"] // ""' \
          <<<"$owned_inspect" 2>/dev/null)" = backend ] &&
        [ "$(jq -r '.[0].Image // ""' <<<"$owned_inspect" 2>/dev/null)" = "$target_id" ]; then
        timeout 15s docker update --restart=no "$owned_container" >/dev/null 2>&1 || :
        timeout 30s docker stop --time 10 "$owned_container" >/dev/null 2>&1 || :
      fi
    fi
    if [ "$phase" != COMMITTED ] && [ "$phase" != ROLLED_BACK ]; then
      timepad_advance RECOVERY_REQUIRED CUTOVER_RECOVERY_REQUIRED || :
    fi
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  fi
  if [ "$rollback_complete" = false ]; then
    if [ "$mutation_started" = true ]; then
      if [ "$work_available" = false ]; then
        [ "$prepared_timepad" = false ] ||
          timepad_advance RECOVERY_REQUIRED WORK_BUDGET_EXHAUSTED || :
        echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
        return 1
      fi
      rollback || return 1
    elif [ "$credential_prepared" = true ]; then
      local rollback_receipt receipt_digest
      if [ "$prepared_timepad" = true ]; then
        [ "$work_available" = true ] || {
          timepad_advance RECOVERY_REQUIRED WORK_BUDGET_EXHAUSTED || :
          return 1
        }
        timepad_claim_rollback
      fi
      if verify_predecessor_for_cleanup; then
        rollback_receipt=$(provider_finish rolled-back "$cleanup_inspect") ||
          return 1
        if [ "$prepared_timepad" = true ]; then
          receipt_digest=$(printf '%s' "$rollback_receipt" |
            sha256sum | awk '{print $1}')
          timepad_advance ROLLED_BACK ROLLBACK_VERIFIED "" "" "$receipt_digest"
          echo "schema_guard=rolled-back"
        fi
      else
        return 1
      fi
    elif [ "$prepared_timepad" = true ]; then
      local receipt_digest current_container current_inspect current_image
      [ "$work_available" = true ] || {
        timepad_advance RECOVERY_REQUIRED WORK_BUDGET_EXHAUSTED || :
        return 1
      }
      current_container=$(compose ps -q backend 2>/dev/null) || return 1
      [ "$current_container" = "$previous_container" ] || return 1
      current_inspect=$(docker_container_inspect "$current_container" 2>/dev/null) ||
        return 1
      current_image=$(docker_container_inspect "$current_container" \
        --format '{{.Image}}') || return 1
      [ "$current_image" = "$previous_id" ] || return 1
      runtime_invariants_bounded "$previous_id" "$previous_revision" \
        "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 || return 1
      runtime_environment_bounded >/dev/null 2>&1 || return 1
      (verify_public_contract "$public_url" >/dev/null 2>&1) || return 1
      timepad_claim_rollback
      receipt_digest=$(printf '%s\n%s\n%s' PRE_BARRIER_NO_MUTATION \
        "$previous_container" "$previous_runtime_hash" |
        sha256sum | awk '{print $1}')
      timepad_advance ROLLED_BACK PRE_BARRIER_NO_MUTATION "" "" "$receipt_digest"
      echo "schema_guard=rolled-back"
    fi
  fi
  return 0
}
on_signal() {
  failure_signal=$1
  if [ "${supervisor_enabled:-false}" = true ]; then
    supervisor_cancel_exit 143 "$failure_signal"
  fi
  trap '' TERM INT HUP
  exit 143
}
on_exit() {
  local status=$?
  if [ "${supervisor_enabled:-false}" = true ]; then
    supervisor_cancel_exit "$status"
  fi
  trap - EXIT
  trap '' TERM INT HUP
  if [ -n "$owned_child_pid" ]; then
    complete_owned_child true || {
      echo "test VPS deployment failed: OWNED_CHILD_QUIESCENCE_UNCONFIRMED" >&2
      exit 1
    }
  fi
  if [ "$status" -ne 0 ]; then
    dispatch_failure || status=1
  fi
  exit "$status"
}
trap on_exit EXIT
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap 'on_signal HUP' HUP

target_id=$(docker_image_inspect "$image" --format '{{.Id}}') ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$revision" ] ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$version" ] ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" \
  --format '{{index .Config.Labels "org.opencontainers.image.source"}}')" = \
  "https://github.com/NickolayMamonov/meet-backend-v3" ] ||
  fail "PROVIDER_STATE_INVALID"
[ "$(docker_image_inspect "$image" --format '{{.Config.User}}')" = 10001:10001 ] ||
  fail "PROVIDER_STATE_INVALID"
if [ "$mode" = rollback-drill ] && [ "$target_id" = "$previous_id" ]; then
  fail "rollback drill requires a target image distinct from the predecessor"
fi
target_image_inspect=$(docker_image_inspect "$image" 2>/dev/null) ||
  fail "PROVIDER_STATE_INVALID"
printf '%s' "$target_image_inspect" |
  timeout 30s python3 "$provider_helper" check-image >/dev/null ||
  fail "PROVIDER_STATE_INVALID"
if [ "$rollout_domain" = initial-domain ]; then
  target_timepad_binding=$(timepad_binding_for_image "$image" "$target_id" \
    "$revision" "$version" initial) ||
    fail "TIMEPAD_ADMISSION_REFUSED"
  predecessor_timepad_binding=$(timepad_binding_for_image "$previous_image" \
    "$previous_id" "$previous_revision" "$previous_version" initial) ||
    fail "TIMEPAD_ADMISSION_REFUSED"
  timepad_transition_id=
else
  target_timepad_binding=$(timepad_binding_for_image "$image" "$target_id" \
    "$revision" "$version" transition) ||
    fail "TIMEPAD_ADMISSION_REFUSED"
  predecessor_timepad_binding=$(timepad_binding_for_image "$previous_image" \
    "$previous_id" "$previous_revision" "$previous_version" any) ||
    fail "TIMEPAD_ADMISSION_REFUSED"
  timepad_transition_id=$(jq -er \
    --arg target "$(jq -er '.id' <<<"$target_timepad_binding")" \
    '[.transitions[]? | select(.targetId == $target)] |
     if length == 1 then .[0].id else error("transition is not unique") end' \
    "$timepad_contract") || fail "TIMEPAD_ADMISSION_REFUSED"
  [ "$initial_proof_id" = "$timepad_transition_id" ] ||
    fail "TIMEPAD_ADMISSION_REFUSED"
fi
prepared_timepad=false
timepad_prepare_transition "$target_timepad_binding" \
  "$predecessor_timepad_binding" "$timepad_transition_id"
echo "schema_guard=$admission_disposition"
run_safety_hook predecessor "$previous_image" "$previous_id" \
  "$previous_revision" "$previous_version" "$previous_runtime_hash"

if [ "$provider_enabled" = true ]; then
  cat >"$state/target-runtime.override.yml" <<'YAML'
services:
  backend:
    healthcheck:
      test:
        - CMD
        - curl
        - --fail
        - --silent
        - --show-error
        - http://127.0.0.1:8080/meetings
    volumes:
      - type: bind
        source: /var/lib/meet-production/credentials/firebase-service-account.json
        target: /run/secrets/meet-firebase-service-account.json
        read_only: true
        bind:
          create_host_path: false
YAML
else
  cat >"$state/target-runtime.override.yml" <<'YAML'
services:
  backend:
    healthcheck:
      test:
        - CMD
        - curl
        - --fail
        - --silent
        - --show-error
        - http://127.0.0.1:8080/meetings
YAML
fi
chmod 600 "$state/target-runtime.override.yml"

target_config=$(
  env -i PATH="$PATH" HOME=/root COMPOSE_PROJECT_NAME=meet-production \
    BACKEND_IMAGE="$image" BACKEND_VERSION="$version" BACKEND_REVISION="$revision" \
    timeout 30s docker compose --project-directory "$root" \
    --env-file "$state/config.env.production" \
    -f "$state/config.base-compose.yml" -f "$state/target-runtime.override.yml" \
    config --format json 2>/dev/null
) || fail "PROVIDER_STATE_INVALID"
printf '%s\n%s\n%s\n' "$previous_inspect" "$target_image_inspect" "$target_config" |
  jq -s -e '
    def envmap:
      if type == "array" then
        reduce .[] as $entry ({};
          if ($entry | type) != "string" or ($entry | contains("=") | not)
          then error("invalid environment")
          else ($entry | index("=")) as $i |
            ($entry[0:$i]) as $key |
            if has($key) then error("duplicate environment") else
              . + {($key): $entry[($i + 1):]}
            end
          end)
      elif type == "object" then
        reduce to_entries[] as $entry ({};
          if ($entry.value | type) != "string"
          then error("unresolved environment")
          else . + {($entry.key):$entry.value}
          end)
      else {}
      end;
    def effective($imageEnv; $targetEnv):
      ($imageEnv | envmap) + ($targetEnv | envmap);
    def tuple($env):
      {
        APP_PUSH_PROVIDER_ENABLED: ($env.APP_PUSH_PROVIDER_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DISCOVERY_ENABLED: ($env.APP_PUSH_DISCOVERY_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DISPATCH_ENABLED: ($env.APP_PUSH_DISPATCH_ENABLED // "false" | ascii_downcase),
        APP_PUSH_DIAGNOSTIC_ENABLED: ($env.APP_PUSH_DIAGNOSTIC_ENABLED // "false" | ascii_downcase),
        APP_PUSH_MAINTENANCE_ENABLED: ($env.APP_PUSH_MAINTENANCE_ENABLED // "false" | ascii_downcase),
        APP_PUSH_PROJECT_ID: ($env.APP_PUSH_PROJECT_ID // "meeting-1d258"),
        APP_PUSH_CREDENTIALS_FILE: ($env.APP_PUSH_CREDENTIALS_FILE // "")
      };
    (.[0][0].Config.Env | envmap) as $previous |
    (.[1][0].Config.Env | envmap) as $image |
    (.[2].services.backend.environment // {}) as $target |
    (effective($image; $target) | tuple(.)) == (tuple($previous)) and
    (tuple($previous).APP_PUSH_PROVIDER_ENABLED == "true" or
      tuple($previous).APP_PUSH_PROVIDER_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DISCOVERY_ENABLED == "true" or
      tuple($previous).APP_PUSH_DISCOVERY_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DISPATCH_ENABLED == "true" or
      tuple($previous).APP_PUSH_DISPATCH_ENABLED == "false") and
    (tuple($previous).APP_PUSH_DIAGNOSTIC_ENABLED == "true" or
      tuple($previous).APP_PUSH_DIAGNOSTIC_ENABLED == "false") and
    (tuple($previous).APP_PUSH_MAINTENANCE_ENABLED == "true" or
      tuple($previous).APP_PUSH_MAINTENANCE_ENABLED == "false")
  ' >/dev/null 2>&1 || fail "PROVIDER_STATE_INVALID"

make_environment_candidate "$state/config.env.production" \
  "$state/config.env.target" "$image" "$revision" "$version" ||
  fail "PROVIDER_STATE_INVALID"
make_environment_candidate "$state/config.env.production" \
  "$state/config.env.previous" "$previous_image" "$previous_revision" \
  "$previous_version" || fail "PROVIDER_STATE_INVALID"

printf '%s' "$previous_inspect" |
  timeout 30s python3 "$provider_helper" prepare \
    --run-key "$run_key" --state-root "$state_root" \
    --deploy-lock-fd 9 >/dev/null ||
  fail "CREDENTIAL_INVALID"
durable_disposition=$(timeout 5s jq -er \
  --arg run_key "$run_key" --argjson enabled "$provider_enabled" '
    select(
      type == "object" and
      .schemaVersion == 1 and
      .runKey == $run_key and
      .phase == "preparing" and
      .providerEnabled == $enabled
    ) |
    .durableDisposition |
    select(. == "none" or . == "created" or . == "reused")
  ' \
  "$provider_pointer") || fail "RECOVERY_REQUIRED"
if [ "$provider_enabled" = true ]; then
  case "$durable_disposition" in created|reused) ;; *) fail "RECOVERY_REQUIRED" ;; esac
else
  [ "$durable_disposition" = none ] || fail "RECOVERY_REQUIRED"
fi
write_provider_marker prepared "$durable_disposition"
credential_prepared=true
timepad_publish_prepared_transition

restore_previous_active_files() {
  restore_active_file "$active_compose" compose || fail "RECOVERY_REQUIRED"
  restore_active_file "$active_runtime" runtime || fail "RECOVERY_REQUIRED"
}

rollback() {
  local rollback_receipt receipt_digest
  recovery_work_check || fail "RECOVERY_REQUIRED"
  if [ "$prepared_timepad" = true ]; then
    timepad_claim_rollback
  fi
  if [ "$updater_completed" = true ]; then
    validate_configuration_boundary "$state/config.env.target"
  elif [ "$updater_started" = false ]; then
    validate_configuration_boundary "$state/config.env.production"
  fi
  write_provider_marker rolling-back "${durable_disposition:-none}"
  restore_previous_active_files
  if [ "$updater_completed" = true ]; then
    validate_configuration_boundary "$state/config.env.target"
  fi
  updater_started=true
  PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
    timeout 60s "$update_script" "$previous_image" "$previous_revision" "$previous_version" \
    >/dev/null 2>&1 || fail "RECOVERY_REQUIRED"
  cmp -s "$root/.env.production" "$state/config.env.previous" ||
    fail "RECOVERY_REQUIRED"
  printf '%s\n' "$(configuration_file_identity "$root/.env.production")" \
    >"$state/config.env.previous.identity"
  chmod 600 "$state/config.env.previous.identity"
  validate_configuration_boundary "$state/config.env.previous"
  compose_up -d --no-deps --no-build --pull never --force-recreate \
    --wait --wait-timeout 180 backend >/dev/null
  recovery_deadline_check
  restored_container=$(compose ps -q backend)
  restored_inspect=$(docker_container_inspect "$restored_container" 2>/dev/null) ||
    fail "RECOVERY_REQUIRED"
  restored_hash=$(docker_container_inspect "$restored_container" \
    --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
  [ "$restored_hash" = "$previous_runtime_hash" ] ||
    fail "rollback did not restore the exact predecessor Compose runtime"
  runtime_invariants_bounded "$previous_id" "$previous_revision" \
    "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 ||
    fail "RECOVERY_REQUIRED"
  printf '[%s,%s]' "$previous_inspect" "$restored_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --state-root "$state_root" --phase rollback \
      --deploy-lock-fd 9 >/dev/null ||
    fail "RECOVERY_REQUIRED"
  verify_public_contract "$public_url"
  recovery_deadline_check
  run_safety_hook rollback "$previous_image" "$previous_id" \
    "$previous_revision" "$previous_version" "$previous_runtime_hash"
  final_restored_container=$(compose ps -q backend)
  [ "$final_restored_container" = "$restored_container" ] ||
    fail "RECOVERY_REQUIRED"
  final_restored_inspect=$(docker_container_inspect "$final_restored_container" \
    2>/dev/null) || fail "RECOVERY_REQUIRED"
  runtime_invariants_bounded "$previous_id" "$previous_revision" \
    "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 ||
    fail "RECOVERY_REQUIRED"
  runtime_environment_bounded >/dev/null 2>&1 || fail "RECOVERY_REQUIRED"
  (verify_public_contract "$public_url") || fail "RECOVERY_REQUIRED"
  printf '[%s,%s]' "$previous_inspect" "$final_restored_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --state-root "$state_root" --phase rollback \
      --deploy-lock-fd 9 >/dev/null ||
    fail "RECOVERY_REQUIRED"
  rollback_receipt=$(provider_finish rolled-back "$final_restored_inspect")
  if [ "$prepared_timepad" = true ]; then
    receipt_digest=$(printf '%s' "$rollback_receipt" | sha256sum | awk '{print $1}')
    timepad_advance ROLLED_BACK ROLLBACK_VERIFIED "" "" "$receipt_digest"
    echo "schema_guard=rolled-back"
  fi
  rollback_complete=true
  echo "rollback=completed previous_image_id=$previous_id"
  echo "operation_outcome=rolled-back"
}

verify_predecessor_before_writers() {
  local current_container current_inspect
  current_container=$(compose ps -q backend) ||
    fail "PROVIDER_STATE_INVALID"
  [ -n "$current_container" ] || fail "PROVIDER_STATE_INVALID"
  current_inspect=$(docker_container_inspect "$current_container" 2>/dev/null) ||
    fail "PROVIDER_STATE_INVALID"
  printf '[%s,%s]' "$previous_inspect" "$current_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --state-root "$state_root" --phase predecessor \
      --deploy-lock-fd 9 >/dev/null ||
    fail "PROVIDER_STATE_INVALID"
}

verify_predecessor_for_cleanup() {
  local current_container current_inspect
  current_container=$(compose ps -q backend 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  [ -n "$current_container" ] || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  current_inspect=$(docker_container_inspect "$current_container" 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  cleanup_inspect=$current_inspect
  runtime_invariants_bounded "$previous_id" "$previous_revision" \
    "$previous_version" "$previous_runtime_hash" >/dev/null 2>&1 || {
      echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
      return 1
    }
  runtime_environment_bounded >/dev/null 2>&1 || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  if ! (verify_public_contract "$public_url" >/dev/null 2>&1); then
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  fi
  local final_container final_inspect
  final_container=$(compose ps -q backend 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  [ "$final_container" = "$current_container" ] || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  final_inspect=$(docker_container_inspect "$final_container" 2>/dev/null) || {
    echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
    return 1
  }
  cleanup_inspect=$final_inspect
  printf '[%s,%s]' "$previous_inspect" "$final_inspect" |
    timeout 30s python3 "$provider_helper" verify \
      --run-key "$run_key" --state-root "$state_root" --phase predecessor \
      --deploy-lock-fd 9 \
      >/dev/null || {
        echo "test VPS deployment failed: RECOVERY_REQUIRED" >&2
        return 1
      }
}

validate_active_files_before_writers
verify_predecessor_before_writers
validate_configuration_boundary "$state/config.env.production"
write_provider_marker applying "$durable_disposition"
mutation_started=true
validate_configuration_boundary "$state/config.env.production"
timeout 30s install -m 600 "$state/config.base-compose.yml" "$active_compose" ||
  fail "PROVIDER_STATE_INVALID"
record_candidate_active_file "$active_compose" compose
validate_configuration_boundary "$state/config.env.production"
timeout 30s install -m 600 "$state/target-runtime.override.yml" "$active_runtime" ||
  fail "PROVIDER_STATE_INVALID"
record_candidate_active_file "$active_runtime" runtime
validate_configuration_boundary "$state/config.env.production"
updater_started=true
PRODUCTION_ROOT=$root PRODUCTION_SCRIPTS_DIR=$script_dir \
  timeout 60s "$update_script" "$image" "$revision" "$version" >/dev/null 2>&1 ||
  fail "PROVIDER_STATE_INVALID"
cmp -s "$root/.env.production" "$state/config.env.target" ||
  fail "PROVIDER_STATE_INVALID"
printf '%s\n' "$(configuration_file_identity "$root/.env.production")" \
  >"$state/config.env.target.identity"
chmod 600 "$state/config.env.target.identity"
validate_configuration_boundary "$state/config.env.target"
updater_completed=true
if [ "$prepared_timepad" = true ]; then
  guarded_candidate_start
else
  compose_up -d --no-deps --no-build --pull never --force-recreate \
    --wait --wait-timeout 180 backend >/dev/null
  candidate_container=$(compose ps -q backend)
fi
candidate_inspect=$(docker_container_inspect "$candidate_container" 2>/dev/null) ||
  fail "RECOVERY_REQUIRED"
target_hash=$(docker_container_inspect "$candidate_container" \
  --format '{{index .Config.Labels "com.docker.compose.config-hash"}}') ||
  fail "RECOVERY_REQUIRED"
[[ "$target_hash" =~ ^[0-9a-f]{64}$ ]] || fail "candidate runtime hash unavailable"
write_provider_marker verifying "$durable_disposition"
printf '[%s,%s]' "$previous_inspect" "$candidate_inspect" |
  timeout 30s python3 "$provider_helper" verify \
    --run-key "$run_key" --state-root "$state_root" --phase candidate \
    --deploy-lock-fd 9 >/dev/null ||
  fail "PROVIDER_STATE_INVALID"
if [ "$prepared_timepad" = true ]; then
  runtime_guarded_invariants_bounded "$target_id" "$revision" "$version" \
    "$target_hash" "$candidate_container" \
    "$(timeout 15s python3 "$timepad_helper" read-state --root "$state_root" \
      --deploy-lock-fd 9 | jq -er '.current.operationEpoch')" \
    >/dev/null 2>&1 || fail "PROVIDER_STATE_INVALID"
else
  runtime_invariants_bounded "$target_id" "$revision" "$version" "$target_hash" \
    >/dev/null 2>&1 || fail "PROVIDER_STATE_INVALID"
fi
verify_public_contract "$public_url"
run_safety_hook candidate "$image" "$target_id" \
  "$revision" "$version" "$target_hash"
echo "candidate=ready image_id=$target_id version=$version revision=$revision"

if [ "$mode" = rollback-drill ]; then
  echo "rollback_drill=triggered"
  echo "operation_outcome=rollback-drill-triggered"
  exit 86
fi

run_safety_hook final "$image" "$target_id" \
  "$revision" "$version" "$target_hash"
validate_configuration_boundary "$state/config.env.target"
if [ "$prepared_timepad" = true ]; then
  commit_witness_digest=$(timepad_commit_witness)
  finalization_result=$(printf '%s' "$candidate_inspect" |
    timeout 30s python3 "$provider_helper" prepare-finalization \
      --run-key "$run_key" --state-root "$state_root" \
      --state-kind "$state_suffix" --deploy-lock-fd 9) ||
    fail "RECOVERY_REQUIRED"
  provider_finalization_digest=$(jq -er \
    '.providerFinalizationDigest | strings | select(test("^[0-9a-f]{64}$"))' \
    <<<"$finalization_result") || fail "RECOVERY_REQUIRED"
  timepad_advance COMMITTING "" "$candidate_container" "$target_hash" "" \
    "$commit_witness_digest" provider-cleanup "$provider_finalization_digest"
fi
commit_receipt=$(provider_finish committed "$candidate_inspect")
if [ "$prepared_timepad" = true ]; then
  timepad_advance COMMITTING "" "" "" "" "" terminal-policy-intent
  timeout 15s docker update --restart=unless-stopped "$candidate_container" \
    >/dev/null || fail "RECOVERY_REQUIRED"
  [ "$(docker_container_inspect "$candidate_container" \
    --format '{{.HostConfig.RestartPolicy.Name}}')" = unless-stopped ] ||
    fail "RECOVERY_REQUIRED"
  [ "$(compose ps -q backend)" = "$candidate_container" ] ||
    fail "RECOVERY_REQUIRED"
  runtime_invariants_bounded "$target_id" "$revision" "$version" "$target_hash" \
    >/dev/null 2>&1 || fail "RECOVERY_REQUIRED"
  runtime_environment_bounded >/dev/null 2>&1 || fail "RECOVERY_REQUIRED"
  verify_public_contract "$public_url"
  receipt_digest=$(printf '%s' "$commit_receipt" | sha256sum | awk '{print $1}')
  timepad_advance COMMITTED "" "" "" "$receipt_digest" "" policy-restored
  echo "schema_guard=committed"
fi
mutation_started=false
rollback_complete=true
echo "deployment=completed image_id=$target_id version=$version revision=$revision"
echo "operation_outcome=deployment-completed"

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [ "${1:-}" = --timepad-private-worker ]; then
    [ "$#" -ge 3 ] || usage
    worker_mode=$2
    case "$worker_mode" in
      controller-worker|rollback-worker|fail-closed-worker|retention-worker) ;;
      *) fail "PRIVATE_WORKER_REQUIRED" ;;
    esac
    shift 2
    private_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
    private_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    export TIMEPAD_WORKER_MODE=$worker_mode
    timeout 10s python3 "$private_script_dir/test_vps_timepad_supervisor.py" \
        client --root "$private_root" hello >/dev/null ||
      fail "PRIVATE_WORKER_REQUIRED"
    case "$worker_mode" in
      controller-worker|rollback-worker|fail-closed-worker) ;;
      *) fail "PRIVATE_WORKER_MODE_UNAVAILABLE" ;;
    esac
    provider_release_main "$@"
  else
    supervisor_root=${TEST_VPS_STATE_ROOT:-/var/lib/meet-test-vps-deploy}
    [[ "$supervisor_root" = /* ]] || fail "DEPLOY_LOCK_INVALID"
    if [ ! -e "$supervisor_root" ] && [ ! -L "$supervisor_root" ]; then
      timeout 10s install -d -m 700 "$supervisor_root" ||
        fail "DEPLOY_LOCK_INVALID"
    fi
    [ -d "$supervisor_root" ] && [ ! -L "$supervisor_root" ] ||
      fail "DEPLOY_LOCK_INVALID"
    supervisor_operation=deploy
    supervisor_args=("$@")
    for ((index = 0; index < ${#supervisor_args[@]}; index++)); do
      case "${supervisor_args[index]}" in
        --operation)
          ((index + 1 < ${#supervisor_args[@]})) || usage
          case "${supervisor_args[index + 1]}" in
            deploy|bootstrap-guard) supervisor_operation=deploy ;;
            forward-recover) supervisor_operation=forward-recover ;;
            *) usage ;;
          esac
          ((index += 1))
          ;;
        *) ;;
      esac
    done
    supervisor_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    exec python3 "$supervisor_script_dir/test_vps_timepad_supervisor.py" \
      relay --root "$supervisor_root" --operation "$supervisor_operation" -- "${supervisor_args[@]}"
  fi
fi
