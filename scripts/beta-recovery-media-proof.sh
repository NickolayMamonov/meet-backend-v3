#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 --root PATH --output PATH [--reference-list PATH]" >&2; exit 2; }
fail(){ echo "beta recovery media proof failed: $*" >&2; exit 1; }
root='' output='' references=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] && [ -z "$root" ] || usage; root=$2; shift 2;;
    --output) [ "$#" -ge 2 ] && [ -z "$output" ] || usage; output=$2; shift 2;;
    --reference-list) [ "$#" -ge 2 ] && [ -z "$references" ] || usage; references=$2; shift 2;;
    *) usage;;
  esac
done
[ -d "$root" ] && [ ! -L "$root" ] && [ -n "$output" ] || usage
[ ! -L "$output" ] && [ -d "$(dirname -- "$output")" ] || fail "unsafe output"
for tool in find sha256sum jq; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
for top in avatars meetings communities; do
  [ -d "$root/$top" ] && [ ! -L "$root/$top" ] || fail "required uploads directory is absent"
done
[ -z "$references" ] || { [ -f "$references" ] && [ ! -L "$references" ]; } || fail "unsafe reference list"
tmp=$(mktemp -d); trap 'rm -r -- "$tmp"' EXIT HUP INT TERM
records=$tmp/records; : >"$records"
while IFS= read -r -d '' file; do
  [ -f "$file" ] && [ ! -L "$file" ] || fail "unsafe uploads entry"
  relative=${file#"$root"/}
  case "$relative" in avatars/*|meetings/*|communities/*) ;; *) fail "unexpected uploads path";; esac
  size=$(wc -c <"$file" | tr -d '[:space:]')
  digest=$(sha256sum -- "$file" | awk '{print $1}')
  [[ "$size" =~ ^[0-9]+$ ]] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid file record"
  printf '%s\t%s\t%s\n' "$relative" "$size" "$digest" >>"$records"
done < <(LC_ALL=C find "$root" -type f -print0 | LC_ALL=C sort -z)
count=$(wc -l <"$records" | tr -d '[:space:]')
bytes=$(awk -F '\t' '{sum += $2} END {print sum + 0}' "$records")
aggregate=$(sha256sum -- "$records" | awk '{print $1}')
reference_count=0; references_resolved=true
if [ -n "$references" ]; then
  while IFS= read -r reference; do
    [ -n "$reference" ] || continue
    reference_count=$((reference_count + 1))
    case "$reference" in avatars/*|meetings/*|communities/*) ;; *) references_resolved=false; continue;; esac
    [ -f "$root/$reference" ] && [ ! -L "$root/$reference" ] || references_resolved=false
  done <"$references"
fi
candidate=$output.tmp.$$; trap 'rm -f -- "$candidate"; rm -r -- "$tmp"' EXIT HUP INT TERM
jq -cnS --arg digest "$aggregate" --argjson count "$count" --argjson bytes "$bytes" \
  --argjson refs "$reference_count" --argjson resolved "$references_resolved" \
  '{schema:"meet-backend/beta-recovery-media-proof/v1",files:$count,bytes:$bytes,
    canonicalDigest:$digest,referencesTotal:$refs,referencesResolved:$resolved}' >"$candidate"
chmod 600 "$candidate"; mv -f -- "$candidate" "$output"; trap - EXIT HUP INT TERM
