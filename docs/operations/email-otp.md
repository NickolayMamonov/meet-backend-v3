# Email OTP operations

## Production prerequisites

Before enabling email OTP traffic:

1. Verify the exact `APP_EMAIL_FROM` mailbox/domain with the SMTP provider.
2. Publish and validate SPF and DKIM for the sending domain.
3. Publish DMARC in monitoring mode, review reports, then move to the approved enforcement policy.
4. Configure a controlled return path plus bounce, complaint, and suppression handling. Do not repeatedly send to
   suppressed recipients.
5. Store SMTP credentials and OTP HMAC keys in the deployment secret manager. Do not put them in YAML, Compose,
   shell history, tickets, or logs.
6. Configure `APP_HTTP_CLIENT_IP_TRUSTED_PROXY_CIDRS` only for controlled reverse proxies that overwrite
   `X-Forwarded-For`. Leave it empty for direct traffic.
7. Back up PostgreSQL and schedule the coordinated authentication cutover. Old binaries cannot run against the V6
   OTP schema.

## Required runtime configuration

Every profile set other than exactly `dev` or exactly `test`, including no active profile, is production:

- `APP_EMAIL_PROVIDER=smtp`
- `APP_EMAIL_FROM` and optional `APP_EMAIL_FROM_NAME`
- `SPRING_MAIL_HOST`, `SPRING_MAIL_PORT`, `SPRING_MAIL_USERNAME`, `SPRING_MAIL_PASSWORD`
- `APP_EMAIL_CONNECT_TIMEOUT_MS`, `APP_EMAIL_READ_TIMEOUT_MS`, `APP_EMAIL_WRITE_TIMEOUT_MS` (1,000–30,000)
- `APP_OTP_HMAC_CURRENT_KEY_ID`, `APP_OTP_HMAC_CURRENT_KEY_BASE64`
- optional paired `APP_OTP_HMAC_PREVIOUS_KEY_ID`, `APP_OTP_HMAC_PREVIOUS_KEY_BASE64`
- datasource and JWT settings documented in the README

SMTP authentication, STARTTLS enable+required, and certificate hostname verification are forced by the runtime.
Implicit SMTPS, JNDI mail sessions, startup connection tests, debug/trace output, trust-all settings, custom socket
factories, and unsafe TLS/auth/timeout overrides are rejected. Private CAs must be installed through an approved JVM
truststore.

`APP_EMAIL_FROM` must be one ASCII mailbox without display-name syntax. The application owns the fixed subject and
plain-text body.

## HMAC key generation and rotation

Generate at least 32 random bytes with an approved CSPRNG and Base64-encode the raw bytes. Use a 1–32 character key
ID containing only `A-Z`, `a-z`, `0-9`, `.`, `_`, `~`, or `-`. Never reuse JWT, database, SMTP, dev, or test secrets.

Two-phase rotation:

1. Deploy the future key throughout the fleet as the previous/accepted key while the old key remains current.
2. Confirm every instance accepts both key IDs.
3. Deploy the future key as current and retain the old key as previous.
4. Wait longer than the maximum OTP lifetime across the whole fleet.
5. Remove the old key.

Do not run a mixed fleet that lacks the same accepted key ring. For emergency one-step rotation, stop authentication
traffic and revoke active challenges during an approved maintenance window.

## Cutover and canary

1. Confirm DNS, provider verification, return path, suppression handling, credentials, proxy CIDRs, and key ring.
2. Back up PostgreSQL and stop all old application instances/profile writers.
3. Deploy one artifact and apply V6.
4. Start all instances with identical key-ring configuration.
5. Run a controlled send/verify canary, then refresh and logout.
6. Inspect safe operational outcomes and provider dashboards; never search logs by recipient, code, key ID,
   message ID, payload, credential, or provider exception text.
7. Re-enable public traffic only after phone compatibility and the email canary pass.

## Diagnostics and rollback

Allowed application diagnostics are provider kind, operation, latency, safe outcome category, and numeric counters.
Do not enable Jakarta Mail debug/trace. Recipient addresses, OTPs, key IDs/material, credentials, headers, bodies,
message IDs, and provider exception text are prohibited in logs and public errors.

Before public traffic resumes, rollback may restore the pre-cutover database and old artifact. After post-cutover
writes exist, use a forward-fix migration unless an authorized recovery owner accepts the selected restore point and
its data loss. Never recreate plaintext OTP storage.
