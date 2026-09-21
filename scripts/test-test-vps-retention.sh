#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -ne 0 ]; then
  echo "PREREQUISITE_MISSING" >&2
  exit 77
fi

fixture_root=$(mktemp -d /tmp/meet-retention-fixture.XXXXXX)
state_root=/var/lib/meet-test-vps-deploy
production_root=/var/lib/meet-retention-production
production_runtime_root=/var/lib/meet-production
fake_bin="$fixture_root/bin"
remote_script="$fixture_root/retention-remote.sh"
created_fixed_roots=()
cleanup() {
  local status=$?
  trap - EXIT
  for path in "${created_fixed_roots[@]}"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      rm -r -- "$path"
    fi
  done
  rm -r -- "$fixture_root"
  exit "$status"
}
trap cleanup EXIT

if [ "${1:-}" = --check-fixed-roots ]; then
  for path in "$state_root" "$production_root" "$production_runtime_root"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      echo "PREREQUISITE_MISSING: fixed fixture root already exists" >&2
      exit 77
    fi
  done
  exit 0
fi

for path in "$state_root" "$production_root" "$production_runtime_root"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "PREREQUISITE_MISSING: fixed fixture root already exists" >&2
    exit 77
  fi
done

(
  set -euo pipefail
  probe_cleanup() {
    for path in "$state_root" "$production_root" "$production_runtime_root"; do
      if [ -e "$path" ] || [ -L "$path" ]; then
        rm -r -- "$path"
      fi
    done
  }
  trap probe_cleanup EXIT
  for path in "$state_root" "$production_root" "$production_runtime_root"; do
    install -d -m 700 "$path"
    printf 'fixed-root-sentinel\n' >"$path/sentinel"
    chmod 600 "$path/sentinel"
  done
  fixed_before=$(
    for path in "$state_root" "$production_root" "$production_runtime_root"; do
      find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l\n'
      find "$path" -xdev -type f -exec sha256sum {} +
    done | sort
  )
  set +e
  fixed_output=$(bash "$0" --check-fixed-roots 2>&1)
  fixed_status=$?
  set -e
  [ "$fixed_status" -eq 77 ]
  grep -Fq 'fixed fixture root already exists' <<<"$fixed_output"
  test "$fixed_before" = "$(
    for path in "$state_root" "$production_root" "$production_runtime_root"; do
      find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l\n'
      find "$path" -xdev -type f -exec sha256sum {} +
    done | sort
  )"
)

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
write_owner_marker() {
  local state=$1
  local name=${state##*/}
  local run_key=${name%-final-deploy}
  [ "$run_key" = "$name" ] && run_key=${name%-rollback-drill}
  local state_kind=${name#"$run_key"-}
  printf '{"schemaVersion":1,"owner":"meet-test-vps-provider","runKey":"%s","stateKind":"%s"}\n' \
    "$run_key" "$state_kind" >"$state/provider-owner.json"
  chmod 600 "$state/provider-owner.json"
}

install -d -m 700 "$fake_bin"
install -d -m 700 "$state_root"
created_fixed_roots+=("$state_root" "$production_root")
install -d -m 700 "$production_root"
created_fixed_roots+=("$production_root")
install -d -m 700 "$production_runtime_root"
created_fixed_roots+=("$production_runtime_root")
printf 'fixture\n' >"$production_root/.env.production"
printf 'services:\n  backend:\n    image: fixture\n' >"$production_root/docker-compose.production.yml"
printf 'services:\n  backend:\n    image: fixture\n' >"$production_runtime_root/active-compose.yml"
printf 'services:\n  backend:\n    healthcheck:\n      test: ["CMD", "true"]\n' >"$production_runtime_root/active-runtime.override.yml"

for name in "${legacy_names[@]}"; do
  install -d -m 700 "$state_root/$name"
  printf 'legacy synthetic bytes: %s\n' "$name" >"$state_root/$name/opaque.bin"
  chmod 600 "$state_root/$name/opaque.bin"
done
legacy_before=$(legacy_digest)
set +e
legacy_delete_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$state_root/${legacy_names[0]}" 2>&1)
legacy_delete_status=$?
set -e
[ "$legacy_delete_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$legacy_delete_output"
test "$legacy_before" = "$(legacy_digest)"

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ps)
    printf 'fixture-backend\nfixture-provider\n'
    ;;
  inspect)
    case "${2:-}" in
      fixture-backend)
        printf '[{"Type":"volume","Name":"uploads","Destination":"/data/uploads"}]\n'
        ;;
      fixture-provider)
        printf '[{"Type":"bind","Source":"/var/lib/meet-test-vps-deploy/12-1-final-deploy/provider-runtime","Destination":"/run/provider"}]\n'
        ;;
      *)
        printf '{}\n'
        ;;
    esac
    ;;
  compose)
    case " $* " in
      *"/12-1-final-deploy/"*)
        printf '{"services":{"backend":{"volumes":[{"type":"bind","source":"/var/lib/meet-test-vps-deploy/12-1-final-deploy/protected-input","target":"/protected"}]}}}\n'
        ;;
      *)
        printf '{"services":{"backend":{"volumes":[]}}}\n'
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
FAKE_DOCKER
chmod 700 "$fake_bin/docker"

awk '
  /name: Apply bounded test-VPS deployment retention/ { section=1 }
  section && /<<'\''REMOTE'\''/ { inside=1; next }
  inside && /^          REMOTE$/ { exit }
  inside { sub(/^          /, ""); print }
' .github/workflows/deploy-test-vps.yml >"$remote_script"
chmod 700 "$remote_script"

for index in $(seq 1 12); do
  state="$state_root/${index}-1-final-deploy"
  install -d -m 700 "$state"
  printf '{"schemaVersion":1,"runKey":"%s-1","outcome":"committed","providerEnabled":false}\n' \
    "$index" >"$state/terminal.json"
  chmod 600 "$state/terminal.json"
  write_owner_marker "$state"
  touch -d "@$((1800000000 - index))" "$state"
done
owned_digest() {
  local path=$1
  find "$path" -xdev -printf '%p|%y|%m|%u|%g|%l\n' | sort
  find "$path" -xdev -type f -exec sha256sum {} +
}
protected_state="$state_root/1-1-final-deploy"
protected_before=$(owned_digest "$protected_state")
set +e
protected_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$protected_state" \
  --protected-state "$protected_state" 2>&1)
protected_status=$?
set -e
[ "$protected_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$protected_output"
[ -d "$protected_state" ]
[ ! -e "$state_root/.provider-state.1-1-final-deploy.tmp" ]
test "$protected_before" = "$(owned_digest "$protected_state")"
smtp_guard="$state_root/2-1-final-deploy"
smtp_before=$(owned_digest "$smtp_guard")
smtp_quarantine="$state_root/.provider-state.smtp-guard.tmp"
install -d -m 700 "$smtp_quarantine"
printf 'pre-existing smtp quarantine\n' >"$smtp_quarantine/sentinel"
chmod 600 "$smtp_quarantine/sentinel"
smtp_quarantine_before=$(owned_digest "$smtp_quarantine")
ln -s "$state_root/missing-smtp-transaction-target" \
  "$state_root/.smtp-transaction.current"
set +e
smtp_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$smtp_guard" 2>&1)
smtp_status=$?
set -e
[ "$smtp_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$smtp_output"
[ -L "$state_root/.smtp-transaction.current" ]
[ -d "$smtp_guard" ]
test "$smtp_before" = "$(owned_digest "$smtp_guard")"
test "$smtp_quarantine_before" = "$(owned_digest "$smtp_quarantine")"
rm -f -- "$state_root/.smtp-transaction.current"
rm -r -- "$smtp_quarantine"
install -d -m 700 "$state_root/12-1-final-deploy/protected-input"
install -d -m 700 "$state_root/12-1-final-deploy/provider-runtime"
printf 'services:\n  backend:\n    volumes: []\n' \
  >"$state_root/12-1-final-deploy/target-runtime.override.yml"
install -d -m 700 "$state_root/12-1-final-deploy-shadow"
install -d -m 700 "$state_root/14-1-final-deploy"
printf '{"schemaVersion":1,"runKey":"14-1","outcome":"committed","providerEnabled":false}\n' \
  >"$state_root/14-1-final-deploy/terminal.json"
chmod 600 "$state_root/14-1-final-deploy/terminal.json"
write_owner_marker "$state_root/14-1-final-deploy"
printf 'unknown\n' >"$state_root/14-1-final-deploy/unknown.txt"
touch -d '@1799999980' "$state_root/14-1-final-deploy"
install -d -m 700 "$state_root/17-1-final-deploy"
printf '{"schemaVersion":1,"runKey":"17-1","outcome":"committed","providerEnabled":false}\n' \
  >"$state_root/17-1-final-deploy/terminal.json"
chmod 600 "$state_root/17-1-final-deploy/terminal.json"
write_owner_marker "$state_root/17-1-final-deploy"
printf 'unknown-before-race\n' >"$state_root/17-1-final-deploy/unknown-before-race.txt"
touch -d '@1799999970' "$state_root/17-1-final-deploy"

tooling_root="$production_root/.test-vps-tooling-1-1"
install -d -m 700 "$tooling_root/scripts"
cp scripts/test-vps-provider-credential.py \
  "$tooling_root/scripts/provider-credential-real.py"
cat >"$tooling_root/scripts/test-vps-provider-credential.py" <<EOF
#!/usr/bin/env python3
import pathlib
import runpy
import sys

arguments = sys.argv[1:]
if arguments and arguments[0] == "retention-delete":
    state_index = arguments.index("--retention-state") + 1
    state_path = arguments[state_index]
    if (
        state_path == "$state_root/17-1-final-deploy"
        and not pathlib.Path("$state_root/17-1-final-deploy/concurrent-unknown.txt").exists()
    ):
        pathlib.Path("$state_root/17-1-final-deploy/concurrent-unknown.txt").write_text(
            "unknown-concurrent\n", encoding="utf-8"
        )
module = runpy.run_path("$tooling_root/scripts/provider-credential-real.py")
raise SystemExit(module["main"](arguments))
EOF
chmod 700 "$tooling_root/scripts/test-vps-provider-credential.py"
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"

[ -d "$state_root/1-1-final-deploy" ]
[ -d "$state_root/10-1-final-deploy" ]
[ ! -e "$state_root/11-1-final-deploy" ]
[ -d "$state_root/12-1-final-deploy" ]
[ -d "$state_root/12-1-final-deploy/provider-runtime" ]
[ -d "$state_root/12-1-final-deploy-shadow" ]
[ -d "$state_root/14-1-final-deploy" ]
[ -f "$state_root/14-1-final-deploy/unknown.txt" ]
[ -d "$state_root/17-1-final-deploy" ]
[ -f "$state_root/17-1-final-deploy/unknown-before-race.txt" ]
[ ! -e "$state_root/17-1-final-deploy/concurrent-unknown.txt" ]
[ ! -e "$tooling_root" ]

ln -s "$state_root/12-1-final-deploy" "$state_root/13-1-final-deploy"
set +e
symlink_output=$(bash "$remote_script" \
  "$production_root" 1 1 "$production_root/.missing-tooling" 2>&1)
symlink_status=$?
set -e
[ "$symlink_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$symlink_output"
[ -L "$state_root/13-1-final-deploy" ]
rm -f -- "$state_root/13-1-final-deploy"

unresolved_state="$state_root/19-1-final-deploy"
install -d -m 700 "$unresolved_state"
printf 'pre-marker-snapshot\n' >"$unresolved_state/config.env.production"
chmod 600 "$unresolved_state/config.env.production"
set +e
unresolved_output=$(bash "$remote_script" \
  "$production_root" 1 1 "$production_root/.missing-tooling" 2>&1)
unresolved_status=$?
set -e
[ "$unresolved_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$unresolved_output"
[ -d "$unresolved_state" ]
rm -r -- "$unresolved_state"

hard_state="$state_root/18-1-final-deploy"
install -d -m 700 "$hard_state"
hard_witness="$fixture_root/operator-owned-terminal.json"
printf '{"schemaVersion":1,"runKey":"18-1","outcome":"committed","providerEnabled":false}\n' \
  >"$hard_witness"
rm -f -- "$hard_state/terminal.json"
ln "$hard_witness" "$hard_state/terminal.json"
touch -d '@1799999960' "$hard_state"
chmod 600 "$hard_witness"
set +e
hard_output=$(python3 scripts/test-vps-provider-credential.py \
  retention-delete --state-root "$state_root" \
  --retention-state "$hard_state" 2>&1)
hard_status=$?
set -e
[ "$hard_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$hard_output"
[ -d "$hard_state" ]
[ -f "$hard_witness" ]
[ "$(stat -c '%d:%i' "$hard_state/terminal.json")" = "$(stat -c '%d:%i' "$hard_witness")" ]
rm -r -- "$hard_state" "$hard_witness"

hang_bin="$fixture_root/hang-bin"
install -d -m 700 "$hang_bin"
real_timeout=$(command -v timeout)
cat >"$hang_bin/timeout" <<EOF
#!/usr/bin/env bash
if [ "\${2:-}" = docker ]; then
  exit 124
fi
exec "$real_timeout" "\$@"
EOF
chmod 700 "$hang_bin/timeout"
state="$state_root/16-1-final-deploy"
install -d -m 700 "$state"
printf '{"schemaVersion":1,"runKey":"16-1","outcome":"committed","providerEnabled":false}\n' \
  >"$state/terminal.json"
chmod 600 "$state/terminal.json"
write_owner_marker "$state"
touch -d '@1799999980' "$state"
tooling_root="$production_root/.test-vps-tooling-1-1"
install -d -m 700 "$tooling_root/scripts"
cp scripts/test-vps-provider-credential.py \
  "$tooling_root/scripts/provider-credential-real.py"
cat >"$tooling_root/scripts/test-vps-provider-credential.py" <<EOF
#!/usr/bin/env python3
import runpy
import sys

module = runpy.run_path("$tooling_root/scripts/provider-credential-real.py")
raise SystemExit(module["main"](sys.argv[1:]))
EOF
chmod 700 "$tooling_root/scripts/test-vps-provider-credential.py"
set +e
timeout_output=$(PATH="$hang_bin:$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root" 2>&1)
timeout_status=$?
set -e
[ "$timeout_status" -eq 1 ]
grep -Fq 'RECOVERY_REQUIRED' <<<"$timeout_output"
[ -d "$state" ]
[ -d "$tooling_root" ]
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"
[ ! -e "$state" ]
[ ! -e "$tooling_root" ]

state="$state_root/15-1-final-deploy"
install -d -m 700 "$state"
printf '{"schemaVersion":1,"runKey":"15-1","outcome":"committed","providerEnabled":false}\n' \
  >"$state/terminal.json"
chmod 600 "$state/terminal.json"
write_owner_marker "$state"
touch -d '@1799999970' "$state"
tooling_root="$production_root/.test-vps-tooling-1-1"
install -d -m 700 "$tooling_root/scripts"
cp scripts/test-vps-provider-credential.py \
  "$tooling_root/scripts/provider-credential-real.py"
cat >"$tooling_root/scripts/test-vps-provider-credential.py" <<EOF
#!/usr/bin/env python3
import runpy
import sys

module = runpy.run_path("$tooling_root/scripts/provider-credential-real.py")
raise SystemExit(module["main"](sys.argv[1:]))
EOF
chmod 700 "$tooling_root/scripts/test-vps-provider-credential.py"
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"
[ ! -e "$state_root/15-1-final-deploy" ]
[ ! -e "$tooling_root" ]
test "$legacy_before" = "$(legacy_digest)"
echo "retention fixture passed: all-service mounts, timeout failure, self-tooling ordering, repeated-run cleanup, protected reference, unknown, symlink and prefix-collision cases"
