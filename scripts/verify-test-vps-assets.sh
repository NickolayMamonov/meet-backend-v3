#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --public-url https://host --output PATH" >&2
  exit 2
}

fail() {
  echo "test VPS frozen asset verification failed: $*" >&2
  exit 1
}

public_url=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --public-url) [ "$#" -ge 2 ] || usage; public_url=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$public_url" =~ ^https://[^/]+$ ]] || usage
[ -n "$output" ] || usage
[ ! -L "$output" ] || fail "output path is a symlink"
[ -d "$(dirname -- "$output")" ] || fail "output directory is unavailable"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

assets=(
  "demo-assets/v1/community-moscow.png:4cae7410a1e0c9e28491631a59df89b10776ced8e5250d91d01157d2adc158ac"
  "demo-assets/v1/community-walks.png:a4b90e77d01aa3387dfc72288d6565da8fa178730fac43441ac60262235c2ee6"
  "demo-assets/v1/community-online.png:cd0c606d0242e688279b02301e7606132f4493cab83a6a55c7ed164dd0e8ee0d"
  "demo-assets/v1/meeting-moscow.png:674bf6797c1227772bc19e1bca406de9853ca52112d3298cab9a67e84afb1439"
  "demo-assets/v1/meeting-online.png:43378f9e7900f83a0ba86d9244f6f10f09d2f291ce8561f51ddbec5b132e8f46"
  "demo-assets/v1/avatar-01.png:48b6c14991eddce94834bff01b7371d0de02c36ad136565e1a37d1171fc0cc40"
  "demo-assets/v1/avatar-02.png:06ec16e4bcfd833a15bc16fa8416610769be8a6a444743159626d8317fd94cf8"
  "demo-assets/v1/avatar-03.png:bfdd6f5ef6e3d5375d0c21cb7bc59a494f22f80628a35d5ae6c535f3ae5bd940"
  "demo-assets/v1/avatar-04.png:1b4a000feaf4fc4bd173590bf8811e8142d74f968f319b2cfb7022d11aae05a6"
  "demo-assets/v1/avatar-05.png:f820de837384b5068ca49147bfd7d228751445738d0f3f5e7bbafe8936f2a14b"
  "demo-assets/v1/avatar-06.png:ad80b8b4c46e0d30860b872c5a4e8ba557954f66830d3b302eb265521c6fcca2"
  "demo-events/organize-online:3229a94a4cc9698f5ed09320a80a68ec9b9746e5661a982b872d90157cba72b6"
  "demo-events/networking-online:5c7baf9641ba6b602444595199dff14c0cca31125ca3f666f5fd63b9766e0900"
)

temporary=$output.tmp.$$
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM
results=()
for entry in "${assets[@]}"; do
  path=${entry%%:*}
  expected=${entry##*:}
  file=$(mktemp)
  trap 'rm -f -- "$temporary" "$file"' EXIT HUP INT TERM
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    "$public_url/$path" -o "$file" || fail "asset retrieval failed: $path"
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "$expected" ] || fail "asset digest differs: $path"
  results+=("$(jq -cnS --arg path "$path" --arg digest "$actual" \
    '{path:$path,sha256:$digest}')")
  rm -f -- "$file"
done

jq -cnS --argjson count "${#assets[@]}" \
  --argjson assets "$(printf '%s\n' "${results[@]}" | jq -sS .)" \
  '{schema:"meet-backend/test-vps-frozen-assets/v1",count:$count,verified:true,assets:$assets}' \
  >"$temporary" || fail "asset evidence construction failed"
chmod 600 "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || fail "asset evidence publication failed"
trap - EXIT HUP INT TERM
