#!/usr/bin/env bash
set -euo pipefail
usage(){ echo "usage: $0 --root PATH --output PATH [--reference-list PATH]" >&2; exit 2; }
fail(){ echo "beta recovery media proof failed: $*" >&2; exit 1; }
root='' output='' references=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2;;
    --output) output=$2; shift 2;;
    --reference-list) references=$2; shift 2;;
    *) usage;;
  esac
done
[ -d "$root" ] && [ ! -L "$root" ] && [ -n "$output" ] || usage
root=${root%/}; [ "$root" != / ] || fail "unsafe uploads root"
parent=$(dirname -- "$output"); [ -d "$parent" ] && [ ! -L "$parent" ] || fail "unsafe output"
[ ! -e "$output" ] || fail "output already exists"
for tool in find sha256sum jq ln mktemp; do command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"; done
for top in avatars meetings communities; do
  [ -d "$root/$top" ] && [ ! -L "$root/$top" ] || fail "required uploads directory is absent"
done
[ -z "$references" ] || { [ -f "$references" ] && [ ! -L "$references" ]; } || fail "unsafe reference list"
tmp=$(mktemp -d); candidate=''; trap 'rm -f -- "${candidate:-}"; rm -r -- "$tmp"' EXIT HUP INT TERM
records=$tmp/records; : >"$records"
while IFS= read -r -d '' entry; do
  relative=${entry#"$root"/}
  case "$relative" in *$'\n'*|*$'\t'*|*\\*) fail "unsafe uploads path";; esac
  case "$relative" in avatars|avatars/*|meetings|meetings/*|communities|communities/*);; *) fail "unexpected uploads path";; esac
  [ ! -L "$entry" ] || fail "unsafe uploads entry"
  [ -f "$entry" ] || [ -d "$entry" ] || fail "unsupported uploads entry"
done < <(find "$root" -mindepth 1 -print0)
while IFS= read -r -d '' file; do
  [ -f "$file" ] && [ ! -L "$file" ] || fail "unsafe uploads entry"
  relative=${file#"$root"/}; size=$(wc -c <"$file" | tr -d '[:space:]'); digest=$(sha256sum -- "$file" | awk '{print $1}')
  [[ "$size" =~ ^[0-9]+$ && "$digest" =~ ^[0-9a-f]{64}$ ]] || fail "invalid file record"
  printf '%s\t%s\t%s\n' "$relative" "$size" "$digest" >>"$records"
done < <(LC_ALL=C find "$root" -type f -print0 | LC_ALL=C sort -z)
decimal_add(){
  local left=$1 right=$2 carry=0 result='' ld rd digit
  [[ "$left" =~ ^[0-9]+$ && "$right" =~ ^[0-9]+$ ]] || return 1
  while [ -n "$left" ] || [ -n "$right" ] || [ "$carry" -gt 0 ]; do
    ld=0; rd=0; [ -z "$left" ] || ld=${left: -1}; [ -z "$right" ] || rd=${right: -1}
    digit=$((10#$ld + 10#$rd + carry)); result=$((digit % 10))${result:-}; carry=$((digit / 10))
    [ -z "$left" ] || left=${left:0:${#left}-1}; [ -z "$right" ] || right=${right:0:${#right}-1}
  done
  while [ "${result#0}" != "$result" ]; do result=${result#0}; done
  printf '%s\n' "${result:-0}"
}
count=$(wc -l <"$records" | tr -d '[:space:]'); bytes=0
while IFS=$'\t' read -r _ size _; do bytes=$(decimal_add "$bytes" "$size") || fail "file-size overflow"; done <"$records"
aggregate=$(sha256sum -- "$records" | awk '{print $1}'); reference_count=0; references_resolved=true
if [ -n "$references" ]; then
  while IFS= read -r reference; do
    reference_count=$((reference_count + 1))
    [ -n "$reference" ] || { references_resolved=false; continue; }
    case "$reference" in avatars/*|meetings/*|communities/*);; /*|../*|*/../*|*'/..'|*\\*) references_resolved=false; continue;; *) references_resolved=false; continue;; esac
    [ -f "$root/$reference" ] && [ ! -L "$root/$reference" ] && [ -s "$root/$reference" ] ||
      references_resolved=false
  done <"$references"
fi
candidate=$(mktemp "$output.tmp.XXXXXX")
jq -cnS --arg digest "$aggregate" --argjson count "$count" --argjson bytes "$bytes" \
  --argjson refs "$reference_count" --argjson resolved "$references_resolved" \
  '{schema:"meet-backend/beta-recovery-media-proof/v1",files:$count,bytes:$bytes,canonicalDigest:$digest,referencesTotal:$refs,referencesResolved:$resolved}' >"$candidate"
chmod 600 "$candidate"; ln -- "$candidate" "$output" || fail "output publication failed"
rm -f -- "$candidate"; candidate=''; chmod 600 "$output"; trap - EXIT HUP INT TERM
