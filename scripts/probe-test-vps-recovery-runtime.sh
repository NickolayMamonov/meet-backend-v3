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
[ -d "$root" ] && [ -x "$compose" ] && [ -n "$output" ] || usage
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
meetings=$(mktemp "$output.response.XXXXXX"); headers=$(mktemp "$output.headers.XXXXXX")
trap 'rm -f -- "$meetings" "$headers"' EXIT HUP INT TERM
[ "$(curl --fail --silent --show-error --proto '=https' --tlsv1.2 -o "$meetings" -w '%{http_code}' "$url/meetings")" = 200 ] ||
  fail "meetings status differs"
jq -e 'type == "array"' "$meetings" >/dev/null || fail "meetings response is not JSON array"
[ "$(curl --silent --show-error --proto '=https' --tlsv1.2 -o /dev/null -w '%{http_code}' "$url/actuator")" = 404 ] ||
  fail "actuator status differs"
curl --silent --show-error --proto '=http' -D "$headers" -o /dev/null \
  "${url/https:\/\//http://}/meetings" || fail "HTTP redirect probe failed"
grep -Eiq '^location:[[:space:]]*https://' "$headers" || fail "HTTP does not redirect to HTTPS"
tmp=$output.tmp.$$
trap 'rm -f -- "$tmp" "$meetings" "$headers"' EXIT HUP INT TERM
jq -cnS --arg image "$image" --arg hash "$config_hash" \
  '{schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
    runtime:{imageId:$image,configHash:$hash,health:"healthy",uploadsMount:"volume"},
    https:{meetingsStatus:"200",actuatorStatus:"404",httpRedirectHttps:true,meetingsJson:true}}' >"$tmp"
chmod 600 "$tmp"; mv -f -- "$tmp" "$output"; trap - EXIT HUP INT TERM
