#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-immutable-policy-reader-credential.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/bin"

cat >"$TMP/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  pkey)
    if [ "${EXPECT_MULTILINE_KEY:-false}" = true ]; then
      key_file=
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -in) key_file=$2; shift 2 ;;
          *) shift ;;
        esac
      done
      grep -Fx fixture-key-continuation "$key_file" >/dev/null
    fi
    exit 0
    ;;
  dgst)
    cat >/dev/null
    printf 'fixture-signature'
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=
output=
data=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    --header|--connect-timeout|--max-time|--proto|--write-out)
      shift 2
      ;;
    --silent|--show-error|--tlsv1.2)
      shift
      ;;
    https://*) url=$1; shift ;;
    *) exit 91 ;;
  esac
done

printf '%s %s\n' "$method" "$url" >>"$CURL_LOG"
scenario=${CREDENTIAL_SCENARIO:-success}
permissions='{"administration":"read","metadata":"read"}'
case "$scenario" in
  extra-non-write)
    permissions='{"administration":"read","metadata":"read","contents":"read","issues":"none"}'
    ;;
  administration-missing) permissions='{"metadata":"read"}' ;;
  administration-none) permissions='{"administration":"none","metadata":"read"}' ;;
  administration-write) permissions='{"administration":"write","metadata":"read"}' ;;
  metadata-missing) permissions='{"administration":"read"}' ;;
  metadata-none) permissions='{"administration":"read","metadata":"none"}' ;;
  other-write)
    permissions='{"administration":"read","metadata":"read","contents":"write"}'
    ;;
esac

case "$method $url" in
  "GET https://api.github.com/app/installations")
    jq -cn --argjson permissions "$permissions" '
      [{
        id:42,
        account:{login:"FixtureOwner"},
        repository_selection:"selected",
        permissions:$permissions
      }]
    ' >"$output"
    printf '200'
    ;;
  "GET https://api.github.com/app/installations/42")
    selection=selected
    [ "$scenario" != wrong-selection ] || selection=all
    jq -cn \
      --arg selection "$selection" \
      --argjson permissions "$permissions" '
        {
          id:42,
          account:{login:"FixtureOwner"},
          repository_selection:$selection,
          permissions:$permissions
        }
      ' >"$output"
    printf '200'
    ;;
  "POST https://api.github.com/app/installations/42/access_tokens")
    case "$data" in
      @*) ;;
      *) exit 92 ;;
    esac
    jq -e '.repositories == ["repo"]' "${data#@}" >/dev/null
    jq -e '.permissions.administration == "read"' "${data#@}" >/dev/null
    if [ "$scenario" = issuance-failure ]; then
      printf '{"message":"denied"}' >"$output"
      printf '403'
      exit 0
    fi
    selected=FixtureOwner/repo
    [ "$scenario" != token-wrong-repository ] ||
      selected=FixtureOwner/other
    jq -cn \
      --arg selected "$selected" \
      --argjson permissions "$permissions" '
        {
          token:"fixture-installation-token",
          expires_at:"2026-08-14T21:30:00Z",
          permissions:$permissions,
          repositories:[{id:99,full_name:$selected}]
        }
      ' >"$output"
    printf '201'
    ;;
  "GET https://api.github.com/installation/repositories?per_page=100")
    selected=FixtureOwner/repo
    [ "$scenario" != listing-wrong-repository ] ||
      selected=FixtureOwner/other
    jq -cn --arg selected "$selected" '
      {total_count:1,repositories:[{id:99,full_name:$selected}]}
    ' >"$output"
    printf '200'
    ;;
  "GET https://api.github.com/repos/FixtureOwner/repo")
    full_name=FixtureOwner/repo
    name=repo
    [ "$scenario" != metadata-wrong-repository ] || {
      full_name=FixtureOwner/other
      name=other
    }
    jq -cn --arg full_name "$full_name" --arg name "$name" '
      {
        id:99,
        full_name:$full_name,
        name:$name,
        owner:{login:"FixtureOwner"}
      }
    ' >"$output"
    printf '200'
    ;;
  *)
    exit 93
    ;;
esac
EOF
chmod +x "$TMP/bin/openssl" "$TMP/bin/curl"

export PATH="$TMP/bin:$PATH"
export CURL_LOG=$TMP/curl.log

expect_failure() {
  local marker=$1
  shift
  : >"$CURL_LOG"
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "expected credential rejection: $marker" >&2
    exit 1
  fi
  [ ! -s "$TMP/stdout" ] || {
    echo "credential rejection emitted stdout: $marker" >&2
    exit 1
  }
  [ -s "$TMP/stderr" ] || {
    echo "credential rejection omitted its safe error: $marker" >&2
    exit 1
  }
  ! grep -Fq 'fixture-installation-token' "$TMP/stderr" || {
    echo "credential rejection leaked token material: $marker" >&2
    exit 1
  }
}

run_scenario() {
  local scenario=$1
  shift
  CREDENTIAL_SCENARIO=$scenario \
    IMMUTABLE_POLICY_READER_APP_ID=12345 \
    IMMUTABLE_POLICY_READER_PRIVATE_KEY=fixture-key \
    "$VERIFY" --repository FixtureOwner/repo "$@"
}

: >"$CURL_LOG"
run_scenario success >"$TMP/success.json"
jq -e '
  . == {
    repository:"FixtureOwner/repo",
    repositorySelection:"selected",
    permissions:{administration:"read",metadata:"read"}
  }
' "$TMP/success.json" >/dev/null
[ "$(wc -l <"$CURL_LOG" | tr -d '[:space:]')" -eq 5 ]
grep -Fx 'POST https://api.github.com/app/installations/42/access_tokens' \
  "$CURL_LOG" >/dev/null
! grep -Eq '^(PUT|PATCH|DELETE) ' "$CURL_LOG"
! grep -Fq 'fixture-installation-token' "$TMP/success.json"

: >"$CURL_LOG"
run_scenario extra-non-write >"$TMP/extra-non-write.json"
jq -e '
  .permissions == {
    administration:"read",
    contents:"read",
    issues:"none",
    metadata:"read"
  }
' "$TMP/extra-non-write.json" >/dev/null

printf '12345\n' >"$TMP/app-id"
printf '%s\n%s\n' fixture-key fixture-key-continuation >"$TMP/private-key"
: >"$CURL_LOG"
CREDENTIAL_SCENARIO=success \
  EXPECT_MULTILINE_KEY=true \
  IMMUTABLE_POLICY_READER_APP_ID='' \
  IMMUTABLE_POLICY_READER_PRIVATE_KEY='' \
  "$VERIFY" --repository FixtureOwner/repo \
  --app-id-file "$TMP/app-id" \
  --private-key-file "$TMP/private-key" >"$TMP/file-input.json"
jq -e '.permissions.administration == "read"' \
  "$TMP/file-input.json" >/dev/null

: >"$CURL_LOG"
run_scenario success \
  --token-file "$TMP/token" \
  --output "$TMP/credential-proof.json" >"$TMP/output-mode.stdout"
[ ! -s "$TMP/output-mode.stdout" ]
[ "$(cat "$TMP/token")" = fixture-installation-token ]
jq -e '
  .schema == "meet-backend/immutable-policy-reader-credential/v1" and
  .repository == "FixtureOwner/repo" and
  .permissions == {administration:"read",metadata:"read"} and
  .configurableWritePermissions == []
' "$TMP/credential-proof.json" >/dev/null
! grep -Fq fixture-installation-token "$TMP/credential-proof.json"

expect_failure missing-app-id \
  env -u IMMUTABLE_POLICY_READER_APP_ID \
  IMMUTABLE_POLICY_READER_PRIVATE_KEY=fixture-key \
  "$VERIFY" --repository FixtureOwner/repo
[ ! -s "$CURL_LOG" ]

expect_failure missing-private-key \
  env -u IMMUTABLE_POLICY_READER_PRIVATE_KEY \
  IMMUTABLE_POLICY_READER_APP_ID=12345 \
  "$VERIFY" --repository FixtureOwner/repo
[ ! -s "$CURL_LOG" ]

for scenario in \
  issuance-failure \
  wrong-selection \
  token-wrong-repository \
  listing-wrong-repository \
  metadata-wrong-repository \
  administration-missing \
  administration-none \
  administration-write \
  metadata-missing \
  metadata-none \
  other-write; do
  expect_failure "$scenario" run_scenario "$scenario"
done

for method in PUT PATCH DELETE; do
  : >"$CURL_LOG"
  if (
    # shellcheck source=verify-immutable-policy-reader-credential.sh
    # shellcheck disable=SC1090
    source "$VERIFY"
    api_request "$method" https://api.github.com/forbidden \
      'Bearer fixture' "$TMP/forbidden.json"
  ) >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "expected local $method rejection" >&2
    exit 1
  fi
  [ ! -s "$CURL_LOG" ] || {
    echo "$method reached transport" >&2
    exit 1
  }
done

echo "immutable policy reader credential fixtures passed: env/file inputs, issuance, exact repository, least privilege, safe output, and local method rejection"
