# Production deployment

## Operator boundary and authentication configuration

Production email OTP is implemented and is selected with
`APP_EMAIL_PROVIDER=smtp`. The application requires a sender address, SMTP
host/port/username/password, bounded connect/read/write timeouts, and a current
OTP HMAC key. A previous HMAC key is optional for key rotation, but both of its
key-ring values must be supplied together when used. SMS remains disabled with
`APP_SMS_PROVIDER=disabled`; phone OTP is not a production delivery path.
Production release configuration uses these names:

```dotenv
APP_EMAIL_PROVIDER=smtp
APP_EMAIL_FROM=<sender-mailbox>
APP_EMAIL_FROM_NAME=Meet
SPRING_MAIL_HOST=<smtp-host>
SPRING_MAIL_PORT=587
SPRING_MAIL_USERNAME=<smtp-username>
SPRING_MAIL_PASSWORD=<smtp-password>
APP_EMAIL_CONNECT_TIMEOUT_MS=5000
APP_EMAIL_READ_TIMEOUT_MS=5000
APP_EMAIL_WRITE_TIMEOUT_MS=5000
APP_OTP_HMAC_CURRENT_KEY_ID=<current-key-id>
APP_OTP_HMAC_CURRENT_KEY_BASE64=<current-key-material-base64>
APP_OTP_HMAC_PREVIOUS_KEY_ID=<optional-previous-key-id>
APP_OTP_HMAC_PREVIOUS_KEY_BASE64=<optional-previous-key-material-base64>
APP_SMS_PROVIDER=disabled
```

Use placeholders only in this repository. The real SMTP credentials, HMAC
materials, JWT/database secrets, VPS/DNS/TLS/registry configuration, and the
production-release certification decision are separate operator work and must
not be inferred from or committed with this codebase.

All production Compose operations use `scripts/production-compose.sh`. It pins
`-p meet-production`, always reads `.env.production`, and removes shell values
that could override Compose interpolation. The Compose file explicitly names
`meet-production_postgres_data` and `meet-production_uploads_data`.

Run commands from the repository root on a Linux host with Docker Engine and
Compose, `age`, an off-host backup target, DNS, and a TLS reverse proxy. The
backend binds only to loopback; PostgreSQL is not published.

Immutable artifact publication is independent from VPS deployment. Follow
[`docs/operations/backend-release-publishing.md`](operations/backend-release-publishing.md)
to publish and verify a release before using the deployment steps below.

## 1. First installation

This is the only flow that creates `.env.production`; it fails if the file
already exists:

```bash
set -euo pipefail
test ! -e .env.production
(umask 077; set -o noclobber; command cat .env.production.example > .env.production)
chmod 600 .env.production
```

Edit durable configuration and secrets, including the SMTP and OTP settings
listed above, leaving `BACKEND_VERSION`, `BACKEND_IMAGE`, and
`BACKEND_REVISION` to the release updater. Then choose an immutable image and
exact source revision:

```bash
REVISION=<full-40-character-lowercase-git-sha>
IMAGE=registry.example/meet-backend:git-$REVISION
VERSION=<canonical-backend-semver>
scripts/update-production-release.sh "$IMAGE" "$REVISION" "$VERSION"
```

Build only from that clean revision:

```bash
set -euo pipefail
REVISION=$(sed -n 's/^BACKEND_REVISION=//p' .env.production)
IMAGE=$(sed -n 's/^BACKEND_IMAGE=//p' .env.production)
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]]
test -n "$IMAGE"
test -z "$(git status --porcelain --untracked-files=all)"
git fetch --prune origin
git checkout --detach "$REVISION"
test "$(git rev-parse HEAD)" = "$REVISION"
test -z "$(git status --porcelain --untracked-files=all)"
scripts/production-compose.sh config --quiet
scripts/production-compose.sh pull postgres
scripts/production-compose.sh build --pull backend
```

The image has OCI source/revision labels and fixed user `10001:10001`. Keep the
successful image-only smoke path:

```bash
set -euo pipefail
REVISION=$(sed -n 's/^BACKEND_REVISION=//p' .env.production)
IMAGE=$(sed -n 's/^BACKEND_IMAGE=//p' .env.production)
test "$(docker image inspect "$IMAGE" \
  --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}')" = "$REVISION"
test "$(docker image inspect "$IMAGE" --format '{{.Config.User}}')" = 10001:10001
docker run --rm --entrypoint sh "$IMAGE" -ec '
  test "$(id -u):$(id -g)" = 10001:10001
  test -r /app/app.jar
  java -version
'
```

With no existing production volumes or rollback state, deploy:

```bash
scripts/deploy-production-release.sh
```

## 2. Routine release

Never copy `.env.production.example` during an upgrade. Never combine a release
with configuration or credential changes.

1. Capture the exact running image, effective UID/GID, actual uploads mount, and
   a digest of every non-release `.env.production` field:

   ```bash
   scripts/prepare-production-release.sh
   ```

2. Create and verify a coordinated backup before changing release fields:

   ```bash
   AGE_RECIPIENT=age1replace-me \
   BACKUP_DIR=/var/backups/meet-production \
     scripts/backup-production.sh
   ```

   The backup script inspects the running backend and requires exactly one
   `/data/uploads` named-volume mount matching
   `meet-production_uploads_data`. It stops the backend, verifies that the
   discovered volume contains only the expected `avatars`, `meetings`, and
   `communities` archive roots, encrypts PostgreSQL and uploads, and restarts
   the exact same container.

3. Transfer only encrypted files off-host, then decrypt and validate them on the
   recovery host:

   ```bash
   rclone copy /var/backups/meet-production backup-remote:meet-production/ \
     --include '*.age' --checksum --immutable

   age --decrypt -i /secure/backup-identity postgres-selected.dump.age \
     | pg_restore --list >/dev/null
   age --decrypt -i /secure/backup-identity uploads-selected.tar.gz.age \
     | tar -tzf - >/dev/null
   ```

   Keep seven daily, five weekly, and twelve monthly verified recovery points as
   a starting policy. Never prune the last verified point; perform quarterly
   restore drills.

4. Update only immutable release identity; the updater proves the digest of all
   other env-file bytes is unchanged:

   ```bash
   REVISION=<new-full-git-sha>
   VERSION=<new-canonical-backend-semver>
   IMAGE=registry.example/meet-backend:git-$REVISION
   scripts/update-production-release.sh "$IMAGE" "$REVISION" "$VERSION"
   ```

5. Check out/build the exact revision as in section 1, then deploy:

   ```bash
   scripts/production-compose.sh config --quiet
   scripts/production-compose.sh build --pull backend
   scripts/deploy-production-release.sh
   ```

`deploy-production-release.sh` rejects non-release config drift, verifies the
image version/revision labels and fixed runtime identity, migrates an existing uploads volume to
`10001:10001`, removes any legacy rollback override, starts without implicit
pull/build, and checks readiness. Backend and PostgreSQL use bounded Docker
`local` logs (`10m` x five files by default).

## 3. Rollback

Only roll back when every applied Flyway migration is backward-compatible with
the captured image. Never edit applied migrations or `flyway_schema_history`;
restore PostgreSQL and uploads from one verified recovery point when a database
rollback is required.

For an unlabeled legacy image, supply its exact source revision while capturing
state:

```bash
LEGACY_PREVIOUS_REVISION=<full-40-character-lowercase-git-sha> \
LEGACY_PREVIOUS_VERSION=<legacy-canonical-backend-semver> \
  scripts/prepare-production-release.sh
```

After an unsuccessful candidate deployment:

```bash
scripts/rollback-production-release.sh
```

Rollback verifies the captured image ID, uploads volume, prior Compose files,
effective UID/GID, and non-release config digest. It restores the prior image
with the captured Compose/runtime definition while changing only
`BACKEND_IMAGE`, `BACKEND_VERSION`, and `BACKEND_REVISION`; current secrets remain in
`.env.production`. The protected `/var/lib/meet-production/active-*.yml` files
keep that exact runtime definition active. The next normal deployment removes
them and returns to the repository Compose file and `10001:10001`.

If credentials or any other config changed after release preparation, automatic
deploy and rollback intentionally abort. The scripts never copy an older secret
file over `.env.production`; preserve rotated credentials, explicitly verify the
old image is compatible with current config, and roll forward or prepare a new
release from that known-safe state.

## 4. Reverse proxy

The `prod` profile processes forwarded headers. The loopback proxy must discard
client-provided values and set authoritative peer and TLS values:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host api.example.com;
    proxy_set_header Forwarded "";
    proxy_set_header X-Forwarded-Prefix "";
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Host api.example.com;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Port 443;
}
```

Do not use `$proxy_add_x_forwarded_for` or trust arbitrary `real_ip_header`
peers. Trust only documented load-balancer CIDRs. OpenAPI and Swagger remain
disabled by default.

## 5. PostgreSQL initialization and password rotation

`DB_NAME`, `DB_USERNAME`, and `DB_PASSWORD` initialize PostgreSQL only when
`meet-production_postgres_data` is empty. Editing them later does not rename a
database or role and does not rotate the role password.

Do password rotation separately from a release. First run and verify the backup
flow in section 2. Then stop the backend and use PostgreSQL's hidden interactive
password prompt:

```bash
set -euo pipefail
scripts/production-compose.sh stop backend
scripts/production-compose.sh exec postgres sh -c \
  'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" --command="\password $POSTGRES_USER"'
```

Set `DB_PASSWORD` to that same value in `.env.production` without changing its
mode or any release field. The wrapper clears every exported `DB_*` and
`COMPOSE_*` shell override, then recreates only the backend from the single
production env source:

```bash
scripts/production-compose.sh up -d --no-deps --no-build --pull never \
  --force-recreate --wait --wait-timeout 180 backend
ADDRESS=$(scripts/production-compose.sh port backend 8080)
curl --fail "http://$ADDRESS/actuator/health/readiness"
```

If the values do not match, keep the backend stopped, rerun `\password`, update
the same env field, and retry. Never recreate the volume to rotate a password.
