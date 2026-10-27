#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 --root PATH --compose-script PATH --output PATH --public-url https://api.whysoezzy.online [--lock-path PATH]" >&2; exit 2; }
fail(){ echo "test VPS recovery probe failed: $*" >&2; exit 1; }
root='' compose='' output='' url='' lock_path=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2;; --compose-script) compose=$2; shift 2;;
    --output) output=$2; shift 2;; --public-url) url=$2; shift 2;;
    --lock-path) lock_path=$2; shift 2;; *) usage;;
  esac
done
[ -n "$root" ] && [ -n "$compose" ] && [ -n "$output" ] || usage
[ -d "$root" ] && [ ! -L "$root" ] ||
  fail "release root is unsafe"
[ -f "$root/.env.production" ] && [ ! -L "$root/.env.production" ] &&
  [ -s "$root/.env.production" ] ||
  fail "release configuration is unavailable"
export PRODUCTION_ROOT="$root"
[ -x "$compose" ] || usage
[ "$url" = https://api.whysoezzy.online ] || fail "reviewed HTTPS URL is required"
[ ! -L "$output" ] && [ -d "$(dirname -- "$output")" ] || fail "unsafe output"
for tool in docker jq curl flock; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
if [ -n "$lock_path" ]; then
  [ -f "$lock_path" ] && [ ! -L "$lock_path" ] || fail "unsafe lock path"
  exec 9>"$lock_path"; flock -n 9 || fail "deploy lock is busy"
fi
container=$("$compose" ps -q backend); [ -n "$container" ] || fail "backend missing"
[ "$(docker inspect "$container" --format '{{.State.Running}}')" = true ] || fail "backend stopped"
health=$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}')
[ "$health" = healthy ] || fail "backend unhealthy or missing healthcheck"
image=$(docker inspect "$container" --format '{{.Image}}')
config_hash=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
[[ "$config_hash" =~ ^[0-9a-f]{64}$ ]] || fail "runtime config identity unavailable"
uploads=$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{printf "%s|%s" .Type .Name}}{{end}}{{end}}')
[ "$uploads" = "volume|meet-production_uploads_data" ] || fail "uploads mount differs"
allocations=()
pending_signal=0
cleanup(){
  local status=$? cleanup_status=0 path
  trap - EXIT HUP INT TERM
  for path in "${allocations[@]}"; do
    if ! rm -f -- "$path"; then
      cleanup_status=1
    fi
  done
  if [ "$cleanup_status" -ne 0 ]; then
    echo "test VPS recovery probe failed: temporary-file cleanup failed" >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
forget_allocation(){
  local path=$1 remaining=() allocated
  for allocated in "${allocations[@]}"; do
    [ "$allocated" = "$path" ] || remaining+=("$allocated")
  done
  allocations=("${remaining[@]}")
}
allocate_temp(){
  local template=$1 path allocation_status
  pending_signal=0
  trap 'pending_signal=129' HUP
  trap 'pending_signal=130' INT
  trap 'pending_signal=143' TERM
  if path=$(mktemp "$template"); then
    allocations+=("$path")
  else
    allocation_status=$?
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ "$pending_signal" -eq 0 ] || exit "$pending_signal"
    return "$allocation_status"
  fi
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "$pending_signal" -eq 0 ] || exit "$pending_signal"
  allocated_temp=$path
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
allocate_temp "$output.response.XXXXXX"; meetings=$allocated_temp
allocate_temp "$output.headers.XXXXXX"; headers=$allocated_temp
[ "$(curl --fail --silent --show-error --proto '=https' --tlsv1.2 -o "$meetings" -w '%{http_code}' "$url/meetings")" = 200 ] ||
  fail "meetings status differs"
jq -e 'type == "array"' "$meetings" >/dev/null || fail "meetings response is not JSON array"
[ "$(curl --silent --show-error --proto '=https' --tlsv1.2 -o /dev/null -w '%{http_code}' "$url/actuator")" = 404 ] ||
  fail "actuator status differs"
curl --silent --show-error --proto '=http' -D "$headers" -o /dev/null \
  "${url/https:\/\//http://}/meetings" || fail "HTTP redirect probe failed"
grep -Eiq '^location:[[:space:]]*https://' "$headers" || fail "HTTP does not redirect to HTTPS"
allocate_temp "$output.tmp.XXXXXX"; tmp=$allocated_temp
jq -cnS --arg image "$image" --arg hash "$config_hash" \
  '{schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
    runtime:{imageId:$image,configHash:$hash,health:"healthy",uploadsMount:"volume"},
    https:{meetingsStatus:"200",actuatorStatus:"404",httpRedirectHttps:true,meetingsJson:true}}' >"$tmp"
chmod 600 "$tmp"; mv -f -- "$tmp" "$output"
forget_allocation "$tmp"
