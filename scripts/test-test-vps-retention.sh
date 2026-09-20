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
fake_bin="$fixture_root/bin"
remote_script="$fixture_root/retention-remote.sh"
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$fixture_root" "$state_root" "$production_root"
  exit "$status"
}
trap cleanup EXIT

install -d -m 700 "$fake_bin" "$state_root" "$production_root"
install -d -m 700 /var/lib/meet-production
printf 'fixture\n' >"$production_root/.env.production"
printf 'services:\n  backend:\n    image: fixture\n' >"$production_root/docker-compose.production.yml"
printf 'services:\n  backend:\n    image: fixture\n' >/var/lib/meet-production/active-compose.yml
printf 'services:\n  backend:\n    healthcheck:\n      test: ["CMD", "true"]\n' >/var/lib/meet-production/active-runtime.override.yml

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
  touch -d "@$((1800000000 - index))" "$state"
done
install -d -m 700 "$state_root/12-1-final-deploy/protected-input"
install -d -m 700 "$state_root/12-1-final-deploy/provider-runtime"
printf 'services:\n  backend:\n    volumes: []\n' \
  >"$state_root/12-1-final-deploy/target-runtime.override.yml"
ln -s "$state_root/12-1-final-deploy" "$state_root/13-1-final-deploy"
install -d -m 700 "$state_root/12-1-final-deploy-shadow"
install -d -m 700 "$state_root/14-1-final-deploy"
printf '{"schemaVersion":1,"runKey":"14-1","outcome":"committed","providerEnabled":false}\n' \
  >"$state_root/14-1-final-deploy/terminal.json"
printf 'unknown\n' >"$state_root/14-1-final-deploy/unknown.txt"
touch -d '@1799999980' "$state_root/14-1-final-deploy"
install -d -m 700 "$state_root/17-1-final-deploy"
printf '{"schemaVersion":1,"runKey":"17-1","outcome":"committed","providerEnabled":false}\n' \
  >"$state_root/17-1-final-deploy/terminal.json"
printf 'unknown-before-race\n' >"$state_root/17-1-final-deploy/unknown-before-race.txt"
touch -d '@1799999970' "$state_root/17-1-final-deploy"

real_rmdir=$(command -v rmdir)
cat >"$fake_bin/rmdir" <<EOF
#!/usr/bin/env bash
set -euo pipefail
path=\${1:-}
if [ "\$path" = -- ]; then
  path=\${2:-}
fi
if [ "\${path##*/}" = 17-1-final-deploy ] &&
  [ ! -e "\$path/concurrent-unknown.txt" ]; then
  printf 'unknown-concurrent\n' >"\$path/concurrent-unknown.txt"
fi
exec "$real_rmdir" "\$@"
EOF
chmod 700 "$fake_bin/rmdir"

tooling_root="$production_root/.test-vps-tooling-1-1"
install -d -m 700 "$tooling_root/scripts"
cp scripts/test-vps-provider-credential.py "$tooling_root/scripts/"
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"

[ -d "$state_root/1-1-final-deploy" ]
[ -d "$state_root/10-1-final-deploy" ]
[ ! -e "$state_root/11-1-final-deploy" ]
[ -d "$state_root/12-1-final-deploy" ]
[ -d "$state_root/12-1-final-deploy/provider-runtime" ]
[ -L "$state_root/13-1-final-deploy" ]
[ -d "$state_root/12-1-final-deploy-shadow" ]
[ -d "$state_root/14-1-final-deploy" ]
[ -f "$state_root/14-1-final-deploy/unknown.txt" ]
[ -d "$state_root/17-1-final-deploy" ]
[ -f "$state_root/17-1-final-deploy/unknown-before-race.txt" ]
[ -f "$state_root/17-1-final-deploy/concurrent-unknown.txt" ]
[ ! -e "$tooling_root" ]

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
touch -d '@1799999980' "$state"
tooling_root="$production_root/.test-vps-tooling-1-1"
install -d -m 700 "$tooling_root/scripts"
cp scripts/test-vps-provider-credential.py "$tooling_root/scripts/"
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
touch -d '@1799999970' "$state"
tooling_root="$production_root/.test-vps-tooling-1-1"
install -d -m 700 "$tooling_root/scripts"
cp scripts/test-vps-provider-credential.py "$tooling_root/scripts/"
PATH="$fake_bin:$PATH" bash "$remote_script" \
  "$production_root" 1 1 "$tooling_root"
[ ! -e "$state_root/15-1-final-deploy" ]
[ ! -e "$tooling_root" ]
echo "retention fixture passed: all-service mounts, timeout failure, self-tooling ordering, repeated-run cleanup, protected reference, unknown, symlink and prefix-collision cases"
