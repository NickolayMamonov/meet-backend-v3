## Design result

**MEE2-23 — Email OTP backend**

Status: approved by independent plan and compliance review; proposed X-013 contract pending workflow product
approval.

## Design checklist

- [x] Preserve the existing Android phone-auth contract.
- [x] Define additive email OTP request, verification, success, and error contracts.
- [x] Define account-enumeration-safe behavior and email normalization.
- [x] Define user identity and monotonic migration behavior.
- [x] Define OTP hashing, expiry, attempt limits, locking, single use, and replay protection.
- [x] Define rate-limit subjects and the optional device identifier contract.
- [x] Define delivery ordering and provider failure behavior.
- [x] Define production provider configuration and fail-fast startup.
- [x] Define observability, deliverability prerequisites, tests, rollout, and non-goals.
- [x] Incorporate independent plan and compliance review.
- [x] Publish the `Design result` task comment and complete the workflow node.

## Decision summary

Add dedicated email endpoints and DTOs instead of making the existing phone fields polymorphic. Keep
`POST /auth/send-otp` and `POST /auth/verify-otp` unchanged for Android compatibility. The new flow uses a
canonical email identity, a dedicated email delivery boundary, HMAC-hashed OTP challenges, transactional
verification under a database lock, and the existing token issuance/rotation/invalidation path.

Use an `auth_identities` table as the authoritative mapping from a normalized login identifier to a user.
This avoids turning the editable, historically unverified `users.email` profile field into an implicitly verified
credential. Existing phone identities are backfilled. Existing profile emails are deliberately not backfilled or
auto-linked; without independent verification provenance, doing so could let the current owner of a stale,
mistyped, or reassigned mailbox authenticate into another user's account. Existing phone users and endpoints
remain supported.

Use a provider-neutral SMTP production adapter. SMTP credentials, sender identity, and all OTP hashing secrets
come only from environment variables or a secret manager. Every profile except explicit `dev` and `test`,
including the default profile, requires the SMTP adapter and fails before infrastructure bean creation when
required settings are absent.

## Proposed MEE2-23 / X-013 API contract

No authoritative X-013 artifact exists in the repository or linked task records. The paths, statuses, bodies,
errors, device header, and new-user behavior below are the proposed contract submitted by this Design node for
workflow/product approval. Implementation must not begin until that approval records this section as X-013.

### Request an email OTP

`POST /auth/email/send-otp`

Optional header:

- `X-Device-Id`: an opaque installation identifier generated and persisted by the Android app. When present it
  must be 16–128 ASCII characters from `[A-Za-z0-9._~-]`. It is never returned or logged. User-Agent is not a
  device identifier.

Request:

```json
{
  "email": "person@example.com"
}
```

Validation and normalization:

- `email` is required and is processed only by a shared `EmailAddressNormalizer` value-object factory.
- Canonicalization is Java 21 `String.strip()` (only leading/trailing code points for which
  `Character.isWhitespace(int)` is true) → NFC → split on exactly one `@` → lowercase the ASCII local part with
  `Locale.ROOT` → convert the domain with
  `IDN.toASCII(domain, IDN.USE_STD3_ASCII_RULES)` → lowercase the ASCII domain → final validation.
- The local part is a 1–64 character ASCII dot-atom matching
  ``[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*``.
  Quoted local parts and SMTPUTF8/non-ASCII local parts are rejected.
- Before IDNA conversion, leading/trailing dots and empty domain labels are rejected. After conversion the domain
  must have at least two labels, total at most 253 characters, with every 1–63 character label matching
  `[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?`. A trailing root dot and single-label domains are rejected.
- The final canonical address is at most 254 ASCII characters.
- The exact canonical value is used for identity lookup, rate limiting, delivery, and persistence.
- Provider-specific alias rules are not applied: dots and `+tag` segments are preserved.
- Malformed input is rejected before delivery and does not create an OTP challenge.

Validation messages are part of the proposed contract:

- missing/blank email: `Email is required`;
- malformed, unsupported, or noncanonicalizable email: `Email must be valid`;
- canonical email over 254 characters: `Email must not exceed 254 characters`;
- malformed device header: `X-Device-Id must be 16 to 128 safe ASCII characters`;
- malformed verification code: existing `OTP code must be a six-digit number`;
- name/surname limits retain their existing messages.

Successful response:

- Status: `202 Accepted`.
- Body:

```json
{
  "message": "If the address can receive email, a verification code will be sent."
}
```

The service does not query account existence in this flow. Existing accounts, new accounts, and restored
accounts therefore execute the same delivery path and receive the same response shape.

Errors retain the existing `ApiError` envelope:

| Status | `code` | Stable public message | Condition |
| --- | --- | --- | --- |
| 400 | `BAD_REQUEST` | Validation-specific, without echoing the email | Missing/invalid email or malformed device ID |
| 429 | `OTP_RATE_LIMITED` | `Too many OTP requests. Please try again later.` | Any email, IP, or enabled device quota is exhausted |
| 503 | `OTP_DELIVERY_UNAVAILABLE` | `OTP delivery is temporarily unavailable.` | Email provider is disabled, rejects synchronously, times out, or is unavailable |
| 503 | `OTP_ACTIVATION_UNAVAILABLE` | `OTP is temporarily unavailable. Please request a new code.` | Provider accepted the message but the database could not activate the challenge |

Provider-specific errors, suppression reasons, credentials, payloads, and recipient values never cross the API
boundary. No usable OTP is persisted when delivery fails synchronously; a HMAC-only pending row may be marked
`DELIVERY_FAILED` for bounded cleanup. Activation failure leaves no new usable challenge, preserves the prior
active challenge, and returns no `Retry-After`.
Email 429 and 503 responses also omit `Retry-After` because the system cannot currently calculate truthful
per-subject retry timing.

### Verify an email OTP

`POST /auth/email/verify-otp`

Request:

```json
{
  "email": "person@example.com",
  "code": "123456",
  "name": "Optional for a new user",
  "surname": "Optional for a new user"
}
```

`email` uses the same normalization contract as the request endpoint. `code` is exactly six ASCII digits.
`name` and `surname` preserve the existing optional, 100-character behavior.

Successful response:

- Status: `200 OK`.
- Body remains the existing `AuthResponse` contract with `accessToken`, `refreshToken`, `isNewUser`, and `user`.
- For a newly created email-only user, `user.email` is the canonical email and `user.phone` is `null`.
- Existing email identities return the mapped user; a soft-deleted user is restored exactly as in phone auth.
- If the address appears only in an existing user's unverified profile field, it does not identify that account:
  verification creates a separate email-auth user and returns `isNewUser=true`.

Errors:

| Status | `code` | Stable public message | Condition |
| --- | --- | --- | --- |
| 400 | `BAD_REQUEST` | Validation-specific, without echoing the email or code | Malformed request |
| 401 | `OTP_INVALID_OR_EXPIRED` | `Invalid or expired OTP code.` | Unknown challenge, wrong code, expired code, used code, replay, or attempt limit exhausted |

All verification failures intentionally share one status, code, and message. Verification only looks up or
creates a user after a valid challenge has been consumed, so unauthenticated callers cannot distinguish new,
existing, or deleted accounts.

### Existing phone contract

Both `PHONE` and `EMAIL` must use the new challenge representation, HMAC verification, attempt limits, row
locking, auth identities, single-use consumption, and replay protection. Email-specific exceptions remain
separate, and the following Android-visible phone wire matrix is frozen:

| Flow | Existing contract to preserve |
| --- | --- |
| Send request | `POST /auth/send-otp`; body has required E.164 `phone`; invalid format is `400 BAD_REQUEST` with `Phone must be in E.164 format` |
| Send success | `200 OK` with exact body `{"message":"OTP sent successfully"}` |
| Send throttled | `429 RATE_LIMITED` with `Too many OTP requests. Please try again later.` and no `Retry-After` |
| SMS disabled | `503 SMS_UNAVAILABLE` with `SMS delivery is not configured` |
| Verify request | `POST /auth/verify-otp`; body has `phone`, six-digit `code`, optional `name`, optional `surname`; existing validation messages remain |
| Invalid verify | `401 UNAUTHORIZED` with `Invalid or expired OTP code` for wrong, expired, used, or replayed phone codes |
| Verify success | Existing `AuthResponse` shape and `isNewUser` semantics |
| JWT | Phone-auth access tokens retain the existing `phone` claim plus `sub` and `av` |
| Session lifecycle | Existing refresh rotation, logout, profile access, deletion, soft-delete restore, and auth-version invalidation |

Exact MVC and PostgreSQL integration tests freeze this matrix. No phone endpoint, field, status, public message,
code, or existing header behavior changes as a side effect of the email implementation. The request and verify
endpoints accept the optional additive `X-Device-Id`; when absent, no device quota is claimed. User-Agent is no
longer treated as a device identifier.

This design deliberately changes phone security sequences while preserving that wire contract:

- only the latest successfully activated phone challenge is usable, so a resend supersedes older codes;
- five failed verification attempts across resends in the verification window exhaust the shared identifier
  budget, so a later correct code waits for the window to clear;
- one successful verification consumes the active challenge and replay remains a 401.

Those changes are required to add attempt limits and deterministic replay protection to the unified store and are
submitted for product approval with this design. Sequence-level tests cover resend, concurrent requests,
superseded codes, exhaustion, success, and post-success replay.

## Application flow

### Request flow

1. The controller validates the email body and optional `X-Device-Id`, asks `ClientIpResolver` for an
   authoritative normalized IP, and creates an `OtpRequestContext(clientIp, deviceId)`.
2. `EmailAddressNormalizer` produces the canonical email. No full email is logged.
3. `OtpRateLimiter` commits request claims in its existing `REQUIRES_NEW` transaction before delivery:
   `email`, `ip`, and optional `device` scopes. Subject values are SHA-256 hashes.
4. `AuthService` creates a six-digit code with the existing process-wide `SecureRandom`, a random per-challenge
   salt, and an HMAC-SHA-256 code hash using a dedicated OTP hashing secret.
5. A short database transaction takes the shared channel+identifier advisory lock and inserts the HMAC-only
   challenge as `PENDING`, with `created_at = CURRENT_TIMESTAMP` and
   `expires_at = CURRENT_TIMESTAMP + configured lifetime`. Its generated ID is the per-identifier request ordering
   key. `PENDING` is never usable, and the current `ACTIVE` challenge remains active.
6. `EmailOtpSender` sends the raw code outside a database transaction. The raw code exists only in memory and in
   the outbound message.
7. On synchronous provider failure, a compensation transaction changes `PENDING` to `DELIVERY_FAILED`; if that
   compensation itself fails, `PENDING` still remains unusable. The prior `ACTIVE` challenge is unchanged and the
   API returns `503 OTP_DELIVERY_UNAVAILABLE`.
8. On provider acceptance, an activation transaction takes the same advisory lock. If this row has the greatest
   challenge ID for the channel+identifier and its `expires_at` is after PostgreSQL `CURRENT_TIMESTAMP`, it changes
   the prior `ACTIVE` row to `SUPERSEDED` and this row to `ACTIVE`. If a newer request row exists, this row becomes
   `SUPERSEDED` and the request still returns 202. If it has expired, it becomes `EXPIRED`, the prior active row is
   preserved, and the API returns `503 OTP_ACTIVATION_UNAVAILABLE`.
9. If activation fails, this row remains `PENDING`, no new challenge is usable, prior `ACTIVE` remains valid, and
   the API returns `503 OTP_ACTIVATION_UNAVAILABLE`.

Do not keep a database transaction or row lock open during the network call. Provider acceptance means the
provider accepted the message; asynchronous bounce or mailbox delivery cannot be made atomic with PostgreSQL.

At most one challenge per channel+identifier is `ACTIVE`. Request order, not SMTP completion order, decides which
request may activate: an older slow provider call can never supersede a newer request. While a newer request is
pending, the prior active code remains usable; provider failure also preserves it. A unique partial index on
`(channel, identifier) WHERE status = 'ACTIVE'` enforces the invariant.

Request quotas use the existing 60-minute window: five per canonical email, twenty per normalized IP, and ten
per device when device limiting is enabled. Provider and activation failures still consume the already-committed
request claims; otherwise attackers could bypass quotas by inducing downstream failures.

### Verification flow

1. Normalize the email and resolve the same IP/device request context used by send. A separate proxied
   `OtpVerificationExecutor` starts the transaction and takes the channel+identifier PostgreSQL advisory lock.
2. `OtpVerificationLimiter` checks the normalized IP and optional device budgets: fifty and ten failed submissions
   per 15 minutes. Subjects are hashed and concurrency-safe. Exhaustion returns `VerificationOutcome.Invalid`
   with the same public 401, never 429.
3. Lock the single `ACTIVE`, non-exhausted challenge with `PESSIMISTIC_WRITE` and determine expiry using
   PostgreSQL `CURRENT_TIMESTAMP`, the same clock source used during activation.
4. If an active unexpired challenge exists, check its identifier-wide failed-attempt budget before evaluating the
   submitted code. An exhausted budget returns committed `VerificationOutcome.Invalid` without consuming the
   challenge or issuing tokens, so a resend cannot bypass lockout.
5. Recompute its HMAC using its key ID and salt and compare with `MessageDigest.isEqual`.
6. For an unknown/expired challenge, atomically record only the failed IP/device attempt; this cannot pre-lock a
   future identifier. For a mismatch against an active unexpired challenge, also apply the identifier-wide budget
   of five failures per 15 minutes, increment the row's `failedAttempts`, and change it to `EXHAUSTED` at its
   configured maximum. Return `VerificationOutcome.Invalid`; do not throw inside this transaction.
7. The transaction commits all failure counters. The outer auth service then translates `Invalid` to the
   channel-specific public 401 (`OTP_INVALID_OR_EXPIRED` for email, existing `UNAUTHORIZED` for phone).
8. For a match within all budgets, change `ACTIVE` to `CONSUMED` in the same transaction.
9. While still holding the identifier advisory lock, re-query the authoritative auth identity. Restore its user
   if soft-deleted. If no identity exists, create an email-only `User` plus the identity. The advisory lock is
   normal race control; the unique `(type, normalized_identifier)` constraint remains a final invariant.
10. Call the existing token issuance path. Refresh tokens stay hashed and rotated. Logout and account deletion
   continue to increment `authVersion` and delete all refresh tokens.

Because challenge consumption and token persistence share a transaction, a downstream database failure rolls
back consumption and permits a safe retry. Concurrent verification attempts serialize on the challenge row;
only one can consume it and receive tokens.

With one active six-digit code and an identifier-wide budget of five failed submissions against an active
challenge per 15-minute window,
the default aggregate online-guess success bound is at most 5/1,000,000 (1 in 200,000) per identifier per window,
independent of resends. IP and device budgets further bound distributed attempts. These security parameters and
the deliberate phone-sequence changes require approval with X-013.

The verification path never queries `users.email` to infer ownership. Only an existing verified
`auth_identities(type=EMAIL)` row can select an existing user.

### Shared OTP advisory lock

Challenge activation, verification, and identity lookup/creation for both channels use one
`OtpIdentifierLock` component and one namespace. It executes:

```sql
SELECT pg_advisory_xact_lock(hashtextextended(?, 0))
```

with the exact UTF-8 framed subject `meet-otp-identifier-v1:<CHANNEL>:<canonicalIdentifier>`. All three operations
must call this component; no caller may derive a private lock key. A hash collision only over-serializes unrelated
identifiers. If activation acquires the lock before verification, verification observes and consumes that
challenge. If activation acquires it after successful verification commits, it is a later challenge and remains
usable.

### Client IP resolution

`X-Device-Id` is attacker-controlled and only a supplemental quota subject. IP quota integrity is provided by a
dedicated `ClientIpResolver` and `ClientIpProperties`:

- `app.http.client-ip.trusted-proxy-cidrs` defaults to empty.
- `app.http.client-ip.max-forwarded-hops` defaults to 10.
- With no trusted immediate peer, ignore `Forwarded` and `X-Forwarded-For` and use strict-parsed `remoteAddr`.
- When the immediate peer belongs to a configured trusted-proxy CIDR, parse `X-Forwarded-For` as strict IP
  literals, append `remoteAddr`, and walk right-to-left across trusted hops. The first untrusted hop is the client.
- Never resolve hostnames. Normalize IPv4 and IPv6 to a canonical binary-derived textual form before hashing.
- If a chain is malformed, has a zone identifier, or exceeds the hop limit, ignore it and safely fall back to
  normalized `remoteAddr`.

Production operations configure only CIDRs controlled by the deployment. Caller-supplied forwarding headers
from an untrusted peer never affect rate limiting. Trusted ingress must strip/overwrite incoming
`X-Forwarded-For`; the application does not honor RFC `Forwarded` in this ticket.

## Persistence and migration

Add a monotonic Flyway migration after `V5`; never edit applied migrations.

### `auth_identities`

Create:

- `id BIGSERIAL PRIMARY KEY`
- `user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE`
- `type VARCHAR(16) NOT NULL CHECK (type IN ('PHONE', 'EMAIL'))`
- `normalized_identifier VARCHAR(254) NOT NULL`
- `created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP`
- unique `(type, normalized_identifier)`
- unique `(user_id, type)`

Migration behavior:

1. Backfill `PHONE` identities from every current non-null phone without rewriting the already-normalized phone.
2. Do not normalize, deduplicate, mutate, or backfill `users.email`; those values have no verified-auth
   provenance.
3. Drop `NOT NULL` from `users.phone`; retain its existing uniqueness for non-null values.

`auth_identities` is authoritative for login. `users.email` remains the existing profile field. For migrated and
new email-auth users the two may match, but changing the profile field does not silently replace a verified login
identity. A verified account-linking/auth-email-change flow, including any operations-approved import of legacy
emails with auditable verification provenance, is a separate product contract.

### Harden `otp_codes`

Active OTPs are five minutes old at most, so revoke them during deployment instead of preserving plaintext:

1. Delete all existing `otp_codes` rows.
2. Rename `phone` to `identifier` and widen it to 254 characters.
3. Add `channel VARCHAR(16) NOT NULL` constrained to `PHONE` or `EMAIL`.
4. Drop plaintext `code` and boolean `is_used`.
5. Add `code_hash BYTEA NOT NULL`, `hash_salt BYTEA NOT NULL`, `hash_key_id VARCHAR(32) NOT NULL`,
   `status VARCHAR(24) NOT NULL`, `failed_attempts INT NOT NULL DEFAULT 0`, `max_attempts INT NOT NULL`, nullable
   `activated_at`, and nullable `consumed_at`.
6. Add checks for 32-byte hashes, 16-byte salts, nonblank safe key IDs, `failed_attempts >= 0`,
   `max_attempts BETWEEN 1 AND 10`, `failed_attempts <= max_attempts`, and status in
   `PENDING | ACTIVE | CONSUMED | EXHAUSTED | EXPIRED | SUPERSEDED | DELIVERY_FAILED`.
7. Keep `expires_at` and `created_at`.
8. Replace the phone index with `(channel, identifier, created_at DESC, id DESC)` and retain expiry cleanup
   indexing.
9. Add a unique partial index on `(channel, identifier) WHERE status = 'ACTIVE'`.

A challenge is usable only when `status = ACTIVE`, `expires_at > now`, and
`failed_attempts < max_attempts`. A provider-failed or incompletely compensated row can remain persisted but can
never become usable without the activation transaction.

Both channels use this representation; adapting the phone flow is mandatory because the migration removes its
legacy columns. Phone registration and login create/read `PHONE` auth identities so `users.phone` is not a second
authentication source of truth.

Add bounded cleanup for expired or consumed challenges older than 24 hours. Each scheduled run deletes at most
the configured batch size (default 1,000) using an indexed `FOR UPDATE SKIP LOCKED` selection and repeats on the
next schedule; it never logs identifiers or hashes.

### Rate-limit migration

Extend the `otp_rate_limit_attempts.scope` check constraint to include `email`; retain `phone`, `ip`, and
`device` for compatibility. Also add `verify_email`, `verify_phone`, `verify_ip`, and `verify_device` for the
15-minute failed-verification budgets. Existing hashed attempts require no data rewrite. Request and verification
scopes remain separate, and all subject hashes/claims retain advisory-lock concurrency safety.

### OTP generation and HMAC format

- Generate across all one million values with `SecureRandom.nextInt(1_000_000)` and left-pad to six digits, so
  `000000` through `999999` are possible.
- Generate a fresh 16-byte salt per challenge and store it as binary.
- Decode each configured HMAC key from Base64 and require at least 32 decoded random bytes.
- Store the non-secret `hash_key_id` with each row. New rows use the configured current key; verification accepts
  the current and previous key IDs during rotation.
- HMAC-SHA-256 input is the exact byte sequence
  `UTF8("meet-otp-v1") || 0x00 || UTF8(channel) || 0x00 || UTF8(canonicalIdentifier) || 0x00 || saltBytes || 0x00 || ASCII(code)`.
- Store the 32-byte HMAC as binary and compare with `MessageDigest.isEqual`.
- Defaults remain five-minute expiry and five verification attempts; validation bounds expiry to 1–15 minutes
  and attempts to 1–10.

Key rotation is two-phase after all instances support key IDs: deploy the future key as accepted-but-not-current
everywhere, switch `current-key-id` everywhere, wait longer than maximum OTP lifetime, then remove the old key.
The initial rollout revokes all legacy OTPs. An emergency one-step key rotation also deletes all active challenges
during an auth maintenance window; mixed-key deployments without the full accepted key ring are forbidden.

## Configuration and provider boundary

Add:

- `EmailOtpSender`: narrow delivery interface receiving recipient, code, and expiry.
- `SmtpEmailOtpSender`: production adapter using Spring's mail support with fixed server-owned subject/body.
- `FakeEmailOtpSender`: `dev`/test-only adapter that never logs the recipient or code.
- `UnavailableEmailOtpSender`: non-production disabled behavior mapped to `OTP_DELIVERY_UNAVAILABLE`.
- `EmailProperties` with `provider = DISABLED | FAKE | SMTP`, sender address/name, required STARTTLS, and finite
  connect/read/write timeouts.
- `OtpHashProperties` for the current/previous Base64 HMAC key ring and verification-attempt limit.
- `spring-boot-starter-mail` in `build.gradle.kts`.

Production values are supplied only through environment/secret-manager injection:

- `APP_EMAIL_PROVIDER=smtp`
- `APP_EMAIL_FROM`
- `APP_EMAIL_FROM_NAME` (optional, non-secret)
- `SPRING_MAIL_HOST`
- `SPRING_MAIL_PORT`
- `SPRING_MAIL_USERNAME`
- `SPRING_MAIL_PASSWORD`
- `APP_EMAIL_CONNECT_TIMEOUT_MS`
- `APP_EMAIL_READ_TIMEOUT_MS`
- `APP_EMAIL_WRITE_TIMEOUT_MS`
- `APP_OTP_HMAC_CURRENT_KEY_ID`
- `APP_OTP_HMAC_CURRENT_KEY_BASE64`
- optional `APP_OTP_HMAC_PREVIOUS_KEY_ID` and `APP_OTP_HMAC_PREVIOUS_KEY_BASE64` during rotation

The committed YAML contains placeholders/defaults, never credentials. SMTP authentication and STARTTLS are
required (`mail.smtp.starttls.enable=true` and `mail.smtp.starttls.required=true`), as is SMTP certificate hostname
verification (`mail.smtp.ssl.checkserveridentity=true`); implicit SMTPS is not supported in this ticket.
`mail.smtp.ssl.trust=*`, trust-all/custom socket factories, and certificate-validation bypasses are prohibited.
A private CA is allowed only through an explicitly configured runtime JVM truststore. Connect/read/write timeouts
default to 5,000 ms and are bounded to 1,000–30,000 ms. `APP_EMAIL_FROM` must parse as exactly one supported ASCII
mailbox with no display-name/header syntax; sender address and display name reject CR/LF. The adapter builds a
fixed server-owned subject and body and must not fall back to fake or disabled delivery.

Introduce/extend startup validation so every profile except explicit `dev` and `test` (including no active
profile):

- requires `SMTP`;
- rejects `FAKE` and `DISABLED`;
- requires nonblank host, username, password, sender address, current key ID, and current Base64 HMAC key;
- validates a port in 1–65535, required STARTTLS, timeout bounds, CR/LF-free sender values, distinct safe key IDs,
  strict Base64 with at least 32 decoded bytes per configured HMAC key, exact From-mailbox syntax, certificate
  hostname verification, and the absence of trust-all/custom socket-factory settings;
- fails in the initializer before datasource/provider beans are created.

`dev` may use `FAKE` and a clearly dev-only Base64 HMAC key; `test` injects explicit test-only values. For manual
development that needs to inspect messages without logging OTPs, documentation may point SMTP at a local inbox
such as Mailpit; the fake adapter itself never exposes codes through application logs.

Operations generate production HMAC keys with a CSPRNG. Startup can validate encoding, decoded length,
non-equality of current/previous keys, and non-use of documented dev/test values; it does not claim to measure
entropy.

## JWT and compatibility details

- Keep `sub` and `av` claims and all refresh-token behavior unchanged.
- Make token issuance accept a nullable phone. Preserve the existing `phone` claim for phone users; omit it for
  email-only users. Do not put the full email address in the JWT because authorization only needs `sub` and `av`.
- `UserProfileDto.phone` is already nullable, so no response field removal is needed.
- New controllers map entities to existing DTOs; no JPA entity is serialized directly.
- `/auth/**` remains public and `/admin/**` remains role/API-key gated.
- TIMEPAD mapping, ingestion package boundaries, and idempotent `(source, sourceExternalId)` upserts are untouched.

## Failure states

- Invalid email/device/code: structured `400 BAD_REQUEST`; no secrets or submitted values are reflected.
- Request throttled: `429 OTP_RATE_LIMITED`; no delivery or challenge persistence.
- Provider timeout/auth/rejection/suppression: `503 OTP_DELIVERY_UNAVAILABLE`; no new usable challenge.
- Provider accepted, database activation failed: `503 OTP_ACTIVATION_UNAVAILABLE`; no new usable challenge;
  the prior active challenge remains valid.
- Provider/lock delay crosses challenge expiry: mark the pending row `EXPIRED`, return
  `503 OTP_ACTIVATION_UNAVAILABLE`, and preserve the prior active challenge.
- Wrong code: commit the persisted attempt count under lock through `VerificationOutcome.Invalid`, then return
  `401 OTP_INVALID_OR_EXPIRED` outside the transaction.
- Expired, consumed, replayed, exhausted, or unknown challenge: same `401` response.
- Concurrent successful verification: one success; all replays receive the same `401`.
- Concurrent sends maintain one active challenge and request-order activation.
- Concurrent first-account verification: the identity advisory lock plus unique constraint yields one user/identity.
- An unverified profile email never selects or restores an existing account.
- Missing production email/HMAC settings: startup fails before serving traffic.

## Observability and deliverability

Allowed logs/metrics contain only route/event names, provider kind, latency, outcome category, and counters.
Never log raw request bodies, OTPs, full or partially reconstructed email addresses, device identifiers, JWTs,
refresh tokens, HMAC/configuration secrets, API keys, database credentials, SMTP usernames/passwords,
SMTP/provider request or response headers/payloads, provider message IDs, or exception messages that may contain
those values.

Production documentation must require:

- a provider-verified sending domain and From address;
- SPF alignment for the provider;
- provider DKIM signing and published DKIM records;
- a DMARC record, monitored before moving to an enforcement policy;
- a configured return-path/bounce domain where supported;
- provider bounce/complaint suppression enabled and monitored;
- an operational process for reviewing suppression and delivery health without copying recipient addresses into
  application logs or tickets.

Bounce/suppression webhooks and a local suppression database are not part of this ticket. A provider may accept
a message that later bounces; its OTP expires normally. A synchronous provider suppression rejection is mapped to
the generic delivery-unavailable error and is not persisted.

The public behavior is resistant to enumeration of new/existing/deleted application accounts. Because a
synchronous provider recipient rejection or suppression maps to 503 while accepted mail maps to 202, it is not a
promise of mailbox/deliverability opacity. That stronger property is an explicit non-goal of this contract.

## Implementation surfaces

- `AuthController`, additive email methods, and `OtpRequestContext`
- `AuthDto`, additive email request DTOs
- `AuthService`, extracted normalizer/hash/challenge activation behavior, and shared token issuance
- transactional `OtpVerificationExecutor` returning `VerificationOutcome`
- `OtpCode`, new `AuthIdentity`, `User.phone` nullability
- `OtpRepository`, new `AuthIdentityRepository`, and `UserRepository`
- `OtpRateLimiter` generalized from phone to identifier and explicit device ID
- new `ClientIpResolver`/properties for strict trusted-proxy handling
- new `service/email` provider boundary and SMTP/fake/disabled adapters
- `OtpProperties`, new email properties, configuration registration, and startup initializer
- `JwtService` nullable phone claim behavior
- `build.gradle.kts` for Spring mail support
- `application.yml`, `application-dev.yml`, `.env.example`, README/production operations documentation
- auth service, error MVC, runtime log-safety, PostgreSQL migration/rate-limit, startup, and full API integration tests

## Verification plan

Focused tests:

- Email normalization and validation vectors for Unicode trim/NFC, ASCII-local-part enforcement, IDN domains,
  locale-sensitive input, dot placement, aliases, and 254/255-character boundaries.
- No account lookup during request and no `users.email` lookup during verification.
- Secure generation across `000000`–`999999`, 16-byte salts, exact HMAC framing/key selection, no plaintext code
  persistence, constant-time comparison, and two-phase key rotation.
- Provider success changes only the latest requested pending challenge to active; rejection/timeout leaves no new
  usable challenge and maps to the stable 503.
- Activation failure returns exact `OTP_ACTIVATION_UNAVAILABLE`, leaves its pending row unusable, and preserves
  the prior active challenge.
- Provider/lock delay crossing database expiry never promotes the pending row or supersedes a valid prior
  challenge, including requests created under different configured lifetimes.
- Concurrent sends enforce one active challenge and request-ID ordering: an older slow delivery cannot supersede
  a newer request, a pending/failed resend preserves the prior active code, and successful latest activation
  supersedes it.
- A PostgreSQL race test overlaps activation and successful verification using the shared lock: activation
  serialized first is observed/consumed, while activation serialized after verification becomes the later active
  challenge.
- Actual email 401 responses are followed by committed failed-attempt increments; exhaustion and concurrent
  wrong/correct submissions enforce the configured limit.
- Unknown/no-active verification failures consume IP/device budgets but do not consume the identifier budget or
  pre-lock a future challenge; five mismatches against an active challenge do exhaust the shared identifier budget.
- Five mismatches → resend → correct code remains the same 401 until the identifier window clears; the resend
  cannot reset or bypass the shared budget.
- Resends do not reset the five-failure/15-minute identifier budget; IP/device budgets and the 1-in-200,000
  aggregate default bound are enforced under concurrency.
- Existing verified identity login, new email-only user creation, soft-delete restoration, and advisory-locked
  identity creation race.
- An existing unverified/stale/reassigned `users.email` value is never auto-linked or accepted as that user's
  login identity.
- Phone challenge hashing, committed/shared attempt budgets, latest-request supersession, identity creation,
  restoration, success, and replay preserve the frozen HTTP/JWT matrix while proving the explicitly approved
  sequence-semantic changes.
- Refresh rotation, logout, account deletion, and auth-version invalidation regression tests.
- Client-IP tests for direct requests, spoofed headers from untrusted peers, trusted single/multi-proxy chains,
  IPv4/IPv6 normalization, malformed/excessive chains, and quota concurrency.
- Log-capture tests inject marker recipient, code, device ID, HMAC/config secret, SMTP credentials,
  request/response header/payload, provider ID/exception, JWT, refresh token, API key, and database credential
  values and prove absence in default, dev/test, startup-failure, provider-failure, and unexpected-error paths.
- SMTP configuration tests cover required STARTTLS, authentication, certificate hostname verification,
  trust-all/custom-socket-factory rejection, strict From-mailbox syntax, finite timeout bounds, CR/LF rejection,
  optional private truststore behavior, and fail-fast behavior in default/non-dev profiles.

PostgreSQL-backed tests:

- Flyway migrates a V5-shaped database, revokes legacy plaintext OTPs, backfills phone identities only, leaves
  unverified profile emails unlinked, makes phone nullable, adds all constraints/indexes, and validates JPA mappings.
- Old and new binaries never run concurrently during migration; a migration fixture proves old rows are revoked
  without retaining plaintext.
- Email/IP/device request quotas remain concurrency-safe and independent.
- Challenge/advisory locking allows one verification success and commits attempt counts under concurrency.
- Bounded cleanup removes only eligible expired/consumed rows in configured batches.
- Full request → fake delivery → persisted challenge → verify → refresh → logout/deletion integration.
- Auth migrations leave meeting/ingestion/admin/TIMEPAD tables, mappings, configuration, and indexes unchanged.
- TIMEPAD regression coverage maps a representative payload and upserts the same
  `(source, sourceExternalId)` twice, proving one row is updated rather than duplicated.
- Admin integration assertions preserve `/admin/ingest` and `/admin/purge` authorization and response contracts.

Commands/runtime checks:

1. Run focused auth, error-contract, configuration, rate-limit, admin authorization, TIMEPAD mapping/upsert, and
   integration tests.
2. Run `./gradlew test`.
3. Run `./gradlew clean build`.
4. Start once with no active profile and once with `prod`, each with complete SMTP/HMAC settings; verify startup
   and health.
5. Repeat default/`prod` startup while omitting each required provider/HMAC setting; verify fail-fast startup
   without a datasource/provider connection attempt and without secret values in output.

## Rollout and rollback

- Stop all old application instances and profile writers before the migration; the migration revokes in-flight
  phone OTPs and old binaries cannot use the hardened schema.
- Configure and validate the sending domain, SMTP credentials, From address, HMAC secret, and production profile
  before enabling public traffic.
- Roll back application binaries only together with a forward-fix migration or a database restore; old binaries
  cannot read the hardened OTP schema. Never down-migrate by restoring plaintext OTP storage.

## Explicit non-goals

- Android UI/client implementation.
- Removing phone endpoints or deciding the long-term phone-login retirement date.
- A profile/auth-email change or account-linking UI flow.
- Treating any legacy unverified `users.email` value as a login credential.
- Provider bounce/complaint webhooks or a local suppression database.
- Mailbox/deliverability-enumeration opacity beyond application-account enumeration resistance.
- Magic links, passwords, TOTP, social login, or multi-factor authentication.
- Changing refresh-token rotation, logout, deletion, admin authorization, TIMEPAD ingestion, or unrelated APIs.
