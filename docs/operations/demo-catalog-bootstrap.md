# Demo catalog bootstrap runbook

MEE2-50 adds an operator-triggered, disabled-by-default catalog bootstrap.
The reviewed catalog is `closed-beta-demo`, manifest `2026-08-15.v1`, and the
schema change is additive migration V9. The endpoint is available only when
`DEMO_CATALOG_BOOTSTRAP_ENABLED=true`; it never runs at startup.

## Release boundary

1. Retarget and build an artifact descended from
   `27399202b2a9e92d2816749e12965a9f5368b5b3`. Confirm V9 is the next migration
   after V8 and that production Flyway still uses only `classpath:db/migration`.
2. Inspect table sizes before applying V9. The five partial unique indexes can
   briefly lock writes; schedule a maintenance window when required.
3. Take a verified backup. MEE2-52 owns proof that the backup can be restored.
4. Deploy with `DEMO_CATALOG_BOOTSTRAP_ENABLED=false`. Verify readiness, missing
   or wrong `X-Admin-Key` returns 403, and an authenticated admin receives the
   existing 404 envelope for `/admin/demo-catalog/bootstrap`.
5. Verify the exact thirteen static resources and their SHA-256 values from
   `docs/plans/MEE2-50-public-artifact-v1.md`. The exact-host HTTPS probe runs
   only after this disabled deployment.

## Controlled invocation

The host allowlist is a comma-separated, non-secret value:

```sh
export DEMO_CATALOG_ALLOWED_MEDIA_HOSTS='api.whysoezzy.online'
export DEMO_CATALOG_BOOTSTRAP_ENABLED='true'
export BASE_URL='https://beta.example.invalid'
export SCHEDULE_ANCHOR_DATE='REVIEWED-YYYY-MM-DD'
export CATALOG_VALID_THROUGH='REVIEWED-UTC-INSTANT'
read -r -s ADMIN_API_KEY

curl --fail-with-body --silent --show-error \
  -H "X-Admin-Key: ${ADMIN_API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "{\"scheduleAnchorDate\":\"${SCHEDULE_ANCHOR_DATE}\",\"catalogValidThrough\":\"${CATALOG_VALID_THROUGH}\",\"confirmReschedule\":false}" \
  "${BASE_URL}/admin/demo-catalog/bootstrap"
```

Use an explicitly reviewed ISO date and UTC validity instant. The service does
not calculate a new schedule from current time. Starts must be strictly after
both the injected/current server time and the supplied validity boundary.

Save only the safe response summary. Compare owned logical keys, generated IDs,
meeting schedule fields, aggregate counts, and the single
`demo_catalog_state` row. Do not print synthetic emails, phones, auth
identifiers, admin keys, tokens, or database credentials.

Invoke the exact request twice. The second response must classify all roots and
relationships as unchanged, preserving generated IDs and schedule values.
After a supported scalar or owned-edge repair, invoke again and verify only the
owned state changes. Real/shared tags, real users, MANUAL meetings, TIMEPAD
meetings, subscriptions, and participants remain intact. No auth identity,
refresh-token, OTP, social, password, or provider-token row is created.

After verification, set `DEMO_CATALOG_BOOTSTRAP_ENABLED=false` and restart.
The authenticated admin endpoint returns 404 while public catalog content
remains readable. MEE2-50 must not invoke production bootstrap before MEE2-52
restore proof passes. There is no application delete operation; data removal
uses the verified backup restore path.
