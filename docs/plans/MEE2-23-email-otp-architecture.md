## Architecture result

**MEE2-23 — Email OTP backend**

Status: approved by independent plan and compliance review; implementation remains gated on normal workflow
product approval.

## Architecture checklist

- [x] Translate the workflow-approval candidate behavior into module and transaction boundaries.
- [x] Define public and internal contracts without changing the proposed X-013 candidate.
- [x] Define one source of truth for identities, challenges, attempts, clocks, and locks.
- [x] Define the PostgreSQL schema, migration, rollout, and rollback shape.
- [x] Define provider, configuration, observability, and cleanup boundaries.
- [x] Enumerate affected production and test areas.
- [x] Record rejected alternatives and explicit non-goals.
- [x] Incorporate independent architecture/compliance review.
- [x] Publish the `Architecture result` task comment and complete the workflow node.

## Architectural stance

Keep this as one Spring Boot/PostgreSQL modular monolith. Add a deep OTP-auth module inside the existing service,
domain, and repository conventions; do not add Redis, a queue, a second deployable, or a provider-specific email
SDK. PostgreSQL remains the source of truth for identity uniqueness, request ordering, challenge state, locking,
rate-limit attempts, and database time.

The proposed X-013 candidate and frozen phone wire contracts live in
`docs/plans/MEE2-23-email-otp-design.md`. This document decides how to implement them; it does not reopen endpoint,
message, error, normalization, or product semantics. Implementation remains gated until the workflow records
product approval of the Design and Architecture results.

## Component boundaries

### API boundary

Keep `AuthController` as the `/auth` adapter and add two methods:

- `POST /auth/email/send-otp` → `AuthService.sendEmailOtp`
- `POST /auth/email/verify-otp` → `AuthService.verifyEmailOtp`

The existing phone methods and response/error behavior remain. Both request and verification endpoints may read
the optional `X-Device-Id`; controllers never normalize identifiers, resolve proxies, generate OTPs, call
providers, or access repositories.

Add DTOs in `AuthDto.kt`:

- `SendEmailOtpRequest`
- `VerifyEmailOtpRequest`
- `OtpAcceptedResponse`

Email DTO fields are nullable with defaults so missing JSON does not fail Kotlin/Jackson construction:

```kotlin
data class SendEmailOtpRequest(val email: String? = null)
data class VerifyEmailOtpRequest(
    val email: String? = null,
    val code: String? = null,
    val name: String? = null,
    val surname: String? = null,
)
```

Do not put `@Email`, raw `@Size(max=254)`, or email regex constraints on these fields. A dedicated
`EmailOtpRequestValidator` applies deterministic validation in this order:

1. null/blank-after-`String.strip()` email → `Email is required`;
2. canonicalize and validate email → malformed message or canonical 254-character boundary message;
3. validate optional device header;
4. for verify, validate six-digit code, then name, then surname.

It returns a normalized application command. The controller does not use Bean Validation for the email DTOs;
the existing phone DTO validation remains unchanged. JPA entities are never serialized directly.

`ApiExceptionHandler` and `ApiError` retain the current envelope. Add email-specific `ApiException` subclasses:

- `EmailOtpRateLimitedException` → 429 `OTP_RATE_LIMITED`
- `EmailOtpDeliveryUnavailableException` → 503 `OTP_DELIVERY_UNAVAILABLE`
- `EmailOtpActivationUnavailableException` → 503 `OTP_ACTIVATION_UNAVAILABLE`
- `EmailOtpInvalidException` → 401 `OTP_INVALID_OR_EXPIRED`

Phone paths continue mapping the same internal outcomes to `RATE_LIMITED`, `SMS_UNAVAILABLE`, and `UNAUTHORIZED`.
Infrastructure exceptions never escape into the API envelope.

### Application boundary

Keep `AuthService` as the public application facade. It owns channel-specific API mapping and the existing
refresh/logout operations, but delegates OTP mechanics:

```text
AuthController
  -> AuthService
       -> AuthIdentifierNormalizer
       -> OtpRequestCoordinator
       -> OtpVerificationExecutor
       -> RefreshTokenRepository / existing refresh and logout path
```

`AuthService` methods:

- `sendOtp(phone, context)` keeps the existing phone-facing signature/behavior.
- `sendEmailOtp(email, context)` maps request outcomes to X-013.
- `verifyOtp(phoneRequest, context)` keeps the phone wire contract.
- `verifyEmailOtp(emailRequest, context)` maps invalid outcomes to the email 401.
- `refreshToken` and `logout` remain transactionally equivalent to the current implementation.

No send method is `@Transactional`; SMTP/SMS calls must not hold database transactions.

### OTP request coordinator

`OtpRequestCoordinator` is non-transactional and channel-neutral. Its dependencies are:

- `OtpRequestRateLimiter`
- `OtpCodeGenerator`
- `OtpHasher`
- `OtpChallengeLifecycle`
- `OtpDeliveryRouter`

Its only responsibility is the request sequence:

1. claim request quotas;
2. generate sensitive code material;
3. create `PENDING`;
4. call the delivery boundary;
5. compensate delivery failure or activate provider acceptance;
6. return an internal `OtpRequestOutcome`.

`OtpChallengeLifecycle` is a separate proxied Spring bean so each public method gets its own short transaction:

- `createPending(command): PendingChallenge`
- `markDeliveryFailed(challengeId)`
- `activate(challengeId): ActivationOutcome`

Do not place these `@Transactional` methods on `OtpRequestCoordinator`; self-invocation would silently remove the
required transaction boundaries.

### OTP verification executor

`OtpVerificationExecutor.verify(command): VerificationOutcome` owns one transaction covering:

- the identifier advisory lock;
- active-challenge lock and database-time expiry decision;
- verification budget checks and failed-attempt writes;
- constant-time HMAC comparison;
- `ACTIVE -> CONSUMED` or `ACTIVE -> EXHAUSTED`;
- auth-identity lookup/creation;
- soft-delete restoration;
- access-token creation and hashed refresh-token insertion.

Expected invalid verification returns `VerificationOutcome.Invalid` from the transaction. The outer `AuthService`
throws the public channel-specific 401 only after the transaction commits, so failed counters are not rolled back.

Successful consumption, identity/user changes, and refresh-token insertion remain in one transaction. Any
downstream database failure rolls all of them back and leaves the challenge usable for a safe retry.

### Token issuance and DTO mapping

Extract the current private token code to `AuthTokenIssuer`, which joins the caller transaction and:

- generates the access token;
- generates a 32-byte random refresh token;
- persists only its SHA-256 hash and current `authVersion`;
- returns `AuthResponse`.

Centralize common `User -> UserProfileDto` field mapping in one mapper, but keep two explicit projections:

- `toAuthProfileDto`: preserves the current auth response behavior, including default empty interests and default
  preference values even when the entity differs;
- `toFullProfileDto`: preserves `UserService` behavior with actual interests and preferences.

Do not unify these observably different projections without separate product approval. No entity is exposed.

`JwtService.generateAccessToken` accepts nullable phone:

- phone-auth tokens retain `sub`, `phone`, and `av`;
- email-only tokens contain `sub` and `av`, with no email claim and no null `phone` claim.

## Domain contracts

### Authentication identifier

Use one strongly typed internal value with no public canonical-value constructor:

```kotlin
class AuthIdentifier private constructor(
    val channel: AuthChannel,
    internal val canonicalValue: String,
) {
    override fun toString(): String = "AuthIdentifier(channel=$channel)"

    companion object {
        fun fromPhone(raw: String): AuthIdentifier
        fun fromEmail(raw: String?): AuthIdentifier
    }
}
```

The companion factories delegate to:

- `PhoneNumberNormalizer`, preserving current normalization;
- `EmailAddressNormalizer`, implementing the design-defined exact grammar.

Do not accept raw strings in challenge, identity, lock, hash, or limit APIs. This prevents a caller from using a
different normalization rule. `channel` and `canonicalValue` are immutable after construction and after database
insertion. `toString()` never reveals the value.

### Request context

Replace `userAgent` with explicit device identity:

```kotlin
data class OtpRequestContext(
    val clientIp: NormalizedIp?,
    val deviceId: DeviceId?,
)
```

`ClientRequestContextResolver` composes:

- `ClientIpResolver`, with the design-defined trusted-proxy algorithm;
- `DeviceIdParser`, with the approved safe ASCII grammar.

User-Agent is never a device identifier. Device ID is supplemental and attacker-controlled, never an
authentication credential.

### Sensitive OTP material

`OtpCodeGenerator` uses the existing process-wide `SecureRandom` and emits `000000..999999`.

Represent the raw code with a non-data sensitive wrapper whose `toString()` is redacted. Do the same for SMTP
credentials/HMAC key material where application types hold them. Raw OTP lifetime is limited to:

1. generation;
2. HMAC calculation;
3. delivery call;
4. stack-frame release.

It is never persisted, included in an exception message, or passed to logging.

`OtpHasher` owns:

- exact `meet-otp-v1` framing;
- 16-byte salt generation;
- current/previous key lookup by `hash_key_id`;
- HMAC-SHA-256;
- `MessageDigest.isEqual`.

Callers cannot access decoded HMAC key bytes.

### Challenge state machine

Replace the current JPA-managed `OtpCode` with an immutable, non-JPA `OtpChallengeSnapshot` returned only by
`OtpChallengeStore`. The `otp_codes` table has one persistence owner: the JDBC store. Do not retain a second JPA
repository/entity for challenge writes. Flyway and PostgreSQL integration tests validate this table.

Legal transitions are:

```text
PENDING -> ACTIVE | DELIVERY_FAILED | SUPERSEDED | EXPIRED
ACTIVE  -> CONSUMED | EXHAUSTED | SUPERSEDED | EXPIRED
terminal states have no outgoing transition
```

Invariants:

- only `ACTIVE` is usable;
- at most one `ACTIVE` row exists per `(channel, identifier)`;
- the greatest request ID is the only `PENDING` row eligible to activate;
- activation never supersedes the prior active row unless the pending row is still unexpired;
- all security decisions use PostgreSQL wall time sampled after relevant waits with `clock_timestamp()`;
- verification and activation share one advisory-lock key function;
- terminal-state updates are conditional on the expected prior state, making retries idempotent.

Internal outcomes are closed types, not exception/string protocols:

```text
ActivationOutcome = Activated | Superseded | Expired
VerificationOutcome = Authenticated(AuthResponse) | Invalid
OtpRequestOutcome = Accepted | DeliveryUnavailable | ActivationUnavailable | PersistenceUnavailable
```

Delivery failure is an internal typed exception from the provider boundary and is mapped by `AuthService`.

### Authentication identity

`AuthIdentity` is the sole login mapping:

```text
(type, normalized_identifier) -> user_id
```

Neither verification nor migration queries `users.email` to infer account ownership. New identities are created
only after valid challenge consumption while holding the same identifier advisory lock.

For new users:

- PHONE sets `users.phone`, leaves profile email null;
- EMAIL sets `users.email`, leaves phone null.

Existing soft-deleted users are restored through the identity. `users.phone` and `users.email` remain profile
fields; `auth_identities` remains the authentication source of truth.

For an existing identity, verification loads the user with `UserRepository.findWithLockById` before restoration
or token issuance. This serializes verification with logout/account deletion and guarantees tokens use the
committed current `authVersion`.

## Persistence boundary

### JPA repositories

Keep JPA for aggregate persistence:

- `AuthIdentityRepository`
- `UserRepository`
- `RefreshTokenRepository`

`AuthIdentityRepository` exposes lookups only by `(type, normalizedIdentifier)` and `(userId, type)`. The
transaction-level advisory lock, not a caught unique violation, serializes first identity creation. The unique
constraint remains a final invariant.

### PostgreSQL OTP stores

Use narrow JDBC-backed repositories for PostgreSQL-specific behavior rather than spreading native SQL through
services:

- `OtpChallengeStore`
- `OtpAttemptStore`
- `OtpIdentifierLock`

`OtpChallengeStore` owns `INSERT ... RETURNING`, conditional state transitions, active-row `FOR UPDATE`, database
time predicates, latest-ID checks, and bounded `SKIP LOCKED` cleanup. It returns
`OtpChallengeSnapshot`, never JPA entities or API DTOs.

After the relevant advisory/row locks are held, the store samples wall time with `SELECT clock_timestamp()`. It
uses that database-sourced instant for the operation. Final `PENDING -> ACTIVE` and `ACTIVE -> CONSUMED` SQL is
also conditional on `expires_at > clock_timestamp()` so a lock/processing delay that crosses expiry cannot
activate or consume the code. A failed final condition returns an expired/invalid outcome; activation rolls back
any prior-active supersession before marking the pending row `EXPIRED` in a separate short transaction.

`OtpAttemptStore` owns hashed attempt subjects, sorted advisory-lock acquisition, count/insert operations, and
does not start transactions. After all applicable advisory locks are held, attempt insertion explicitly writes
`attempted_at = clock_timestamp()`. Counts and deletion cutoffs are SQL expressions based on `clock_timestamp()`;
its API accepts window durations, never a JVM `Clock`, `now`, or calculated cutoff.

`OtpIdentifierLock` is the only component that derives:

```text
meet-otp-identifier-v1:<CHANNEL>:<canonicalIdentifier>
```

and executes `pg_advisory_xact_lock(hashtextextended(?, 0))`.

Activation accepts only `challengeId`. Inside its transaction it:

1. reads the immutable persisted channel/identifier without locking the row;
2. derives/acquires the shared advisory lock from that persisted value;
3. re-reads the row and performs the conditional latest/expiry transition.

No caller can supply a lock identifier separately from the persisted challenge. A mismatched lock namespace is
therefore unrepresentable through the lifecycle API.

Business services depend on these narrow stores, not raw `JdbcTemplate`. This keeps PostgreSQL-specific
concurrency and SQL testable as one module and prevents multiple lock namespaces.

### Rate-limit transaction ownership

Split the current `OtpRateLimiter` into:

- `OtpRequestRateLimiter`: wraps `OtpAttemptStore` in `REQUIRES_NEW`, preserving committed send claims even when
  delivery later fails;
- `OtpVerificationLimiter`: assumes the caller transaction owned by `OtpVerificationExecutor`.

Attempt scopes:

```text
request: phone | email | ip | device
verify:  verify_phone | verify_email | verify_ip | verify_device
```

Verification ordering:

1. identifier advisory lock;
2. active challenge row lock;
3. build IP/device scopes and tentatively add the identifier scope only for the observed active challenge;
4. sort and acquire attempt advisory locks;
5. resample `clock_timestamp()` after all waits and recheck challenge status/expiry;
6. if expired, remove the identifier scope and charge only IP/device on failure;
7. reject an already exhausted still-applicable budget;
8. compare HMAC;
9. record failed scopes and increment/exhaust the challenge only on failure.

Mismatch and `ACTIVE -> EXHAUSTED` SQL is conditional on
`status = 'ACTIVE' AND expires_at > clock_timestamp()`. If that final condition loses because expiry was crossed,
the transaction records only IP/device failure and returns `Invalid`; it never records an identifier failure.
Successful consume has the same final condition. A correct submission that crosses expiry while waiting likewise
records the applicable IP/device failure and returns `Invalid`.

Unknown/no-active submissions charge only IP/device scopes and cannot pre-lock a future identifier. A resend
cannot bypass an exhausted identifier scope because that scope is checked before accepting a correct code.

Universal lock order is normative:

- request claim: sorted request-subject advisory locks → count → insert;
- verification: identifier advisory lock → active challenge row → sorted verification-subject advisory locks →
  count/insert;
- global attempt cleanup: row locks only in an independent transaction, with no identifier or subject advisory
  lock held.

Claims do not run global cleanup and do not delete expired subject rows; cutoff predicates simply ignore them.
`OtpAttemptCleanupJob` performs bounded `FOR UPDATE SKIP LOCKED` deletion using
`clock_timestamp() - max(requestWindow, verificationWindow)`. This removes the current crossed-row deadlock risk.

Each query uses its own request or verification cutoff. Cleanup retains rows for at least the larger configured
window so the 15-minute and 60-minute budgets cannot delete data needed by each other.

## Delivery boundary

Keep the existing `SmsSender`. Add:

```kotlin
interface EmailOtpSender {
    fun send(message: EmailOtpMessage)
}
```

Implementations:

- `SmtpEmailOtpSender`: non-dev/test production adapter over `JavaMailSender`;
- `FakeEmailOtpSender`: dev/test-only no-op;
- `UnavailableEmailOtpSender`: dev/test disabled adapter that throws a safe internal delivery failure;
- test-only `RecordingEmailOtpSender` in `src/test`, never production code.

`OtpDeliveryRouter` depends on both `SmsSender` and `EmailOtpSender` and dispatches by `AuthChannel`. This retains
the existing SMS boundary while keeping request coordination channel-neutral.

`SmtpEmailOtpSender`:

- builds fixed server-owned plain-text content and subject;
- accepts no caller-controlled subject/template/body;
- enables SMTP auth and required STARTTLS;
- requires certificate hostname verification;
- rejects trust-all/custom socket factories;
- uses finite connect/read/write timeouts;
- performs no automatic retry, preventing duplicate OTP mail;
- converts all provider exceptions to a safe reason enum without carrying provider text into public errors/logs.

Provider acceptance is the synchronous successful return from `JavaMailSender`; asynchronous bounce remains an
operations concern and does not mutate challenge state.

## Configuration boundary

Add validated configuration properties:

- `EmailProperties`
- `OtpHashProperties`
- expanded `OtpProperties` / `OtpRateLimitProperties`
- `ClientIpProperties`

Register them in `MeetBackendApplication`.

Rate-limit configuration is explicit and has one owner:

| Property | Default | Validation | Scope behavior |
| --- | ---: | --- | --- |
| `app.otp.expiration-minutes` | 5 | 1–15 | pending/active challenge lifetime captured at creation |
| `app.otp.max-attempts-per-hour` | 5 | 1–100 | request identifier, separate PHONE/EMAIL scopes |
| `app.otp.rate-limit.window-minutes` | 60 | 1–1440 | all request scopes |
| `app.otp.rate-limit.ip-max-attempts` | 20 | 1–10000 | aggregates PHONE and EMAIL request traffic |
| `app.otp.rate-limit.device-enabled` | false | boolean | controls both request and verification device scopes |
| `app.otp.rate-limit.device-max-attempts` | 10 | 1–10000 | aggregates PHONE and EMAIL request traffic |
| `app.otp.verification.window-minutes` | 15 | 1–1440 | all failed-verification scopes |
| `app.otp.verification.identifier-max-attempts` | 5 | 1–10 | separate PHONE/EMAIL scope; also captured as challenge `max_attempts` |
| `app.otp.verification.ip-max-attempts` | 50 | 1–10000 | aggregates PHONE and EMAIL failures |
| `app.otp.verification.device-max-attempts` | 10 | 1–10000 | aggregates PHONE and EMAIL failures when enabled |

Present device IDs are validated even when device limiting is disabled; disabling only omits the device claim.

Replace the narrowly named `JwtConfigurationInitializer` with one `RuntimeConfigurationInitializer` and update
the existing registration. This is the single pre-bean fail-fast source for datasource, JWT, admin/SMS safety,
email, HMAC, SMTP TLS, sender, timeout, key-ring, profile, and trusted-proxy property validation.

Validation rules have one implementation:

- ordinary scalar constraints live once on their configuration property type;
- each security-sensitive group exposes one pure factory/validator (`OtpKeyRing.from`,
  `SmtpRuntimeSettings.from`, `TrustedProxySet.from`);
- one `RuntimeConfigurationValidator` owns cross-group/profile rules;
- the initializer binds raw properties and invokes those same factories/validator;
- runtime beans consume the resulting property types/factories rather than reimplementing checks.

Do not duplicate a rule in annotations, an `init` block, the initializer, and a bean. Where this task touches the
existing duplicated JWT startup checks, retain one constructor/factory owner and let the initializer only bind it.

Production mode is every active-profile set except exactly `dev` or exactly `test`; an empty profile set is
production. Reject mixed profiles such as `prod,dev` so a dev profile cannot weaken production checks.

Blank `ADMIN_API_KEY` remains valid startup configuration and keeps `/admin/**` closed through the existing
filter; this task adds no admin availability requirement. The existing dev-only fake-SMS restriction remains.

Configuration files:

- `application.yml`: placeholders/defaults only;
- `application-dev.yml`: fake providers and explicit dev-only HMAC key;
- `src/test/resources/application.yml`: explicit `test` profile and test-only values;
- `.env.example`: variable names and non-secret guidance only.

No credential, decoded key, provider payload, or recipient is included in validation error text.

## Database migration

Add exactly one next monotonic migration, `V6__email_otp_authentication.sql`; do not edit V1–V5.

The migration is transactional and:

1. creates `auth_identities`;
2. backfills PHONE identities from every non-null `users.phone`;
3. does not inspect, normalize, deduplicate, or backfill `users.email`;
4. drops `NOT NULL` from `users.phone` while retaining uniqueness for non-null values;
5. deletes all short-lived legacy `otp_codes`;
6. converts `otp_codes` to the constrained challenge schema;
7. creates `(channel, identifier, id DESC)` for latest-request lookup and the unique-active index;
8. extends the rate-limit scope constraint for email and verification scopes.

Required challenge constraints:

- valid channel/status enums;
- 254-character nonblank identifier;
- 32-byte HMAC and 16-byte salt;
- safe nonblank key ID;
- `0 <= failed_attempts <= max_attempts`;
- `1 <= max_attempts <= 10`;
- partial unique active index.
- `(channel, identifier, id DESC)` latest-request index; `created_at` is never used for request ordering.
- `(status, expires_at, id)` cleanup index.

No meeting, TIMEPAD, ingestion, admin, or unrelated schema changes are allowed.

`auth_identities` DDL is fixed:

- `id BIGSERIAL PRIMARY KEY`;
- `user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE`;
- `type VARCHAR(16) NOT NULL CHECK (type IN ('PHONE', 'EMAIL'))`;
- `normalized_identifier VARCHAR(254) NOT NULL` with a nonblank check;
- `created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP`;
- `UNIQUE (type, normalized_identifier)`;
- `UNIQUE (user_id, type)`.

Migration integration tests assert every column, FK action, check, unique constraint, and backing index.

Activation eligibility is `NOT EXISTS` a same-channel/identifier row with `id > :challengeId` across all
statuses. `created_at` is audit data only and never participates in latest-request selection.

## Data flows and transaction boundaries

### Request email OTP

```text
HTTP validation/context
  -> canonical email
  -> REQUIRES_NEW request quota claim
  -> generate raw code + HMAC material
  -> TX create PENDING using DB time
     -> failure before provider call: generic 500 INTERNAL_ERROR
  -> SMTP without DB transaction
     -> failure: TX PENDING -> DELIVERY_FAILED; 503 delivery unavailable
     -> accepted: TX shared lock + latest/expiry check
          -> latest/unexpired: prior ACTIVE -> SUPERSEDED, PENDING -> ACTIVE; 202
          -> older request: PENDING -> SUPERSEDED; 202
          -> expired: PENDING -> EXPIRED; 503 activation unavailable
          -> DB failure: PENDING stays unusable; 503 activation unavailable
```

No account query occurs in this flow.

### Verify email OTP

```text
HTTP validation/context
  -> canonical email
  -> TX shared identifier lock
     -> lock active challenge and evaluate DB expiry
     -> lock/check IP/device budgets
     -> when active: lock/check resend-resistant identifier budget
     -> unavailable/exhausted: Invalid
     -> wrong: write failed budgets + increment/exhaust challenge; Invalid
     -> correct:
          ACTIVE -> CONSUMED
          find identity
          restore user or create email-only user + identity
          issue JWT + persist hashed refresh token
          Authenticated(AuthResponse)
  -> outside TX map Invalid to exact 401
```

Phone request/verification use the same flow with `PHONE`, `SmsSender`, phone normalization, and legacy public
error mapping. PHONE pending-insert failure, activation database failure, or activation-after-expiry returns the
existing generic `500 INTERNAL_ERROR` envelope (`An unexpected error occurred`) with no `Retry-After`; no new
phone-specific error code is introduced.

### Concurrency

The shared identifier lock serializes pending creation, activation, verification, and first identity creation for
one identifier. Rate keys are separately sorted before acquisition. Request rate scopes and verification scopes
are disjoint, preventing a lock-order cycle with the identifier lock.

The unique-active index is a database invariant, not the primary concurrency mechanism. Constraint violations are
bugs or unexpected races and cause transaction rollback; code does not catch a PostgreSQL violation and continue
inside the aborted transaction.

## Failure handling

| Failure | Internal handling | Public behavior |
| --- | --- | --- |
| Invalid email/device/code shape | Reject before application flow | Exact 400 `BAD_REQUEST` |
| Request quota exhausted | `OtpRequestRateLimiter` rejects before persistence/delivery | Email 429 `OTP_RATE_LIMITED`; legacy phone 429 `RATE_LIMITED` |
| Pending insert unavailable | Do not call provider | Email and phone: exact generic 500 `INTERNAL_ERROR`, `An unexpected error occurred`, no `Retry-After` |
| SMTP/SMS synchronous failure | Best-effort terminal compensation; no active challenge | Email 503 `OTP_DELIVERY_UNAVAILABLE`; legacy SMS error unchanged |
| Provider accepted, activation DB failure | Leave pending unusable; preserve prior active | Email 503 `OTP_ACTIVATION_UNAVAILABLE`; phone exact generic 500 `INTERNAL_ERROR` |
| Activation after expiry | `PENDING -> EXPIRED`; preserve prior active | Email 503 `OTP_ACTIVATION_UNAVAILABLE`; phone exact generic 500 `INTERNAL_ERROR` |
| Older concurrent request finishes late | `PENDING -> SUPERSEDED` | Accepted response; newest request controls |
| Unknown/expired/wrong/exhausted/replay | Commit applicable failed counters; no identity lookup | Uniform channel-specific 401 |
| Refresh/token persistence failure after correct OTP | Roll back consume/user/identity/token transaction | Existing generic 500; safe retry remains possible |
| Unique identity/active invariant violation | Roll back transaction; do not query in aborted transaction | Existing generic 500 |
| Cleanup failure | Leave rows for next bounded run; safe category log only | No request impact |
| Missing/unsafe production config | Fail initializer before datasource/provider beans | Process does not start |

Do not automatically retry SMTP. Database transactions may use the datasource's normal deadlock/serialization
failure behavior; no unbounded retry loop is added. A caller may safely request another code after a generic
activation failure.

## Cleanup and retention

Add `OtpChallengeCleanupJob` under existing scheduling:

- fixed delay from configuration;
- one transaction per bounded batch;
- `FOR UPDATE SKIP LOCKED`;
- delete any challenge whose `expires_at` is more than 24 hours old, including an expired row still marked
  `ACTIVE`, plus terminal/stale pending rows past retention;
- default batch 1,000;
- no identifiers/hashes in logs.

Add `OtpAttemptCleanupJob` as a separate bounded transaction:

- it holds no identifier or subject advisory locks;
- it selects only globally expired attempt rows with `FOR UPDATE SKIP LOCKED`;
- its SQL cutoff uses PostgreSQL `clock_timestamp()` and the maximum configured request/verification window;
- request/verification paths never invoke it.

Neither cleanup path performs an unbounded delete.

## Observability

Use safe event names and low-cardinality categories only:

- request rate limited;
- provider accepted/failed by safe reason category;
- activation activated/superseded/expired/failed;
- verification accepted/invalid/exhausted;
- cleanup count;
- startup validation category.

Never log identifiers, addresses, device IDs, IPs, codes, hashes, salts, HMAC key IDs, tokens, credentials, SMTP
headers/body/message IDs, provider exception text, or request bodies. The allow-list is exhaustive for this
ticket: route/event name, provider kind, latency, safe outcome category, and numeric counters only. Existing
source and runtime marker tests remain the enforcement mechanism and include current/previous key-ID markers.

Do not add an observability backend or actuator dependency in this ticket.

## Affected areas

### Production

- `build.gradle.kts`: Spring Mail starter
- `MeetBackendApplication.kt`: property registration and initializer rename
- `api/controller/AuthController.kt`
- `api/dto/AuthDto.kt`
- `api/error/ApiError.kt`
- `service/AuthService.kt`
- new `service/auth/identifier/*`
- new `service/auth/otp/*`
- new `service/email/*`
- `service/OtpRequestContext.kt` and replacement/generalization of `OtpRateLimiter.kt`
- `domain/entity/AuthEntity.kt` and `User.kt`
- `domain/repository/AuthRepository.kt` and `UserRepository.kt`
- `security/JwtService.kt`
- `config/*Properties.kt` and runtime initializer
- `application.yml`, `application-dev.yml`, `.env.example`
- `db/migration/V6__email_otp_authentication.sql`
- README/production email deliverability documentation

`SecurityConfig` should require no rule change because `/auth/**` is already public; add a regression assertion
rather than modifying admin authorization.

### Tests

- existing `AuthServiceTest`, `ErrorContractMvcTest`, `ApiMvcIntegrationTest`
- existing JWT/startup, logging-safety, admin, user-service, and rate-limit tests
- new normalizer, context/IP resolver, HMAC/key-ring, request coordinator, SMTP adapter, cleanup, and migration tests
- PostgreSQL race tests for active uniqueness, request ordering, activation-vs-verification, failed-attempt commit,
  resend-resistant budgets, identity creation, and cleanup
- test-only recording email/SMS delivery adapters
- shared PostgreSQL test utility extracted from current integration support when needed
- TIMEPAD mapping and `(source, sourceExternalId)` idempotent-upsert regression coverage

Required contract/security cases are not optional:

- exact phone and email status/body/code/message/header assertions, including absent `Retry-After`;
- missing/null/blank/whitespace email, IDN, canonical 254/255 boundaries, malformed device ID, and no reflected
  submitted values;
- no account lookup during send and no `users.email` ownership lookup during verification;
- exact numeric request/verification quotas, resend-resistant identifier budget, and concurrent boundary claims;
- activation derives its lock only from persisted immutable identifier data; a mismatched caller lock cannot be
  constructed;
- activation and verification waits deliberately cross expiry; neither final transition accepts an expired code;
- wrong and correct submissions whose attempt-lock wait crosses expiry charge only IP/device, never the identifier
  or challenge row; a subsequent resend inherits no identifier failure from the expired challenge;
- attempt inserts/counts/window edges use a post-lock `clock_timestamp()` sample only, including waits crossing
  the rate-window boundary;
- two disjoint claims with crossed expired rows plus concurrent cleanup complete without deadlock or transient 500;
- SMTP STARTTLS, peer identity, trust-all rejection, timeout bounds, strict sender, and secret-safe startup errors;
- refresh rotation, logout, deletion, restoration, and monotonic `authVersion`;
- phone auth with non-empty interests and false preferences retains the current auth-response default projection,
  while profile endpoints retain full entity values;
- startup validates `app.otp.expiration-minutes` at 1/5/15 and rejects 0/16; PostgreSQL persists the configured
  lifetime from its post-lock wall-clock sample;
- V5-shaped migration, plaintext revocation, phone-only identity backfill, every identity/challenge constraint,
  and unrelated-schema non-change;
- `/admin/ingest`, `/admin/purge`, TIMEPAD mapping, and idempotent upsert;
- exhaustive marker paths for recipient/code/device, current/previous key IDs/material, JWT/refresh token,
  credentials, provider payload/message ID, and exception text.

## Verification architecture

Use three layers:

1. Pure unit tests for normalization, parsing, HMAC framing/key selection, status outcomes, and API mapping.
2. PostgreSQL integration tests for every lock, transaction, migration, budget, state, and cleanup invariant.
3. Full Spring MockMvc integration for exact phone/email contracts, token lifecycle, security filters, and safe
   startup/runtime behavior.

Consolidate the duplicated PostgreSQL harness into one shared test utility. PostgreSQL tests carry a JUnit tag and
run through a dedicated Gradle `postgresTest` task. That task fails—not skips—when neither Docker nor
`TEST_POSTGRES_JDBC_URL` is available. The normal local `test` task may retain an explicit developer opt-out, but
release evidence must show `postgresTest` executed.

The implementation stage must run focused tests, `./gradlew postgresTest`, `./gradlew test`, and
`./gradlew clean build`, then perform default/`prod` startup success and missing-setting fail-fast checks. This
Architecture node changes documentation only, so it does not rerun the production build already passed in
preflight.

## Rollout and rollback

This is a coordinated stop-the-world auth schema cutover, not an expand/contract migration:

1. Complete the explicit provider/DNS readiness checklist: verified From domain, SPF, DKIM, DMARC, bounce/return
   path, suppression/complaint handling, SMTP credentials, HMAC key ring, and trusted-proxy CIDRs.
2. Back up PostgreSQL and stop every old application instance/profile writer.
3. Deploy one artifact and run V6.
4. Start all instances with the same current/previous HMAC key ring.
5. Verify startup, health, a canary request/verify flow, refresh rotation, and safe logs.
6. Re-enable public traffic.

V6 intentionally revokes in-flight phone OTPs. Old binaries cannot run against the new challenge schema. Before
public traffic is re-enabled, rollback may use the pre-cutover database restore. Once post-cutover writes exist,
rollback requires a forward-fix migration unless an authorized recovery owner explicitly approves the chosen
recovery point and resulting data loss. Never recreate plaintext OTP storage as a down migration.

Future HMAC rotation uses the design-defined two-phase key-ring rollout. Mixed fleets that cannot verify both current
and previous IDs are prohibited.

## Rejected alternatives

- **Polymorphic existing phone DTO/endpoints:** rejected because optional `phone`/`email` fields create ambiguous
  validation and risk Android breakage; dedicated email endpoints are additive.
- **Remove phone login:** rejected as outside X-013 and incompatible with existing Android users.
- **Use/backfill `users.email` as login identity:** rejected because profile emails have no verification
  provenance.
- **Plain SHA-256 or encrypted plaintext OTP storage:** rejected because a six-digit space is cheaply enumerable
  offline or recoverable with a storage key; keyed HMAC stores only verification material.
- **Persist ACTIVE before provider delivery:** rejected because a crash/provider failure can leave a usable code
  that was never delivered.
- **Send before any persistence:** rejected because concurrent request order is undefined and cannot guarantee one
  active newest request.
- **Hold a database transaction during SMTP:** rejected because external latency would pin connections/locks.
- **Multiple active challenges:** rejected because it amplifies online guessing and makes resend ordering ambiguous.
- **Catch unique violations and continue:** rejected because PostgreSQL aborts the transaction; advisory locking is
  the normal race-control mechanism.
- **Outbox/worker:** rejected because it either persists recoverable OTP content or adds encryption, a worker, and
  asynchronous contract complexity not needed for one synchronous provider.
- **Redis rate limiting:** rejected because PostgreSQL already supplies durable counters and concurrency control;
  another production dependency is unnecessary.
- **Provider-specific HTTP SDK:** rejected because no provider-specific contract is approved and SMTP satisfies the
  production boundary with fewer lock-in surfaces.
- **Trust forwarding headers directly:** rejected because clients could evade IP limits.
- **User-Agent as device identity:** rejected because it is shared, unstable, and spoofable.
- **Automatic SMTP retry:** rejected because it can send duplicate codes after ambiguous provider outcomes.
- **Return 202 for every provider failure:** rejected because mailbox-opacity is an explicit non-goal and X-013
  defines generic 503 delivery/activation failures.

## Explicit non-goals

- Android client/UI changes.
- Phone-login retirement.
- Legacy email-account linking or profile email-change verification.
- Bounce/complaint webhooks or local suppression storage.
- Mailbox/deliverability-enumeration opacity.
- New auth methods or MFA.
- A new service, queue, cache, metrics backend, or secret manager.
- Changes to admin policy, refresh semantics, account deletion, TIMEPAD packages/mapping, meeting upsert identity,
  or unrelated APIs.
