# MEE2-23 — Email OTP backend implementation plan

## Planning status

- **Baseline:** branch `MEE2-23` at `d3b34d7f77f3e3f60858a594ff434e36394a0564`, exactly matching
  `origin/dev` when this recovery plan was prepared.
- **Inputs:** the complete Design and later reviewed Architecture results in this directory, the task body and all
  task comments, and the current auth, configuration, migration, persistence, security, ingestion, and test code.
- **Plan readiness:** executable after the remaining workflow/product gate below is cleared.
- **Production changes in this planning stage:** none.

## Remaining gates and blockers

1. **Implementation blocker:** the workflow must record product approval of the proposed X-013 contract and the
   reviewed Design/Architecture results. The repository and task records still describe X-013 as proposed rather
   than approved. Do not begin production implementation before that approval.
2. **Release gate, not an implementation blocker:** public sign-in remains blocked until A-048 is complete.
3. **Operational release prerequisites:** production SMTP credentials, a verified From domain, SPF, DKIM, DMARC,
   bounce/return-path and suppression handling, a shared OTP HMAC key ring, trusted-proxy CIDRs, and a database
   backup/cutover window must exist before production traffic is enabled.

The task's current `interrupted` workflow status is a handoff concern for the parent session. This plan does not
change workflow state.

## Authority and resolved contradictions

The API and product behavior are taken from the Design result. Where the Design and Architecture differ, the
later reviewed Architecture result is authoritative:

- Use dedicated email endpoints; do not make the existing phone DTOs polymorphic.
- Replace the JPA `OtpCode`/`OtpRepository` persistence path with one JDBC-owned challenge store and an immutable
  non-JPA `OtpChallengeSnapshot`.
- Use `(channel, identifier, id DESC)` for request ordering. `created_at` is audit data and must not decide which
  request is latest.
- Use PostgreSQL `clock_timestamp()` sampled after relevant lock waits for challenge, attempt-window, and cleanup
  decisions; do not use JVM `Clock`, `LocalDateTime.now()`, or transaction-start `CURRENT_TIMESTAMP` for those
  decisions.
- Split request and verification limiting into `OtpRequestRateLimiter` and `OtpVerificationLimiter` over one
  `OtpAttemptStore`; request/verification paths do not perform cleanup.
- Verification lock order is identifier advisory lock, active challenge row, then sorted attempt-subject advisory
  locks.
- Activation accepts only `challengeId` and derives the lock subject from immutable persisted challenge data.
- Use `EmailOtpMessage` at the email delivery boundary.
- Keep separate auth-response and full-profile projections because their current defaults are observably
  different.
- Treat every profile set other than exactly `dev` or exactly `test` as production; reject mixed profile sets that
  include `dev` or `test`.

## Scope

### In scope

- Additive email OTP request and verification HTTP contracts.
- Unified PHONE/EMAIL challenge storage, HMAC verification, request ordering, attempt limits, replay protection,
  and single-use consumption.
- Authoritative `auth_identities` mappings and nullable `users.phone`.
- SMTP email delivery with strict production startup validation.
- Trusted-proxy-aware IP and explicit device-ID quota subjects.
- Preservation of refresh rotation, logout, account deletion/restoration, and monotonic `authVersion`.
- Bounded challenge and attempt cleanup.
- Exact contract, migration, PostgreSQL concurrency, startup, provider, logging-safety, and regression tests.
- Production deliverability, rollout, rollback, and key-rotation documentation.

### Explicit non-goals

- Android/client work or phone-login retirement.
- Linking a legacy profile email to an authentication identity.
- Profile/auth-email change verification.
- Bounce/complaint webhooks or local suppression storage.
- Mailbox/deliverability-enumeration opacity beyond application-account enumeration resistance.
- Redis, a queue/outbox, another deployable, a provider-specific email SDK, or a new observability backend.
- Changes to admin policy, refresh semantics, account deletion semantics, TIMEPAD behavior, meeting upsert
  identity, or unrelated APIs/schema.


## Frozen public contracts

### Existing phone contract

Keep these values byte-for-byte stable at the HTTP boundary:

- `POST /auth/send-otp`
  - valid request: `200` and `{"message":"OTP sent successfully"}`;
  - invalid phone: `400 BAD_REQUEST`, `Phone must be in E.164 format`;
  - throttled: `429 RATE_LIMITED`, `Too many OTP requests. Please try again later.`;
  - disabled SMS: `503 SMS_UNAVAILABLE`, `SMS delivery is not configured`;
  - no `Retry-After` on the above failures.
- `POST /auth/verify-otp`
  - existing request shape and validation messages;
  - wrong, unknown, expired, exhausted, consumed, or replayed code: `401 UNAUTHORIZED`,
    `Invalid or expired OTP code`;
  - existing `AuthResponse` shape and `isNewUser` behavior.
- Phone-auth JWTs retain `sub`, `phone`, and `av`.
- Pending-insert failure, activation database failure, and activation-after-expiry remain the exact generic
  `500 INTERNAL_ERROR` envelope with `An unexpected error occurred` and no `Retry-After`.

The phone endpoints add optional `X-Device-Id`; absence must preserve current behavior.

### Email contract

- `POST /auth/email/send-otp`
  - body: `{"email":"person@example.com"}`;
  - optional `X-Device-Id`, 16–128 ASCII characters from `[A-Za-z0-9._~-]`;
  - success: `202` and
    `{"message":"If the address can receive email, a verification code will be sent."}`;
  - request flow performs no account lookup;
  - validation messages:
    - missing/blank: `Email is required`;
    - malformed/unsupported: `Email must be valid`;
    - canonical address over 254 characters: `Email must not exceed 254 characters`;
    - bad device header: `X-Device-Id must be 16 to 128 safe ASCII characters`;
  - throttled: `429 OTP_RATE_LIMITED`, `Too many OTP requests. Please try again later.`;
  - provider failure: `503 OTP_DELIVERY_UNAVAILABLE`, `OTP delivery is temporarily unavailable.`;
  - accepted delivery followed by activation failure/expiry: `503 OTP_ACTIVATION_UNAVAILABLE`,
    `OTP is temporarily unavailable. Please request a new code.`;
  - email 429/503 responses have no `Retry-After`.
- `POST /auth/email/verify-otp`
  - nullable-at-deserialization `email`, `code`, `name`, and `surname` fields;
  - code is exactly six ASCII digits; name/surname retain existing 100-character messages;
  - success uses existing `AuthResponse`; a new email-only user has canonical email and null phone;
  - all unknown/wrong/expired/exhausted/consumed/replay cases use `401 OTP_INVALID_OR_EXPIRED` and
    `Invalid or expired OTP code.`;
  - verification never uses `users.email` to infer account ownership.
- Email-only JWTs contain `sub` and `av`, omit `email`, and omit the `phone` claim entirely.

## Target component and affected-area map

Use the existing modular-monolith package conventions. Exact filenames may be combined when that improves
cohesion, but these ownership boundaries are required.

### API and mapping

- `api/controller/AuthController.kt`: retain phone methods; add `sendEmailOtp`/`verifyEmailOtp`; resolve context
  through `ClientRequestContextResolver`; never normalize, generate OTPs, call providers, or access repositories.
- `api/dto/AuthDto.kt`: add `SendEmailOtpRequest`, `VerifyEmailOtpRequest`, and `OtpAcceptedResponse`. Email DTO
  fields are nullable with defaults and have no Bean Validation email regex/raw-size annotations.
- `api/error/ApiError.kt`: add email-specific rate-limit, delivery, activation, and invalid-OTP exceptions.
- Add `EmailOtpRequestValidator`, returning normalized send/verify commands in deterministic validation order.
- Add one user-profile mapper with explicit `toAuthProfileDto` and `toFullProfileDto`; update `AuthService` and
  `UserService` to select the correct projection.

### Identifier and request context

Suggested package: `service/auth/identifier`.

- `AuthChannel`, immutable/redacted `AuthIdentifier`, `PhoneNumberNormalizer`, and `EmailAddressNormalizer`.
- `DeviceId`, `DeviceIdParser`, `NormalizedIp`, `IpLiteralParser`, `TrustedProxySet`, and `ClientIpResolver`.
- `ClientRequestContextResolver`; replace `OtpRequestContext.userAgent` with typed `clientIp` and `deviceId`.

### OTP module

Suggested package: `service/auth/otp`.

- Sensitive/domain types: `SensitiveOtpCode`, `OtpChallengeStatus`, `OtpChallengeSnapshot`, `PendingChallenge`,
  `ActivationOutcome`, `VerificationOutcome`, `OtpRequestOutcome`, and safe internal failure enums/types.
- Cryptography: `OtpCodeGenerator`, `OtpKeyRing`, and `OtpHasher`.
- PostgreSQL persistence: `OtpIdentifierLock`, `OtpChallengeStore`, and `OtpAttemptStore`.
- Application/transactions: `OtpRequestRateLimiter`, `OtpVerificationLimiter`, `OtpChallengeLifecycle`,
  `OtpRequestCoordinator`, `OtpVerificationExecutor`, and `OtpDeliveryRouter`.
- Cleanup: `OtpChallengeCleanupJob` and `OtpAttemptCleanupJob`.

Business services depend on these narrow stores, never directly on `JdbcTemplate`.

### Identity, tokens, delivery, and configuration

- `domain/entity/AuthEntity.kt`: remove JPA `OtpCode`, retain `RefreshToken`, add JPA `AuthIdentity`.
- `domain/entity/User.kt`: make `phone: String?`/column nullable and preserve uniqueness for non-null values.
- `domain/repository/AuthRepository.kt`: remove `OtpRepository`, retain `RefreshTokenRepository`, add
  `AuthIdentityRepository` with only `(type, normalizedIdentifier)` and `(userId, type)` lookups.
- `domain/repository/UserRepository.kt`: retain `findWithLockById`; remove `findByPhone` because no non-auth caller
  uses it and profile phone must not remain an auth source.
- Add `AuthTokenIssuer`; update `JwtService.generateAccessToken` for nullable phone and conditional claim creation.
- Keep `SmsSender`; add `service/email/EmailOtpSender`, `EmailOtpMessage`, `SmtpEmailOtpSender`,
  `FakeEmailOtpSender`, and `UnavailableEmailOtpSender`; recording senders live only under `src/test`.
- Add `EmailProperties`, `OtpHashProperties`, `ClientIpProperties`, expanded OTP/rate-limit properties,
  `SmtpRuntimeSettings`, `RuntimeConfigurationValidator`, and `RuntimeConfigurationInitializer`.
- Update `MeetBackendApplication.kt`, `build.gradle.kts`, `application.yml`, `application-dev.yml`,
  `src/test/resources/application.yml`, `.env.example`, README, and production email operations documentation.
- Add only `db/migration/V6__email_otp_authentication.sql`; do not edit V1–V5.

## Required internal contracts and invariants

Closed outcomes are not exception-message or string protocols:

```text
ActivationOutcome = Activated | Superseded | Expired
VerificationOutcome = Authenticated(AuthResponse) | Invalid
OtpRequestOutcome = Accepted | DeliveryUnavailable | ActivationUnavailable | PersistenceUnavailable
```

Request quota exhaustion and provider failure use separate safe internal typed failures, mapped by `AuthService`
to channel-specific public errors.

The challenge state machine is:

```text
PENDING -> ACTIVE | DELIVERY_FAILED | SUPERSEDED | EXPIRED
ACTIVE  -> CONSUMED | EXHAUSTED | SUPERSEDED | EXPIRED
terminal states have no outgoing transition
```

Additional invariants:

- only `ACTIVE` is usable and at most one active row exists per `(channel, identifier)`;
- immutable channel/identifier data owns lock derivation, HMAC framing, identity lookup, and limit subjects;
- the greatest request ID is the only pending row eligible to activate;
- terminal transitions are conditional on the expected prior state and are idempotent;
- raw OTP lifetime is limited to generation, HMAC calculation, delivery, and stack-frame release;
- `auth_identities` owns login mappings; `users.phone`/`users.email` remain profile fields;
- successful consumption, identity/user work, and refresh-token insertion share one transaction;
- expected invalid verification returns from the transaction so applicable counters commit before the public 401.

## Ordered implementation slices

Each slice should leave focused tests green. Do not split V6 and the unified phone/email runtime into
independently deployable artifacts: production rollout is one coordinated cutover.

### Slice 1 — Freeze baseline behavior and PostgreSQL test infrastructure

1. Extract the duplicated external-PostgreSQL/Testcontainers setup from `IntegrationTestSupport` and
   `OtpRateLimiterPostgresIntegrationTest` into a shared test utility.
2. Add JUnit `postgres` tags to every PostgreSQL-backed suite.
3. Add a dedicated Gradle `postgresTest` task that includes only `postgres`, uses the main test runtime classpath,
   and fails clearly when neither Docker nor `TEST_POSTGRES_JDBC_URL` is available. Remove `Assumptions` and the
   execution condition that currently allow database suites to pass by skipping.
4. Keep one explicit developer opt-out for the ordinary `test` task, such as `-PskipPostgresTests=true`; without
   it, PostgreSQL tests run normally.
5. Characterize the frozen phone statuses, bodies, codes, messages, absent `Retry-After`, JWT phone claim, refresh
   rotation, logout, deletion, restoration, `authVersion`, and the two current profile projections before moving
   those responsibilities.
6. Add missing admin, TIMEPAD mapping, and `(source, sourceExternalId)` idempotent-upsert regression coverage so
   later auth changes have unrelated-system guards.

Acceptance:

- Baseline behavior is asserted before it is refactored.
- `./gradlew postgresTest` cannot pass by skipping all database tests.
- No production behavior changes in this slice.

### Slice 2 — Add typed identifiers, request context, and validation

1. Implement `AuthIdentifier`, phone/email normalizers, typed normalization failures, and redacted sensitive value
   wrappers.
2. Implement email canonicalization exactly:
   - Java 21 `String.strip()`;
   - NFC normalization;
   - exactly one `@`;
   - 1–64 character ASCII dot-atom local part;
   - lowercase local part with `Locale.ROOT`;
   - reject pre-IDNA leading/trailing dots and empty domain labels;
   - `IDN.toASCII(domain, IDN.USE_STD3_ASCII_RULES)`;
   - lowercase domain; require at least two labels, 1–63 characters per label, and at most 253 total;
   - final canonical address at most 254 ASCII characters;
   - preserve dots and `+tag`; reject quoted and SMTPUTF8 local parts.
3. Implement deterministic email request validation in this order: email required, canonical email validity/length,
   device header, code, name, surname.
4. Implement `DeviceIdParser` for 16–128 safe ASCII characters and validate a present header even when device
   limiting is disabled.
5. Implement strict IP literal parsing, CIDR membership, right-to-left trusted-proxy traversal, maximum forwarded
   hops, and fallback to normalized `remoteAddr`. Never call DNS resolution on supplied input.
6. Ignore forwarding headers when the immediate peer is untrusted. When trusted, honor only `X-Forwarded-For`;
   RFC `Forwarded` remains unsupported in this ticket.
7. Replace `OtpRequestContext.userAgent` with typed `clientIp` and `deviceId` values and add
   `ClientRequestContextResolver`.

Acceptance:

- Turkish-locale, Unicode strip/NFC, IDN, dot placement, 254/255 boundary, malformed device, direct IP, spoofed
  header, trusted chain, malformed chain, hop-limit, IPv4, and IPv6 tests pass.
- No value-object `toString()` reveals an identifier, IP, device ID, code, or key material.
- No resolver path can perform a hostname lookup.

### Slice 3 — Add V6 and authoritative identity/challenge persistence

Add exactly `src/main/resources/db/migration/V6__email_otp_authentication.sql`; do not edit V1–V5.
V6 is one Flyway-transactional migration; do not split its statements across versions.

Implement the migration in this order:

1. Create `auth_identities` with the fixed DDL contract below.
2. Backfill one `PHONE` identity for every non-null `users.phone`, unchanged.
3. Do not read, normalize, deduplicate, mutate, or backfill `users.email`.
4. Drop `NOT NULL` from `users.phone`; leave its existing uniqueness in place.
5. Delete every legacy `otp_codes` row, intentionally revoking in-flight plaintext phone OTPs.
6. Drop legacy OTP indexes; transform `otp_codes` to the challenge schema; drop plaintext `code` and `is_used`.
7. Add challenge checks and Architecture-approved indexes.
8. Replace the rate-limit scope check with the complete request and verification scope set.

Required `auth_identities` shape:

- `id BIGSERIAL PRIMARY KEY`;
- `user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE`;
- `type VARCHAR(16) NOT NULL CHECK (type IN ('PHONE', 'EMAIL'))`;
- `normalized_identifier VARCHAR(254) NOT NULL` with a nonblank check;
- `created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP`;
- unique `(type, normalized_identifier)`;
- unique `(user_id, type)`.

Required `otp_codes` challenge shape:

- retain `id`, `expires_at`, and `created_at`;
- `identifier VARCHAR(254) NOT NULL`, `channel VARCHAR(16) NOT NULL`;
- `code_hash BYTEA NOT NULL`, `hash_salt BYTEA NOT NULL`, `hash_key_id VARCHAR(32) NOT NULL`;
- `status VARCHAR(24) NOT NULL`, `failed_attempts INT NOT NULL DEFAULT 0`, `max_attempts INT NOT NULL`;
- nullable `activated_at` and `consumed_at`;
- checks for channel `PHONE|EMAIL`, the reviewed status set, nonblank identifier, exactly 32 hash bytes and 16 salt
  bytes, a 1–32 safe ASCII key ID, `0 <= failed_attempts <= max_attempts`, and `1 <= max_attempts <= 10`.

Required indexes:

- `(channel, identifier, id DESC)` for latest-request lookup;
- unique partial `(channel, identifier) WHERE status = 'ACTIVE'`;
- `(status, expires_at, id)` for cleanup.

Rate-limit scopes are `phone`, `email`, `ip`, `device`, `verify_phone`, `verify_email`, `verify_ip`, and
`verify_device`.

After migration tests pass:

1. Add `AuthIdentity` JPA mapping/repository and nullable `User.phone`.
2. Remove the JPA `OtpCode` entity and `OtpRepository`.
3. Implement `OtpIdentifierLock`, `OtpChallengeStore`, and immutable snapshots.
4. Make activation's public API accept only a challenge ID. Read persisted channel/identifier, acquire the shared
   advisory lock, then re-read and conditionally transition the row.

Acceptance:

- A V5-shaped fixture migrates successfully; legacy rows are deleted and plaintext columns no longer exist.
- Phone identities are complete, email identity count is zero, and profile emails are byte-for-byte unchanged.
- `users.phone` accepts multiple nulls and still rejects duplicate non-null phones.
- Tests assert every column, FK action, check, unique constraint, and backing index from PostgreSQL catalogs.
- Meeting, ingestion, admin, TIMEPAD, and unrelated schema objects are unchanged.
- Hibernate validates aggregate mappings while `otp_codes` has no JPA persistence owner.

### Slice 4 — Implement OTP HMAC and delivery boundaries

1. `OtpCodeGenerator` uses the process-wide `SecureRandom`, calls `nextInt(1_000_000)`, and left-pads to six
   digits, allowing `000000` through `999999`.
2. `OtpHasher` generates a fresh 16-byte salt, resolves current/previous keys by `hash_key_id`, and computes
   HMAC-SHA-256 over exactly:

   ```text
   UTF8("meet-otp-v1") || 0x00 || UTF8(channel) || 0x00 || UTF8(canonicalIdentifier) ||
   0x00 || salt || 0x00 || ASCII(code)
   ```

3. Compare hashes with `MessageDigest.isEqual`; never expose decoded key bytes.
4. `OtpKeyRing` validates strict Base64, at least 32 decoded bytes per key, safe/distinct IDs, distinct material,
   a configured current key, and the approved optional previous key.
5. Add `EmailOtpSender`, `EmailOtpMessage`, and `OtpDeliveryRouter`.
6. `SmtpEmailOtpSender`:
   - builds fixed server-owned plain-text subject/body;
   - accepts no caller-controlled template, subject, or body;
   - requires auth, STARTTLS enable+required, and certificate hostname verification;
   - rejects trust-all and custom socket-factory settings;
   - uses 1,000–30,000 ms connect/read/write timeouts, default 5,000 ms;
   - validates exactly one ASCII From mailbox and rejects CR/LF in sender fields;
   - performs no automatic retry;
   - maps provider exceptions to safe internal categories without carrying provider text.
7. Adapt existing SMS delivery to the internal delivery outcome without changing its public exception contract.
8. Add dev/test fake/disabled email adapters and test-only recording adapters. Fake adapters never log codes or
   recipients.

Acceptance:

- HMAC framing and current/previous key selection pass fixed-vector tests.
- Stored challenge values contain no recoverable plaintext code.
- SMTP tests assert auth, STARTTLS, peer identity, trust-all rejection, timeouts, strict sender parsing, fixed
  content, no retry, and safe exception mapping.
- Marker tests prove recipient, code, key ID/material, credentials, payload, provider message ID, and provider
  exception text do not appear in logs or public errors.

### Slice 5 — Implement request limiting and challenge lifecycle

1. Replace `OtpRateLimiter` with `OtpAttemptStore`, `OtpRequestRateLimiter`, and `OtpVerificationLimiter`.
   The store owns subject hashing, sorted advisory locks, count/insert SQL, and cleanup selection; the request
   limiter claims in `REQUIRES_NEW`; the verification limiter joins its caller transaction.
2. Request identifier scopes are separate for PHONE/EMAIL; IP and enabled device scopes aggregate both channels.
3. Request claim transaction:
   - sort subjects by stable scope/key and acquire advisory locks;
   - count with `clock_timestamp() - configured window`;
   - reject before inserts if any scope is exhausted;
   - insert accepted claims with `attempted_at = clock_timestamp()`;
   - do not delete rows or invoke cleanup.
4. `OtpChallengeLifecycle.createPending` runs in a short transaction: acquire the identifier advisory lock, sample
   PostgreSQL wall time after the lock, insert `PENDING` with configured lifetime and captured `max_attempts`, and
   return the generated ID.
5. `markDeliveryFailed` is an idempotent conditional `PENDING -> DELIVERY_FAILED` transaction.
6. Activation accepts only `challengeId`, derives the advisory lock from persisted immutable data, and re-reads
   after locking. A greater ID across any status makes the row `SUPERSEDED`; an expired row becomes `EXPIRED`;
   only the latest unexpired row may supersede the prior active row and become `ACTIVE`. Final activation SQL also
   requires `expires_at > clock_timestamp()`.
7. If expiry is crossed after prior-active supersession but before final activation, roll back that attempt, then
   mark the pending row `EXPIRED` in a separate short transaction. Use a separate proxied transaction helper or
   explicit transaction templates; never commit the prior-row change after the final predicate loses.
8. `OtpRequestCoordinator` is non-transactional and executes: request claim, generate code/HMAC, create pending,
   provider call outside a DB transaction, compensate or activate, return a closed outcome.
9. Provider failure compensation is best effort. Compensation failure cannot make the pending row usable and must
   not replace the original channel-specific delivery error.

Acceptance:

- Claims commit even when pending insertion, delivery, or activation later fails.
- Provider is never called when rate limiting or pending insertion fails.
- SMTP/SMS is never called while a database transaction is active.
- Delivery failure leaves no new usable challenge and preserves the prior active challenge.
- A newer request ID controls activation even if an older provider call returns later.
- At most one active row exists per channel/identifier under concurrency.
- Activation waits crossing expiry never activate the row or supersede a valid prior active challenge.

### Slice 6 — Implement transactional verification, identities, and tokens

Implement `OtpVerificationExecutor.verify(command)` as one transaction:

1. Acquire the shared identifier advisory lock.
2. Lock the active challenge row for the identifier.
3. Build IP/device subjects and tentatively include the identifier subject only when an active challenge was
   observed; sort and acquire those attempt-subject advisory locks.
4. Resample `clock_timestamp()` after all waits and recheck status/expiry.
5. If no active/unexpired challenge remains, omit the identifier scope and charge only applicable IP/device
   failure scopes.
6. Check applicable budgets. An exhausted identifier budget prevents a correct resent code from bypassing lockout.
7. Compare HMAC only for an applicable active challenge.
8. For a mismatch, conditionally increment/exhaust the challenge only while active and unexpired. If the update
   succeeds, insert applicable IP/device/identifier attempts. If it loses because expiry was crossed, insert only
   IP/device attempts and do not increment the challenge.
9. For a match, conditionally change `ACTIVE -> CONSUMED` with the same expiry predicate. If it loses, record only
   IP/device failure and return invalid; if it succeeds, continue in the same transaction.
10. Resolve only `AuthIdentity(type, normalizedIdentifier)`: lock an existing user's row; restore soft deletion
    without decreasing `authVersion`; or create one user and identity while holding the identifier lock. PHONE new
    users set phone/null email; EMAIL new users set canonical email/null phone.
11. Issue the access token and persist only the hashed refresh token through `AuthTokenIssuer`.
12. Return `VerificationOutcome.Invalid` from inside the transaction. `AuthService` throws the channel-specific
    public 401 only after the transaction commits.

Transaction invariants:

- Wrong-code counters survive the outer public 401.
- Consumption, user/identity creation or restoration, and refresh-token insertion commit together.
- A database failure after a correct comparison rolls back consumption and permits safe retry.
- Existing users are locked before token issuance so logout/deletion and verification use a committed monotonic
  `authVersion`.
- A unique-constraint violation is not caught and queried around inside an aborted PostgreSQL transaction.

Also extract `AuthTokenIssuer`, add `toAuthProfileDto`/`toFullProfileDto`, update refresh rotation for nullable
phone, and make `JwtService` omit rather than null-fill the phone claim for email-only users.

Acceptance:

- Unknown, expired, wrong, exhausted, consumed, and replayed attempts map uniformly per channel.
- Five default identifier failures across resends block a later correct code until the 15-minute window clears.
- Unknown/no-active failures cannot pre-lock or charge a future identifier challenge.
- Attempt-lock and challenge-lock waits crossing expiry charge only IP/device, never identifier/challenge state.
- Concurrent correct submissions produce exactly one success.
- An unverified `users.email` value never selects or restores that user.
- Concurrent first-account verification creates one user/identity.
- Existing/new phone users, existing/new email users, and soft-deleted users follow the reviewed behavior.
- Refresh, logout, deletion, restoration, and old JWT/refresh invalidation remain monotonic.

### Slice 7 — Wire HTTP contracts and channel-specific error mapping

1. Update `AuthController` to inject context resolution/validation collaborators and expose the two email routes.
2. Add `X-Device-Id` handling to both phone routes without changing existing JSON fields or Bean Validation.
   `verifyOtp` now also receives the resolved IP/device context.
3. Keep `AuthService` as the channel-facing facade:
   - `sendOtp(phone, context)` maps internal outcomes to the frozen phone contract;
   - `sendEmailOtp(command)` maps to the X-013 email request contract;
   - `verifyOtp(request, context)` maps invalid to the phone 401;
   - `verifyEmailOtp(command)` maps invalid to the email 401;
   - refresh/logout retain current transaction semantics.
4. Preserve `ApiExceptionHandler`'s envelope and generic unexpected-error behavior.
5. Ensure no infrastructure/provider exception text or submitted identifier is reflected.
6. Leave `SecurityConfig` production rules unchanged because `/auth/**` is already public; add regression
   assertions for both email routes and unchanged `/admin/**` authorization.

Acceptance:

- Exact phone and email status/body/code/message/path/timestamp/header assertions pass.
- Missing, null, blank, whitespace, malformed, IDN, 254/255, code, name/surname, and device validation order is
  deterministic.
- Send performs no account lookup; verify performs no `users.email` ownership lookup.
- Submitted values are absent from error bodies and default/dev runtime logs.

### Slice 8 — Complete fail-fast configuration, cleanup, and operations docs

1. Add validated bindings for email provider/from/from-name, Spring Mail host/port/username/password, SMTP
   TLS/hostname verification/timeouts, current/previous HMAC IDs/material, request/verification limits, trusted
   proxy CIDRs/hop limit, and cleanup delays/retention/batches.
2. `application.yml` contains placeholders/defaults only. `application-dev.yml` uses fake providers and an explicit
   documented dev-only HMAC key. `src/test/resources/application.yml` explicitly activates only `test` and uses
   test-only values. `.env.example` lists names and non-secret guidance only.
3. Replace `JwtConfigurationInitializer` with `RuntimeConfigurationInitializer`:
   - empty/default profile is production;
   - exactly `dev` and exactly `test` are non-production;
   - reject `prod,dev`, `dev,test`, and any mixed set containing a weakening profile;
   - production requires SMTP, safe sender/TLS/timeouts, current HMAC key, datasource, and JWT;
   - preserve blank-admin-key behavior and dev-only fake-SMS safety;
   - fail before datasource/provider beans;
   - never include credential, key, or recipient values in errors.
4. Keep one validation owner per rule. Where this work touches duplicated JWT checks, retain one constructor/factory
   owner and let the initializer only bind/invoke it.
5. Add `OtpChallengeCleanupJob`: bounded `FOR UPDATE SKIP LOCKED` deletion of rows whose `expires_at` is over 24
   hours old, including stale active/pending and terminal rows.
6. Add `OtpAttemptCleanupJob`: bounded deletion before
   `clock_timestamp() - max(requestWindow, verificationWindow)`, with no identifier/subject advisory lock.
7. Add production operations documentation, preferably `docs/operations/email-otp.md`, covering verified From
   domain, SPF, DKIM, DMARC rollout, return path, bounce/complaint suppression, credentials, trusted proxies, key
   generation/rotation, safe diagnostics, cutover, canary, and rollback. Update README variable guidance.

Acceptance:

- Startup accepts OTP expiration values 1, 5, and 15 and rejects 0 and 16.
- Every required default/production setting is tested for omission and unsafe values.
- Missing configuration fails before datasource or SMTP connection attempts.
- Dev/test values are rejected in production and mixed profiles cannot weaken checks.
- Cleanup is bounded, concurrent-safe, database-time-based, and emits only safe count/category logs.
- Request/verification paths never perform cleanup.

### Slice 9 — Complete PostgreSQL races and full regressions

Add deterministic PostgreSQL tests for:

- request quota boundary concurrency for email, phone, aggregate IP, and enabled device;
- verification identifier/IP/device boundaries and resend-resistant identifier budget;
- one-active uniqueness and ID-based request ordering;
- slow old delivery versus fast new delivery and failed/pending resend preserving the prior active code;
- activation versus successful verification under the shared lock;
- activation, challenge, and attempt-lock waits crossing expiry;
- attempt-lock waits crossing the rate-window boundary;
- post-lock `clock_timestamp()` for counts and inserts;
- failed verification counters committed before the public 401;
- correct code followed by token persistence failure rolling back consumption;
- concurrent successful verification/replay and identity creation/restoration races;
- bounded challenge and attempt cleanup;
- two disjoint claims with crossed stale rows plus concurrent cleanup completing without deadlock/transient 500;
- V5-to-V6 migration and unrelated-schema invariants.

Complete MockMvc/runtime tests for:

- end-to-end email request, recording delivery, persisted active challenge, verify, refresh, logout, and deletion;
- frozen phone request/verify/JWT behavior over the unified store;
- auth-response defaults with non-empty interests and false preferences;
- full profile retaining actual interests/preferences;
- email-only JWT claim omission;
- admin endpoints/security;
- TIMEPAD representative payload mapping and idempotent meeting upsert;
- exhaustive logging markers for identifiers, code, device, IP, current/previous key IDs/material, JWT, refresh
  token, API/database/SMTP credentials, provider payload/message ID, and exception text.

## Configuration contract

Retain these Architecture defaults and bounds:

| Property | Default | Bounds/meaning |
| --- | ---: | --- |
| `app.otp.expiration-minutes` | 5 | 1–15; captured at pending creation |
| `app.otp.max-attempts-per-hour` | 5 | 1–100; per PHONE/EMAIL request identifier |
| `app.otp.rate-limit.window-minutes` | 60 | 1–1440 |
| `app.otp.rate-limit.ip-max-attempts` | 20 | 1–10000; aggregate channels |
| `app.otp.rate-limit.device-enabled` | false | controls request and verification device scopes |
| `app.otp.rate-limit.device-max-attempts` | 10 | 1–10000; aggregate channels |
| `app.otp.verification.window-minutes` | 15 | 1–1440 |
| `app.otp.verification.identifier-max-attempts` | 5 | 1–10; captured as challenge `max_attempts` |
| `app.otp.verification.ip-max-attempts` | 50 | 1–10000; aggregate channels |
| `app.otp.verification.device-max-attempts` | 10 | 1–10000 when enabled |

Client-IP configuration is `app.http.client-ip.trusted-proxy-cidrs` (default empty) and
`app.http.client-ip.max-forwarded-hops` (default 10). Production supplies only CIDRs controlled by the deployment.

Add positive bounded cleanup delay/batch properties and a 24-hour challenge retention property under `app.otp`.
Keep one owner for each value; do not introduce aliases.

Required approved environment names:

- `APP_EMAIL_PROVIDER`, `APP_EMAIL_FROM`, `APP_EMAIL_FROM_NAME`;
- `SPRING_MAIL_HOST`, `SPRING_MAIL_PORT`, `SPRING_MAIL_USERNAME`, `SPRING_MAIL_PASSWORD`;
- `APP_EMAIL_CONNECT_TIMEOUT_MS`, `APP_EMAIL_READ_TIMEOUT_MS`, `APP_EMAIL_WRITE_TIMEOUT_MS`;
- `APP_OTP_HMAC_CURRENT_KEY_ID`, `APP_OTP_HMAC_CURRENT_KEY_BASE64`;
- optional previous HMAC key ID/material during rotation.

Add bindings for trusted proxies and verification/cleanup properties using the same naming convention. Do not
commit generated values.

## Normative transaction and lock sequencing

### Request claim

```text
REQUIRES_NEW
  sorted request-subject advisory locks
  -> count with clock_timestamp()-window
  -> insert claims with attempted_at=clock_timestamp()
COMMIT
```

### Create pending

```text
TX
  identifier advisory lock
  -> sample clock_timestamp()
  -> INSERT PENDING ... RETURNING id
COMMIT
```

### Delivery and activation

```text
no DB transaction
  provider send

failure:
  TX conditional PENDING -> DELIVERY_FAILED

success:
  TX persisted-id lookup
    -> identifier advisory lock derived from persisted channel/identifier
    -> re-read row
    -> latest-ID and expiry checks
    -> conditional prior ACTIVE -> SUPERSEDED
    -> conditional PENDING -> ACTIVE with expires_at > clock_timestamp()
```

If the final activation predicate loses after supersession, roll back the transaction and mark the pending row
expired in a separate transaction.

### Verification

```text
TX
  identifier advisory lock
  -> active challenge FOR UPDATE
  -> sorted verification-subject advisory locks
  -> post-wait clock_timestamp() recheck and budget counts
  -> HMAC compare
  -> conditional challenge transition
  -> applicable failed-attempt inserts OR identity/user/token work
COMMIT

outside TX:
  Invalid -> channel-specific public 401
```

### Cleanup

```text
independent TX
  bounded eligible row selection FOR UPDATE SKIP LOCKED
  -> DELETE selected IDs
COMMIT
```

Cleanup never holds identifier or attempt-subject advisory locks.

## End-to-end acceptance criteria

Implementation is complete only when all of the following are true:

1. The approved email request/verify contracts are exact and account-enumeration-safe.
2. The frozen Android phone wire contract is unchanged.
3. Both channels use HMAC-only, single-active, single-use, expiring challenges with replay and attempt protection.
4. A usable challenge exists only after synchronous provider acceptance and successful activation.
5. Request order is based only on generated challenge ID.
6. Every OTP security time/window decision uses PostgreSQL wall time after relevant waits.
7. Request claims survive downstream failure; failed verification counters survive the public 401.
8. Expiry crossed during lock waits cannot activate, consume, or charge identifier/challenge failure state.
9. `auth_identities` is the only authentication ownership source; legacy profile emails are never auto-linked.
10. New email users have null phone; phone users and tokens retain phone compatibility.
11. Refresh tokens remain random, hashed at rest, rotated, and bound to monotonic `authVersion`.
12. Logout/deletion invalidate access and refresh credentials; restoration does not lower `authVersion`.
13. Production startup requires safe SMTP/HMAC configuration before infrastructure bean creation.
14. No OTP, identifier, IP, device ID, token, key material/ID, credential, provider payload/ID, request body, or
    provider exception detail is logged or reflected.
15. V6 is the only migration changed/added, revokes plaintext OTPs, and leaves unrelated schema behavior intact.
16. Cleanup is bounded and cannot deadlock request claims through crossed row/advisory lock order.
17. Operations documentation covers deliverability, suppression, key rotation, cutover, canary, and rollback.

## Verification commands

Run from the MEE2-23 worktree. Use Docker or the documented disposable external PostgreSQL variables.

### Focused unit/MVC tests

```bash
./gradlew test \
  --tests '*EmailAddressNormalizerTest' \
  --tests '*EmailOtpRequestValidatorTest' \
  --tests '*ClientRequestContextResolverTest' \
  --tests '*OtpHasherTest' \
  --tests '*OtpRequestCoordinatorTest' \
  --tests '*SmtpEmailOtpSenderTest' \
  --tests '*RuntimeConfigurationInitializerTest' \
  --tests '*AuthServiceTest' \
  --tests '*ErrorContractMvcTest' \
  --tests '*JwtServiceTest' \
  --tests '*UserServiceTest' \
  --tests '*AdminKeyAuthFilterMvcTest' \
  --tests '*TimepadProviderTest'
```

### Focused PostgreSQL tests

```bash
./gradlew postgresTest \
  --tests '*EmailOtpMigrationPostgresTest' \
  --tests '*OtpChallengeStorePostgresTest' \
  --tests '*OtpRateLimiterPostgresIntegrationTest' \
  --tests '*OtpVerificationPostgresIntegrationTest' \
  --tests '*OtpCleanupPostgresTest' \
  --tests '*MeetingUpsertServicePostgresTest' \
  --tests '*ApiMvcIntegrationTest'
```

### Required complete build evidence

```bash
./gradlew postgresTest
./gradlew test
./gradlew clean build
```

Release evidence must show a real `postgresTest` execution, not a skipped suite.

### Startup/runtime checks

With a disposable PostgreSQL database and generated runtime-only keys:

1. Start with no active profile and complete SMTP/HMAC settings; verify application startup/health without sending
   a message.
2. Repeat with exactly `prod`.
3. Start exactly `dev` and exactly `test` with their non-production values.
4. Verify mixed profiles such as `prod,dev` and `dev,test` fail.
5. Omit each required datasource/JWT/email/HMAC setting one at a time in default and `prod`; verify startup fails
   before datasource or SMTP connection attempts.
6. Supply each unsafe SMTP/key/sender/timeout/trusted-proxy form; verify a safe category-only failure.
7. Run one canary request/verify/refresh/logout flow against a controlled SMTP inbox and inspect logs for the
   exhaustive marker set.

Do not paste runtime credentials, generated keys, recipient addresses, OTPs, or tokens into build logs, task
comments, or committed documentation.

## Rollout and rollback

This is a stop-the-world auth cutover:

1. Confirm X-013/product approval and A-048 release coordination.
2. Complete provider/DNS/suppression/trusted-proxy/key-ring readiness.
3. Back up PostgreSQL and stop every old application instance and profile writer.
4. Deploy one artifact and run V6.
5. Start all instances with the same current/previous HMAC key ring.
6. Verify startup, health, a controlled email request/verify canary, phone compatibility, refresh rotation, and
   safe logs.
7. Re-enable public traffic only after all checks pass.

V6 intentionally revokes in-flight phone OTPs. Old binaries cannot use the new challenge schema.

- Before public traffic resumes, rollback may restore the pre-cutover database and old artifact.
- After post-cutover writes exist, use a forward-fix migration unless an authorized recovery owner explicitly
  accepts a database restore point and its data loss.
- Never recreate plaintext OTP storage in a down migration.
- Future HMAC rotation is two phase: distribute the future key as accepted secondary material, switch the current
  ID everywhere, wait longer than maximum OTP lifetime, then remove the old key. Mixed fleets without the full
  accepted key ring are prohibited.

## Final implementation review checklist

- [ ] Product approval of X-013 and Design/Architecture is recorded.
- [ ] Only V6 changes auth schema; V1–V5 remain byte-for-byte unchanged.
- [ ] No JPA `OtpCode`/`OtpRepository` remains.
- [ ] No auth path calls `findByPhone` or queries `users.email` for ownership.
- [ ] Provider calls occur outside transactions.
- [ ] Activation accepts only challenge ID and uses persisted lock data.
- [ ] Lock order and post-wait database time are covered by deterministic tests.
- [ ] Phone and email exact HTTP matrices pass.
- [ ] Refresh/logout/delete/restore/auth-version regressions pass.
- [ ] SMTP/startup and logging-safety matrices pass.
- [ ] Admin/TIMEPAD/meeting-upsert regressions pass.
- [ ] `postgresTest`, `test`, and `clean build` all pass.
- [ ] Operational readiness and rollback owners approve the cutover.
