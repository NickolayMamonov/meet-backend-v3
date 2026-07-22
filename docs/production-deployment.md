# Production deployment (Linux VPS + Docker Compose)

## 1. Server prerequisites

- Docker Engine with the Compose plugin
- a DNS record pointing the API hostname to the VPS
- a TLS-terminating reverse proxy such as Caddy or Nginx
- a backup destination outside this VPS

The Compose stack binds the backend only to `127.0.0.1`. Publish it through the
reverse proxy; do not expose PostgreSQL directly.

## 2. Configure secrets

```bash
cp .env.production.example .env.production
chmod 600 .env.production
openssl rand -base64 48
```

Put the generated value in `APP_JWT_SECRET`, replace the database password, and
set `APP_STORAGE_BASE_URL` to the public HTTPS media URL.

Keep `.env.production` only on the server. It is ignored by Git.

## 3. Validate and start

Always pass the production env file to Compose because it is also used for
Compose variable interpolation:

```bash
docker compose --env-file .env.production -f docker-compose.production.yml config --quiet
docker compose --env-file .env.production -f docker-compose.production.yml build
docker compose --env-file .env.production -f docker-compose.production.yml \
  up -d --wait --wait-timeout 180
docker compose --env-file .env.production -f docker-compose.production.yml ps
```

Flyway applies pending migrations while the backend starts. Compose waits for
PostgreSQL to become healthy before starting the backend.

## 4. Reverse proxy

Proxy the public HTTPS hostname to `http://127.0.0.1:8080` and preserve
`X-Forwarded-For`, `X-Forwarded-Host`, and `X-Forwarded-Proto`. The `prod`
profile enables framework handling of forwarded headers.

After TLS is configured:

```bash
curl --fail https://api.example.com/actuator/health/readiness
```

Only health probes are public. Swagger and OpenAPI are disabled by default in
the `prod` profile.

## 5. Persistent data and backups

The named volumes contain:

- `meet-production_postgres_data`: PostgreSQL data
- `meet-production_uploads_data`: uploaded media

Back up both. A database dump alone does not include uploaded avatars or cover
images.

`BACKEND_MEMORY_LIMIT` bounds the container memory used by the JVM. The default
is `768m`; tune it together with PostgreSQL and OS capacity for the actual VPS.

Example logical database backup:

```bash
docker compose --env-file .env.production -f docker-compose.production.yml \
  exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' \
  > meet-$(date +%F).sql
```

Test restore procedures before launch.

## 6. Updates and rollback

```bash
git pull --ff-only
docker compose --env-file .env.production -f docker-compose.production.yml build
docker compose --env-file .env.production -f docker-compose.production.yml \
  up -d --wait --wait-timeout 180
```

Do not delete the named volumes during an update. Database migrations must be
reviewed for backward compatibility before rolling an application image back.

## Known launch limitation

Production OTP delivery is disabled (`APP_SMS_PROVIDER=disabled`). The current
fake provider is restricted to the `dev` profile. Email OTP is tracked as a
separate product task and must be completed before end users can sign in.
