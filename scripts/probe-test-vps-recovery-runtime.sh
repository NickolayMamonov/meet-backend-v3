#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 --root PATH --compose-script PATH --output PATH [--public-url URL]" >&2; exit 2; }
fail(){ echo "test VPS recovery probe failed: $*" >&2; exit 1; }
root='' compose='' output='' url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2;; --compose-script) compose=$2; shift 2;;
    --output) output=$2; shift 2;; --public-url) url=$2; shift 2;; *) usage;;
  esac
done
[ -d "$root" ] && [ -x "$compose" ] && [ -n "$output" ] || usage
[ ! -L "$output" ] && [ -d "$(dirname -- "$output")" ] || fail "unsafe output"
for tool in docker jq; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
[ -z "$url" ] || command -v curl >/dev/null 2>&1 || fail "curl is required"
container=$("$compose" ps -q backend); [ -n "$container" ] || fail "backend missing"
[ "$(docker inspect "$container" --format '{{.State.Running}}')" = true ] || fail "backend stopped"
health=$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}')
[ "$health" = healthy ] || [ "$health" = unknown ] || fail "backend unhealthy"
image=$(docker inspect "$container" --format '{{.Image}}')
config_hash=$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.config-hash"}}')
[ "$(docker inspect "$container" --format '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{.Type}}{{end}}{{end}}')" = volume ] || fail "uploads mount differs"
meetings_status=not_checked; actuator_status=not_checked; redirect=false; json=false
if [ -n "$url" ]; then
  meetings_status=$(curl --fail --silent --show-error --proto '=https' --tlsv1.2 -o "$output.response" -w '%{http_code}' "$url/meetings")
  jq -e 'type == "array"' "$output.response" >/dev/null || fail "meetings response differs"
  json=true
  actuator_status=$(curl --silent --show-error --proto '=https' --tlsv1.2 -o /dev/null -w '%{http_code}' "$url/actuator")
  headers=$output.headers
  curl --silent --show-error --proto '=http' -D "$headers" -o /dev/null "${url/https:\/\//http://}/meetings" || fail "redirect probe failed"
  grep -Eiq '^location:[[:space:]]*https://' "$headers" || fail "HTTP does not redirect to HTTPS"
  redirect=true; rm -f -- "$output.response" "$headers"
fi
tmp=$output.tmp.$$; trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
jq -cnS --arg image "$image" --arg hash "$config_hash" --arg health "$health" \
  --arg ms "$meetings_status" --arg as "$actuator_status" --argjson redirect "$redirect" \
  --argjson json "$json" '{schema:"meet-backend/test-vps-recovery-runtime/v1",healthy:true,
    runtime:{imageId:$image,configHash:$hash,health:$health,uploadsMount:"volume"},
    https:{meetingsStatus:$ms,actuatorStatus:$as,httpRedirectHttps:$redirect,meetingsJson:$json}}' >"$tmp"
chmod 600 "$tmp"; mv -f -- "$tmp" "$output"; trap - EXIT HUP INT TERM
