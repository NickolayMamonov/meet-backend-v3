#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-immutable-policy-reader-credential.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
case "$(uname -s)" in
  MINGW*|MSYS*)
    echo "immutable policy reader credential fixtures require hosted POSIX curl path semantics"
    exit 0
    ;;
esac
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
    signing_input=$(cat)
    IFS=. read -r jwt_header jwt_payload jwt_extra <<<"$signing_input"
    [ -n "$jwt_header" ] && [ -n "$jwt_payload" ] && [ -z "${jwt_extra:-}" ]
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
authorization=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    --header)
      case "$2" in
        Authorization:*) authorization=${2#Authorization: } ;;
      esac
      shift 2
      ;;
    --connect-timeout|--max-time|--proto|--write-out)
      shift 2
      ;;
    --silent|--show-error|--tlsv1.2)
      shift
      ;;
    https://*) url=$1; shift ;;
    *) exit 91 ;;
  esac
done
if [[ "$authorization" == Bearer\ * ]]; then
  bearer=${authorization#Bearer }
  IFS=. read -r jwt_header jwt_payload jwt_signature jwt_extra <<<"$bearer"
  if [ -n "$jwt_header" ] && [ -n "$jwt_payload" ] &&
     [ -n "$jwt_signature" ] && [ -z "${jwt_extra:-}" ]; then
    jwt_segments=3
  else
    jwt_segments=invalid
  fi
else
  jwt_segments=none
fi
printf '%s %s jwt_segments=%s\n' "$method" "$url" "$jwt_segments" >>"$CURL_LOG"
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
    [ "$jwt_segments" = 3 ]
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
    [ "$jwt_segments" = 3 ]
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
    [ "$jwt_segments" = 3 ]
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
grep -Fx 'POST https://api.github.com/app/installations/42/access_tokens jwt_segments=3' \
  "$CURL_LOG" >/dev/null
grep -Fx 'GET https://api.github.com/app/installations jwt_segments=3' \
  "$CURL_LOG" >/dev/null
grep -Fx 'POST https://api.github.com/app/installations/42/access_tokens jwt_segments=3' \
  "$CURL_LOG" >/dev/null
! grep -Eq '^(PUT|PATCH|DELETE) ' "$CURL_LOG"
! grep -Fq 'fixture-installation-token' "$TMP/success.json"

case "$(uname -s)" in
  MINGW*|MSYS*)
    echo "additional credential path fixtures deferred on Windows Git Bash"
    ;;
  *)
    run_scenario metadata-missing >"$TMP/metadata-missing.json"
    jq -e '.permissions == {administration:"read",metadata:"read"}' \
      "$TMP/metadata-missing.json" >/dev/null

    printf '12345\n' >"$TMP/app-id"
    printf '%s\n%s\n' fixture-key fixture-key-continuation >"$TMP/private-key"
    CREDENTIAL_SCENARIO=success \
      EXPECT_MULTILINE_KEY=true \
      IMMUTABLE_POLICY_READER_APP_ID='' \
      IMMUTABLE_POLICY_READER_PRIVATE_KEY='' \
      "$VERIFY" --repository FixtureOwner/repo \
      --app-id-file "$TMP/app-id" \
      --private-key-file "$TMP/private-key" >"$TMP/file-input.json"
    jq -e '.permissions.administration == "read"' \
      "$TMP/file-input.json" >/dev/null
    if run_scenario extra-non-write >"$TMP/extra.out" 2>"$TMP/extra.err"; then
      echo "broader non-write permissions were incorrectly accepted" >&2
      exit 1
    fi
    [ ! -s "$TMP/extra.out" ]
    ! grep -Fq fixture-installation-token "$TMP/extra.err"

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

    for scenario in \
      issuance-failure \
      wrong-selection \
      token-wrong-repository \
      listing-wrong-repository \
      metadata-wrong-repository \
      administration-missing \
      administration-none \
      administration-write \
      metadata-none \
      other-write; do
      expect_failure "$scenario" run_scenario "$scenario"
    done
    ;;
esac

echo "immutable policy reader credential fixtures passed: compact JWT, implicit Metadata, and multiline PEM"
