#!/usr/bin/env bash
set -euo pipefail
fail(){ echo "beta recovery capture test failed: $*" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
capture=$root/scripts/run-beta-recovery-capture.sh
backup=$root/scripts/backup-production.sh
media=$root/scripts/beta-recovery-media-proof.sh
for script in "$capture" "$backup" "$media"; do [ -x "$script" ] || fail "not executable: $script"; bash -n "$script"; done
grep -Fq '.deploy.lock' "$capture"; grep -Fq 'reconcile_states' "$capture"; grep -Fq 'capture-database-proof.json' "$capture"
grep -Fq 'export PRODUCTION_ROOT="$root"' "$capture"
grep -Fq 'export PRODUCTION_ROOT="$root"' "$root/scripts/probe-test-vps-recovery-runtime.sh"
grep -Fq 'pg_database_size(current_database())' "$backup"; grep -Fq 'validate_upload_archive' "$backup"; grep -Fq 'tar --list --gzip --verbose' "$backup"
grep -Fq 'jq -cS' "$backup"; grep -Fq 'capacity_ok' "$backup"; grep -Fq -- '--reference-list' "$backup"
grep -Fq 'decimal_add' "$media"; grep -Fq 'ln -- "$candidate" "$output"' "$media"
command -v jq >/dev/null 2>&1 || fail "jq is required"
fixture=$(mktemp -d); references=$(mktemp -d)
trap '[ "${KEEP_BETA_RECOVERY_FIXTURE:-0}" = 1 ] || rm -r -- "$fixture" "$references"' EXIT HUP INT TERM
mkdir -p "$fixture/avatars" "$fixture/meetings" "$fixture/communities"
printf avatar >"$fixture/avatars/a.bin"; printf meeting >"$fixture/meetings/m.bin"; printf community >"$fixture/communities/c.bin"
media_output=$references/proof.json; bash "$media" --root "$fixture" --output "$media_output"
jq -e '.files==3 and .bytes==22 and (.canonicalDigest|test("^[0-9a-f]{64}$"))' "$media_output" >/dev/null
if bash "$media" --root "$fixture" --output "$media_output"; then fail "existing output was overwritten"; fi
printf '\n' >"$references/blank-reference"
bash "$media" --root "$fixture" --reference-list "$references/blank-reference" \
  --output "$references/blank-reference-proof.json"
jq -e '.referencesTotal==1 and .referencesResolved==false' \
  "$references/blank-reference-proof.json" >/dev/null
printf 'avatars/a.bin\n' >"$references/valid-reference"
bash "$media" --root "$fixture" --reference-list "$references/valid-reference" \
  --output "$references/valid-reference-proof.json"
jq -e '.referencesTotal==1 and .referencesResolved==true' \
  "$references/valid-reference-proof.json" >/dev/null
printf 'avatars/missing.bin\n' >"$references/missing-reference"
bash "$media" --root "$fixture" --reference-list "$references/missing-reference" \
  --output "$references/missing-reference-proof.json"
jq -e '.referencesTotal==1 and .referencesResolved==false' \
  "$references/missing-reference-proof.json" >/dev/null
printf '../escape\n' >"$references/unsafe-reference"
bash "$media" --root "$fixture" --reference-list "$references/unsafe-reference" \
  --output "$references/unsafe-reference-proof.json"
jq -e '.referencesTotal==1 and .referencesResolved==false' \
  "$references/unsafe-reference-proof.json" >/dev/null
if ln -s "$fixture/avatars/a.bin" "$fixture/meetings/link" && [ -L "$fixture/meetings/link" ]; then
  if bash "$media" --root "$fixture" --output "$references/unsafe.json"; then fail "symlink was accepted"; fi
else
  rm -f -- "$fixture/meetings/link"
fi
backup_fixture="$fixture/backup"
mkdir -p "$backup_fixture/bin" "$backup_fixture/root" "$backup_fixture/uploads"/{avatars,meetings,communities} \
  "$backup_fixture/postgres" "$backup_fixture/docker"
printf 'BACKEND_IMAGE=fixture\n' >"$backup_fixture/root/.env.production"
printf avatar >"$backup_fixture/uploads/avatars/a.bin"
printf meeting >"$backup_fixture/uploads/meetings/m.bin"
printf community >"$backup_fixture/uploads/communities/c.bin"
printf unchanged >"$backup_fixture/postgres/data-sentinel"
printf running >"$backup_fixture/postgres/postgres-running"
cat >"$backup_fixture/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) shift ;;
    -m) shift 2 ;;
    -o|-g) shift 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
mkdir -p "${paths[@]}"
EOF
cat >"$backup_fixture/bin/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in -n) exit 0;; *) exit 2;; esac
EOF
cat >"$backup_fixture/bin/chown" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift
[ "$#" -gt 0 ] || exit 2
EOF
cat >"$backup_fixture/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
format=${2:-}; path=${3:-}
case "$format" in
  %u) id -u ;;
  %g) id -g ;;
  %a) [ -d "$path" ] && printf '700\n' || printf '600\n' ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF
cat >"$backup_fixture/bin/production-compose.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
events=${CAPTURE_BACKUP_EVENTS:?}
printf 'compose %s\n' "$1 ${2:-} ${3:-}" >>"$events"
if [ "${1:-}" = ps ] && [ "${2:-}" = -q ]; then
  case "${3:-}" in
    backend) printf 'aaaaaaaaaaaaaaaa\n' ;;
    postgres) printf 'bbbbbbbbbbbbbbbb\n' ;;
    *) exit 2 ;;
  esac
  exit 0
fi
[ "${1:-}" = exec ] && [ "${2:-}" = -T ] && [ "${3:-}" = postgres ] &&
  [ "${4:-}" = sh ] && [ "${5:-}" = -c ] || exit 2
inner=$6; shift 6; zero=${1:-_}; [ "$#" -eq 0 ] || shift
POSTGRES_USER=configured_user POSTGRES_DB=configured_db \
  CAPTURE_CLIENT_LOG="$CAPTURE_CLIENT_LOG" CAPTURE_BACKUP_EVENTS="$events" \
  PATH="$CAPTURE_BACKUP_BIN:$PATH" sh -c "$inner" "$zero" "$@"
EOF
cat >"$backup_fixture/bin/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@"); log=${CAPTURE_CLIENT_LOG:?}; events=${CAPTURE_BACKUP_EVENTS:?}
argv_json=$(printf '%s\0' "${args[@]}" | jq -Rs 'split("\u0000")[:-1]')
[ "${args[0]:-}" = -U ] && [ "${args[1]:-}" = configured_user ] &&
  [ "${args[2]:-}" = -d ] && [ "${args[3]:-}" = configured_db ] ||
  { echo "psql did not receive configured identity" >&2; exit 91; }
if [[ " ${args[*]} " == *"pg_database_size(current_database())"* ]]; then
  consumer=size
  [ "${CAPTURE_FAIL_SIZE:-0}" = 1 ] && status=42 || status=0
  printf '%s\n' "$consumer" >>"$events"
  jq -cn --arg consumer "$consumer" --argjson argv "$argv_json" \
    '{consumer:$consumer,argv:$argv}' >>"$log"
  [ "$status" -eq 0 ] && printf '123456789\n'
  exit "$status"
elif [[ " ${args[*]} " == *" -c "* ]] && [[ " ${args[*]} " == *"regexp_replace"* ]]; then
  consumer=media
  printf '%s\n' "$consumer" >>"$events"
  jq -cn --arg consumer "$consumer" --argjson argv "$argv_json" \
    '{consumer:$consumer,argv:$argv}' >>"$log"
  printf 'avatars/a.bin\nmeetings/m.bin\ncommunities/c.bin\n'
elif [ "${args[${#args[@]}-2]:-}" = -f ] && [ "${args[${#args[@]}-1]:-}" = - ]; then
  consumer=proof
  printf '%s\n' "$consumer" >>"$events"
  jq -cn --arg consumer "$consumer" --argjson argv "$argv_json" \
    '{consumer:$consumer,argv:$argv}' >>"$log"
  printf '{"schema":"meet-backend/closed-beta-database-proof/v1","valid":true}\n'
else
  echo "unexpected psql fixture argv" >&2
  exit 92
fi
EOF
cat >"$backup_fixture/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=("$@"); log=${CAPTURE_CLIENT_LOG:?}; events=${CAPTURE_BACKUP_EVENTS:?}
argv_json=$(printf '%s\0' "${args[@]}" | jq -Rs 'split("\u0000")[:-1]')
[ "${args[1]:-}" = -U ] && [ "${args[2]:-}" = configured_user ] &&
  [ "${args[3]:-}" = -d ] && [ "${args[4]:-}" = configured_db ] ||
  { echo "pg_dump did not receive configured identity" >&2; exit 93; }
printf 'dump\n' >>"$events"
jq -cn --arg consumer dump --argjson argv "$argv_json" \
  '{consumer:$consumer,argv:$argv}' >>"$log"
printf 'fixture-postgres-dump\n'
EOF
cat >"$backup_fixture/bin/age" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
events=${CAPTURE_BACKUP_EVENTS:?}; output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -r) shift 2 ;;
    -o) output=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
[ -n "$output" ] || exit 2
printf 'age\n' >>"$events"
cat >"$output"
EOF
cat >"$backup_fixture/bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'fixture 1000000000 1000 999999000 1%% /fixture\n'
EOF
cat >"$backup_fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
events=${CAPTURE_BACKUP_EVENTS:?}
case "${1:-}" in
  inspect)
    id=${2:-}; format=${4:-}
    [ "$id" = aaaaaaaaaaaaaaaa ] || [ "$id" = bbbbbbbbbbbbbbbb ] || exit 2
    case "$format" in
      *'{{.Id}}'*) printf '%s\n' "$id" ;;
      *'{{.Image}}'*) printf 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      *Health.Status*|*State.Health*) printf 'healthy\n' ;;
      *'{{.State.Running}}'*) printf 'true\n' ;;
      *'{{range .Mounts}}'*) printf 'volume|meet-production_uploads_data\n' ;;
      *) jq -cn --arg id "$id" '[{Id:$id,Image:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",State:{Running:true}}]' ;;
    esac
    ;;
  volume)
    [ "${2:-}" = inspect ] && [ "${3:-}" = --format ] || exit 2
    volume_name=${5:-}
    [ "$volume_name" = meet-production_uploads_data ] ||
      [ "$volume_name" = meet-production_postgres_data ] || exit 2
    if [ "$volume_name" = meet-production_uploads_data ]; then
      printf '%s\n' "$CAPTURE_UPLOAD_ROOT"
    else
      printf '%s\n' "$CAPTURE_POSTGRES_ROOT"
    fi
    ;;
  info) printf '%s\n' "$CAPTURE_DOCKER_ROOT" ;;
  stop)
    target=${4:-}; [ "$target" = aaaaaaaaaaaaaaaa ] || exit 94
    printf 'stop backend\n' >>"$events"
    ;;
  start)
    [ "${2:-}" = aaaaaaaaaaaaaaaa ] || exit 95
    printf 'start backend\n' >>"$events"
    ;;
  run)
    printf 'run archive\n' >>"$events"
    tar -C "$CAPTURE_UPLOAD_ROOT" -czf - .
    ;;
  *) echo "unsupported docker fixture operation: $*" >&2; exit 2 ;;
esac
EOF
cat >"$backup_fixture/bin/probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while [ "$#" -gt 0 ]; do
  [ "$1" = --output ] && output=$2 && shift 2 || shift
done
jq -cnS '{schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
  runtime:{health:"healthy",imageId:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  configHash:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",uploadsMount:"volume"},
  https:{meetingsStatus:"200",meetingsJson:true,actuatorStatus:"404",httpRedirectHttps:true}}' >"$output"
EOF
chmod 700 "$backup_fixture/bin"/*
run_backup_capture_case() {
  local label=$1 fail_size=$2 state_root="$backup_fixture/state-$1" output="$backup_fixture/output-$1"
  local events="$backup_fixture/$label.events" clients="$backup_fixture/$label.clients"
  mkdir -p "$state_root" "$output"
  printf untouched >"$state_root/.deploy.lock"
  : >"$events"; : >"$clients"
  if CAPTURE_FAIL_SIZE="$fail_size" CAPTURE_BACKUP_EVENTS="$events" \
    CAPTURE_CLIENT_LOG="$clients" CAPTURE_BACKUP_BIN="$backup_fixture/bin" \
    CAPTURE_UPLOAD_ROOT="$backup_fixture/uploads" CAPTURE_POSTGRES_ROOT="$backup_fixture/postgres" \
    CAPTURE_DOCKER_ROOT="$backup_fixture/docker" SUDO_UID='' SUDO_GID='' \
    USER=root PGUSER=root PGDATABASE=root PATH="$backup_fixture/bin:$PATH" \
    bash "$capture" --recovery-id "recovery-$label" --root "$backup_fixture/root" \
      --output-dir "$output" \
      --recipient age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m \
      --public-url https://api.whysoezzy.online --state-root "$state_root" \
      --compose-script "$backup_fixture/bin/production-compose.sh" \
      --probe-script "$backup_fixture/bin/probe" --backup-script "$backup"; then
    [ "$fail_size" = 0 ] || fail "injected size failure succeeded"
  else
    [ "$fail_size" = 1 ] || fail "success fixture failed"
  fi
  if [ "$fail_size" = 0 ]; then
    jq -se 'length==4 and ([.[].consumer]|sort)==["dump","media","proof","size"] and
      all(.[]; (.argv|index("-U")) != null and (.argv|index("configured_user")) != null and
      (.argv|index("-d")) != null and (.argv|index("configured_db")) != null)' "$clients" >/dev/null ||
      fail "configured identity was not explicit for every consumer"
    jq -se 'map(select(.consumer=="media")) | length==1 and
      ((.[0].argv|index("ON_ERROR_STOP=1"))!=null)' \
      "$clients" >/dev/null || fail "media ON_ERROR_STOP was lost"
    grep -Fq 'stop backend' "$events" && grep -Fq 'start backend' "$events" ||
      fail "backend was not restarted"
    ! grep -Fq 'root' "$clients" || fail "ambient identity reached a client"
    expected='capture-database-proof.json capture-media-proof.json capture-result.json capture-runtime.json post-capture.json postgres.dump.age uploads.tar.gz.age'
    actual=$(find "$output" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')
    [ "$actual" = "$expected" ] || fail "success publication set differs"
    for file in "$output"/*; do
      [ "$(PATH="$backup_fixture/bin:$PATH" stat -c '%a' "$file")" = 600 ] &&
        [ "$(PATH="$backup_fixture/bin:$PATH" stat -c '%u' "$file")" = "$(id -u)" ] &&
        [ "$(PATH="$backup_fixture/bin:$PATH" stat -c '%g' "$file")" = "$(id -g)" ] ||
        fail "published mode or ownership differs"
    done
    [ ! -e "$state_root/beta-recovery-recovery-$label" ] &&
      [ -f "$state_root/.deploy.lock" ] || fail "successful state cleanup was incomplete"
  else
    [ "$(wc -l <"$clients" | tr -d '[:space:]')" = 1 ] &&
      jq -e '.consumer=="size" and (.argv|index("configured_user"))!=null and
        (.argv|index("configured_db"))!=null' "$clients" >/dev/null ||
      fail "size failure did not use configured identity"
    [ "$(grep -Fc 'stop backend' "$events")" = 1 ] &&
      [ "$(grep -Fc 'start backend' "$events")" = 1 ] || fail "failure restarted wrong backend"
    ! grep -Eq '^(media|proof|dump|age|run archive)$' "$events" ||
      fail "failure continued after size query"
    [ "$(cat "$backup_fixture/postgres/data-sentinel")" = unchanged ] ||
      fail "failure changed PostgreSQL sentinel"
    [ "$(cat "$backup_fixture/postgres/postgres-running")" = running ] ||
      fail "failure changed PostgreSQL state"
    [ -z "$(find "$output" -mindepth 1 -print -quit)" ] || fail "failure published output"
    state="$state_root/beta-recovery-recovery-$label"
    jq -e '.state=="nonterminal" and .phase=="pre_stop" and
      .ownedPaths==["private/capture-runtime.json","private/post-capture.json","private/capture-result.json",
      "private/capture-database-proof.json","private/capture-media-proof.json","private/postgres.dump.age",
      "private/uploads.tar.gz.age","staging"]' "$state/journal.json" >/dev/null ||
      fail "failure journal was not retained at pre_stop"
    [ "$(find "$state/private" -mindepth 1 -maxdepth 1 -type f -printf '%f\n')" = capture-runtime.json ] &&
      [ -z "$(find "$state/staging" -mindepth 1 -print -quit)" ] ||
      fail "failure left private snapshot output"
    [ -f "$state_root/.deploy.lock" ] || fail "deploy lock was removed"
  fi
}
run_backup_capture_case success 0
run_backup_capture_case failure 1
capture_fixture="$fixture/capture"
mkdir -p "$capture_fixture/bin" "$capture_fixture/root"
printf 'BACKEND_IMAGE=fixture\n' >"$capture_fixture/root/.env.production"
cat >"$capture_fixture/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
paths=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d) shift ;;
    -m) shift 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
mkdir -p "${paths[@]}"
EOF
cat >"$capture_fixture/bin/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
EOF
cat >"$capture_fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${CAPTURE_CALLS_FILE:-}" ]; then
  printf 'docker\n' >>"$CAPTURE_CALLS_FILE"
fi
case "${1:-}" in
  info) exit 0 ;;
  inspect)
    id=${2:-}
    if [ "$id" = aaaaaaaaaaaaaaaa ] && [ "${CAPTURE_INSPECT_MODE:-not-found}" != not-found ]; then
      case "$CAPTURE_INSPECT_MODE" in
        daemon) echo 'Error response from daemon: connection refused' >&2 ;;
        permission) echo 'permission denied while trying to connect to Docker daemon socket' >&2 ;;
        timeout) echo 'context deadline exceeded' >&2 ;;
        unknown) echo 'unexpected inspect failure' >&2 ;;
        *) echo 'unexpected inspect mode' >&2 ;;
      esac
      exit 1
    fi
    if [ "$id" = aaaaaaaaaaaaaaaa ]; then
      echo 'Error: No such container: aaaaaaaaaaaaaaaa' >&2
      exit 1
    fi
    case "$*" in
      *State.Running*) printf 'true\n' ;;
      *Health.Status*) printf 'healthy\n' ;;
      *'{{.Image}}'*) printf 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
      *config-hash*) printf 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n' ;;
      *Mounts*) printf 'volume|meet-production_uploads_data\n' ;;
      *) jq -cn '[{Id:"current-container",Image:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",State:{Running:true}}]' ;;
    esac
    ;;
  *) echo "unsupported docker fixture operation: $*" >&2; exit 2 ;;
esac
EOF
cat >"$capture_fixture/bin/compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${CAPTURE_EXPECTED_PRODUCTION_ROOT:-}" ] &&
  [ "${PRODUCTION_ROOT:-}" != "$CAPTURE_EXPECTED_PRODUCTION_ROOT" ]; then
  echo "compose received an unexpected production root" >&2
  exit 1
fi
if [ -n "${CAPTURE_CALLS_FILE:-}" ]; then
  printf 'compose\n' >>"$CAPTURE_CALLS_FILE"
fi
[ "${1:-}" = ps ] && [ "${2:-}" = -q ] && [ "${3:-}" = backend ] && printf 'current-container\n'
EOF
cat >"$capture_fixture/bin/probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${CAPTURE_CALLS_FILE:-}" ]; then
  printf 'probe\n' >>"$CAPTURE_CALLS_FILE"
fi
output=''
while [ "$#" -gt 0 ]; do
  [ "$1" = --output ] && output=$2 && shift 2 || shift
done
jq -cnS '{schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
  runtime:{health:"healthy",imageId:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  configHash:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",uploadsMount:"volume"},
  https:{meetingsStatus:"200",meetingsJson:true,actuatorStatus:"404",httpRedirectHttps:true}}' >"$output"
EOF
cat >"$capture_fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${CAPTURE_CALLS_FILE:-}" ]; then
  printf 'curl\n' >>"$CAPTURE_CALLS_FILE"
fi
output=/dev/null
headers=
write=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -D) headers=$2; shift 2 ;;
    -w) write=$2; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
if [ -n "$headers" ]; then
  printf 'location: https://api.whysoezzy.online/meetings\n' >"$headers"
elif [[ "$url" == */meetings ]]; then
  printf '[]\n' >"$output"
  printf '200\n'
elif [[ "$url" == */actuator ]]; then
  printf '404\n'
fi
EOF
chmod 700 "$capture_fixture/bin/install" "$capture_fixture/bin/flock" \
  "$capture_fixture/bin/docker" "$capture_fixture/bin/compose" "$capture_fixture/bin/probe" \
  "$capture_fixture/bin/curl"
probe_output="$capture_fixture/probe.json"
CAPTURE_CALLS_FILE="$capture_fixture/valid-calls.log" \
  CAPTURE_EXPECTED_PRODUCTION_ROOT="$capture_fixture/root" \
  PATH="$capture_fixture/bin:$PATH" \
  bash "$root/scripts/probe-test-vps-recovery-runtime.sh" \
    --root "$capture_fixture/root" --compose-script "$capture_fixture/bin/compose" \
    --output "$probe_output" --public-url https://api.whysoezzy.online
jq -e '.schema=="meet-backend/test-vps-recovery-runtime/v1" and .healthy==true' \
  "$probe_output" >/dev/null
[ "$(grep -Fc 'compose' "$capture_fixture/valid-calls.log")" -ge 1 ]
[ "$(grep -Fc 'docker' "$capture_fixture/valid-calls.log")" -ge 1 ]
[ "$(grep -Fc 'curl' "$capture_fixture/valid-calls.log")" -ge 1 ]
run_capture_admission_case(){
  local label=$1 bad_root=$2 state_dir="$capture_fixture/admission-$1" output_dir="$capture_fixture/output-$1"
  mkdir -p "$state_dir" "$output_dir"
  printf 'before\n' >"$state_dir/sentinel"
  : >"$capture_fixture/admission-calls.log"
  if CAPTURE_CALLS_FILE="$capture_fixture/admission-calls.log" \
    PATH="$capture_fixture/bin:$PATH" bash "$capture" \
      --recovery-id recovery-fixture --root "$bad_root" --output-dir "$output_dir" \
      --recipient age1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0savhh7m \
      --public-url https://api.whysoezzy.online --state-root "$state_dir" \
      --compose-script "$capture_fixture/bin/compose" \
      --probe-script "$capture_fixture/bin/probe" \
      --backup-script "$capture_fixture/bin/compose"; then
    fail "invalid $label release root was accepted"
  fi
  [ ! -s "$capture_fixture/admission-calls.log" ]
  [ "$(cat "$state_dir/sentinel")" = before ]
  [ ! -e "$output_dir/postgres.dump.age" ]
}
run_probe_admission_case(){
  local label=$1 bad_root=$2 output="$capture_fixture/probe-$1.json"
  rm -f -- "$output" "$capture_fixture/probe-$1.json."*
  : >"$capture_fixture/admission-calls.log"
  if CAPTURE_CALLS_FILE="$capture_fixture/admission-calls.log" \
    PATH="$capture_fixture/bin:$PATH" bash "$root/scripts/probe-test-vps-recovery-runtime.sh" \
      --root "$bad_root" --compose-script "$capture_fixture/bin/compose" \
      --output "$output" --public-url https://api.whysoezzy.online; then
    fail "invalid $label probe root was accepted"
  fi
  [ ! -s "$capture_fixture/admission-calls.log" ]
  [ ! -e "$output" ]
}
mkdir "$capture_fixture/state-only" "$capture_fixture/missing-env" "$capture_fixture/empty-env" \
  "$capture_fixture/symlink-env"
: >"$capture_fixture/empty-env/.env.production"
symlink_supported=false
if ln -s "$capture_fixture/root" "$capture_fixture/symlink-root" &&
  [ -L "$capture_fixture/symlink-root" ]; then
  symlink_supported=true
else
  rm -r -- "$capture_fixture/symlink-root" 2>/dev/null || true
fi
if ln -s "$capture_fixture/root/.env.production" "$capture_fixture/symlink-env/.env.production" &&
  [ -L "$capture_fixture/symlink-env/.env.production" ]; then
  symlink_supported=true
else
  rm -f -- "$capture_fixture/symlink-env/.env.production"
fi
run_capture_admission_case missing "$capture_fixture/missing-root"
run_capture_admission_case blank ''
run_capture_admission_case relative relative/root
run_capture_admission_case double-dot "$capture_fixture/missing-root/../missing-root"
run_capture_admission_case metacharacter "$capture_fixture/missing-root;touch"
run_capture_admission_case state-only "$capture_fixture/state-only"
run_capture_admission_case missing-env "$capture_fixture/missing-env"
run_capture_admission_case empty-env "$capture_fixture/empty-env"
if [ "$symlink_supported" = true ]; then
  run_capture_admission_case symlink "$capture_fixture/symlink-root"
  run_capture_admission_case symlink-env "$capture_fixture/symlink-env"
fi
run_probe_admission_case missing "$capture_fixture/missing-root"
run_probe_admission_case blank ''
run_probe_admission_case relative relative/root
run_probe_admission_case double-dot "$capture_fixture/missing-root/../missing-root"
run_probe_admission_case metacharacter "$capture_fixture/missing-root;touch"
run_probe_admission_case state-only "$capture_fixture/state-only"
run_probe_admission_case missing-env "$capture_fixture/missing-env"
run_probe_admission_case empty-env "$capture_fixture/empty-env"
if [ "$symlink_supported" = true ]; then
  run_probe_admission_case symlink "$capture_fixture/symlink-root"
  run_probe_admission_case symlink-env "$capture_fixture/symlink-env"
fi
write_capture_journal() {
  local state_root=$1 healthy=$2 safe=$3 keep_owned=${4:-true} state_dir="$1/beta-recovery-recovery-fixture"
  mkdir -p "$state_dir"
  if [ "$keep_owned" = true ]; then
    mkdir -p "$state_dir/private" "$state_dir/staging"
    printf owned >"$state_dir/private/capture-runtime.json"
    printf staged >"$state_dir/staging/owned"
  fi
  jq -cnS --arg healthy "$healthy" --arg safe "$safe" \
    '{schema:"meet-backend/beta-recovery-journal/v1",recoveryId:"recovery-fixture",
      state:"nonterminal",phase:"runtime_verified",capturedContainerId:"aaaaaaaaaaaaaaaa",
      capturedImageId:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      capturedRuntimeDigest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      currentRuntimeHealthy:($healthy=="true"),capturedContainerSafe:($safe=="true"),
      ownedPaths:["private/capture-runtime.json","private/post-capture.json","private/capture-result.json",
      "private/capture-database-proof.json","private/capture-media-proof.json","private/postgres.dump.age",
      "private/uploads.tar.gz.age","staging"]}' >"$state_dir/journal.json"
}
run_capture_reconcile() {
  local mode=$1 state_root=$2
  rm -f -- "$state_root/reconcile.json"
  PATH="$capture_fixture/bin:$PATH" \
    CAPTURE_EXPECTED_PRODUCTION_ROOT="$capture_fixture/root" \
    CAPTURE_INSPECT_MODE="$mode" \
    bash "$capture" reconcile --root "$capture_fixture/root" \
    --public-url https://example.test --state-root "$state_root" \
    --output "$state_root/reconcile.json" \
    --compose-script "$capture_fixture/bin/compose" \
    --probe-script "$capture_fixture/bin/probe" \
    --backup-script "$capture_fixture/bin/compose"
}
for inspect_mode in daemon permission timeout unknown; do
  error_root="$capture_fixture/state-$inspect_mode"
  write_capture_journal "$error_root" true true
  error_state="$error_root/beta-recovery-recovery-fixture"
  error_journal_before=$(sha256sum "$error_state/journal.json")
  error_owned_before=$(find "$error_state/private" "$error_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)
  if run_capture_reconcile "$inspect_mode" "$error_root"; then
    fail "Docker $inspect_mode inspection error was treated as not-found"
  fi
  [ "$error_journal_before" = "$(sha256sum "$error_state/journal.json")" ] &&
    [ "$error_owned_before" = "$(find "$error_state/private" "$error_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)" ] &&
    [ "$(jq -er .state "$error_state/journal.json")" = nonterminal ] ||
    fail "inspection error changed journal state"
  [ -f "$error_state/private/capture-runtime.json" ] && [ -f "$error_state/staging/owned" ] ||
    fail "inspection error deleted owned state"
done
not_found_root="$capture_fixture/state-not-found"
write_capture_journal "$not_found_root" true true false
run_capture_reconcile not-found "$not_found_root"
not_found_state="$not_found_root/beta-recovery-recovery-fixture"
jq -e '.state=="terminal" and .phase=="superseded" and
  .currentRuntimeHealthy==true and .capturedContainerSafe==true' \
  "$not_found_state/journal.json" >/dev/null
[ -f "$not_found_state/incident.json" ] && [ ! -e "$not_found_state/private/capture-runtime.json" ] &&
  [ ! -e "$not_found_state/staging" ] || fail "not-found reconciliation did not clean owned state"
incident_before=$(sha256sum "$not_found_state/incident.json")
journal_before=$(sha256sum "$not_found_state/journal.json")
run_capture_reconcile not-found "$not_found_root"
[ "$incident_before" = "$(sha256sum "$not_found_state/incident.json")" ] &&
  [ "$journal_before" = "$(sha256sum "$not_found_state/journal.json")" ] ||
  fail "generated true-flag reconciliation was not idempotent"
for unsafe_flags in healthy safe; do
  unsafe_root="$capture_fixture/state-false-$unsafe_flags"
  if [ "$unsafe_flags" = healthy ]; then
    write_capture_journal "$unsafe_root" false true
  else
    write_capture_journal "$unsafe_root" true false
  fi
  unsafe_state="$unsafe_root/beta-recovery-recovery-fixture"
  unsafe_journal_before=$(sha256sum "$unsafe_state/journal.json")
  unsafe_owned_before=$(find "$unsafe_state/private" "$unsafe_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)
  if run_capture_reconcile not-found "$unsafe_root"; then
    fail "false $unsafe_flags journal was reconciled"
  fi
  [ "$unsafe_journal_before" = "$(sha256sum "$unsafe_state/journal.json")" ] &&
    [ "$unsafe_owned_before" = "$(find "$unsafe_state/private" "$unsafe_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)" ] &&
    [ "$(jq -er .state "$unsafe_state/journal.json")" = nonterminal ] &&
    [ -f "$unsafe_state/private/capture-runtime.json" ] && [ -f "$unsafe_state/staging/owned" ] ||
    fail "false $unsafe_flags journal lost owned state"
done
invalid_phase_root="$capture_fixture/state-invalid-phase"
write_capture_journal "$invalid_phase_root" true true
invalid_phase_state="$invalid_phase_root/beta-recovery-recovery-fixture"
jq '.phase="invalid_phase"' "$invalid_phase_state/journal.json" >"$invalid_phase_state/journal.tmp"
mv -- "$invalid_phase_state/journal.tmp" "$invalid_phase_state/journal.json"
printf '{}' >"$invalid_phase_state/incident.json"
invalid_phase_journal_before=$(sha256sum "$invalid_phase_state/journal.json")
invalid_phase_owned_before=$(find "$invalid_phase_state/private" "$invalid_phase_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)
if run_capture_reconcile not-found "$invalid_phase_root"; then
  fail "invalid journal phase was reconciled"
fi
[ "$invalid_phase_journal_before" = "$(sha256sum "$invalid_phase_state/journal.json")" ] &&
  [ "$invalid_phase_owned_before" = "$(find "$invalid_phase_state/private" "$invalid_phase_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)" ] &&
  [ "$(jq -er .state "$invalid_phase_state/journal.json")" = nonterminal ] ||
  fail "invalid journal phase changed capture state"
terminal_incident_root="$capture_fixture/state-invalid-incident"
write_capture_journal "$terminal_incident_root" true true
terminal_incident_state="$terminal_incident_root/beta-recovery-recovery-fixture"
jq '.state="terminal"|.phase="superseded"' "$terminal_incident_state/journal.json" >"$terminal_incident_state/journal.tmp"
mv -- "$terminal_incident_state/journal.tmp" "$terminal_incident_state/journal.json"
printf '{}' >"$terminal_incident_state/incident.json"
terminal_incident_journal_before=$(sha256sum "$terminal_incident_state/journal.json")
terminal_incident_owned_before=$(find "$terminal_incident_state/private" "$terminal_incident_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)
if run_capture_reconcile not-found "$terminal_incident_root"; then
  fail "malformed terminal incident was reconciled"
fi
[ "$terminal_incident_journal_before" = "$(sha256sum "$terminal_incident_state/journal.json")" ] &&
  [ "$terminal_incident_owned_before" = "$(find "$terminal_incident_state/private" "$terminal_incident_state/staging" -type f -exec sha256sum {} \; | sort | sha256sum)" ] &&
  [ "$(jq -er .state "$terminal_incident_state/journal.json")" = terminal ] ||
  fail "malformed terminal incident changed capture state"
echo "beta recovery capture contract passed"
