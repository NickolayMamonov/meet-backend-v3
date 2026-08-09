#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

test -f .env.production || {
  echo ".env.production is required; initialize it only on first install" >&2
  exit 1
}

if grep -Eq '\$[{A-Za-z_]' .env.production; then
  echo ".env.production must contain literal values, not shell interpolation" >&2
  exit 1
fi
while IFS= read -r VARIABLE; do
  case "$VARIABLE" in
    COMPOSE_*|DB_*|BACKEND_*) unset "$VARIABLE" ;;
  esac
done < <(compgen -e)
unset PRODUCTION_ENV_FILE
unset APP_PORT BACKEND_MEMORY_LIMIT DOCKER_LOG_MAX_SIZE DOCKER_LOG_MAX_FILE
unset APP_JWT_SECRET APP_STORAGE_UPLOAD_DIR APP_STORAGE_BASE_URL
unset ADMIN_API_KEY APP_SMS_PROVIDER APP_EMAIL_PROVIDER APP_EMAIL_FROM APP_EMAIL_FROM_NAME
unset APP_EMAIL_CONNECT_TIMEOUT_MS APP_EMAIL_READ_TIMEOUT_MS APP_EMAIL_WRITE_TIMEOUT_MS
unset APP_OTP_HMAC_CURRENT_KEY_ID APP_OTP_HMAC_CURRENT_KEY_BASE64 APP_OTP_HMAC_PREVIOUS_KEY_ID APP_OTP_HMAC_PREVIOUS_KEY_BASE64
unset SPRING_MAIL_HOST SPRING_MAIL_PORT SPRING_MAIL_USERNAME SPRING_MAIL_PASSWORD
unset APP_HTTP_CLIENT_IP_TRUSTED_PROXY_CIDRS APP_HTTP_CLIENT_IP_MAX_FORWARDED_HOPS
unset INGESTION_ENABLED INGESTION_CRON INGESTION_ZONE GEOCODER_ENABLED LOCATIONIQ_KEY
unset TIMEPAD_ENABLED TIMEPAD_TOKEN TIMEPAD_CATEGORY_IDS TIMEPAD_KEYWORDS TIMEPAD_CITIES
unset SPRINGDOC_API_DOCS_ENABLED SPRINGDOC_SWAGGER_UI_ENABLED

STATE_DIR=/var/lib/meet-production
if [ "${1:-}" = --captured-runtime ]; then
  shift
  BASE_COMPOSE="$STATE_DIR/previous-compose.yml"
  RUNTIME_OVERRIDE="$STATE_DIR/previous-runtime.override.yml"
  test -s "$BASE_COMPOSE" && test -s "$RUNTIME_OVERRIDE" || {
    echo "captured runtime Compose files are incomplete" >&2
    exit 1
  }
else
  BASE_COMPOSE=docker-compose.production.yml
  [ ! -s "$STATE_DIR/active-compose.yml" ] || \
    BASE_COMPOSE="$STATE_DIR/active-compose.yml"
  RUNTIME_OVERRIDE="$STATE_DIR/active-runtime.override.yml"
fi

COMPOSE_FILES=(-f "$BASE_COMPOSE")
if [ -s "$RUNTIME_OVERRIDE" ]; then
  COMPOSE_FILES+=(-f "$RUNTIME_OVERRIDE")
fi

exec docker compose -p meet-production --project-directory "$ROOT_DIR" \
  --env-file .env.production \
  "${COMPOSE_FILES[@]}" "$@"
