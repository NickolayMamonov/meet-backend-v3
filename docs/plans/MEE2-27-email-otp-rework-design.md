# MEE2-27 — Email OTP rework design

## Status and checklist

This design is a bounded integration and hardening plan for the already implemented MEE2-23 email OTP work.
It does not reopen the approved MEE2-23 product contract.

- [x] Confirm the clean stale baseline and required commit order.
- [x] Identify overlapping current-dev changes and define their merge result.
- [x] Preserve the email and phone authentication contracts and security invariants.
- [x] Define a monotonic cleanup-index migration.
- [x] Define representative-volume PostgreSQL query-plan coverage.
- [x] Define documentation correction, verification, rollout, rollback, and non-goals.
- [ ] Implementation integrates `origin/MEE2-23` at `681c09b` first.
- [ ] Implementation integrates `origin/dev` at `ebb6955` second.
- [ ] Implementation adds the bounded cleanup index/test rework and README correction.
- [ ] Implementation completes the verification matrix and opens the replacement PR.

## Baseline and authority

The managed branch starts clean at stale `d3b34d7f77f3e3f60858a594ff434e36394a0564`, the common ancestor of
the two required inputs:

- `origin/MEE2-23` at `681c09b76e2ea33c58557daeb76cd48774e88638` contains the existing B-056
  implementation and its reviewed design, architecture, operations, and tests.
- `origin/dev` at `ebb69550950cf96670f6aa084a3aa2cb3e96af90` contains the current atomic avatar
  replacement and storage behavior.

The MEE2-23 authority order is:

1. production code and tests at `681c09b`;
2. `docs/plans/MEE2-23-email-otp-architecture.md` and
   `docs/plans/MEE2-23-email-otp-implementation.md`, whose resolved contradictions supersede earlier design
   decisions;
3. `docs/plans/MEE2-23-email-otp-design.md` for product/API decisions not superseded by those later artifacts.

In particular, preserve JDBC-only challenge ownership, ID-based request ordering, persisted-data-derived activation
locks, post-wait PostgreSQL `clock_timestamp()`, the shared lock order, and separate auth/full-profile DTO
projections. Do not reintroduce superseded `created_at` ordering, transaction-start time, or JPA challenge
ownership.

The current `dev` commit is the authority for avatar replacement and storage behavior. This task only combines
those authorities and repairs the cleanup access path and README discrepancy identified during recon.

## Integration design

### Commit order

1. Fetch and verify both remote commit IDs.
2. Integrate `origin/MEE2-23` first. Because it descends directly from the stale task baseline, the expected result
   is a fast-forward that retains commits `3851feb`, `6ef2b05`, and `681c09b` unchanged.
3. Integrate `origin/dev` second with a normal merge commit. Do not rebase or force-push either source history.
4. Resolve only the overlapping files, then inspect the complete merge diff against both parents before adding
   the cleanup rework.
5. Immediately before final verification and PR creation, fetch `origin/dev` again. If it is still `ebb6955`,
   proceed. If it advanced, inspect the intervening commits, integrate the new tip without rewriting history,
   repeat overlap analysis, and rerun affected verification. If that integration materially changes approved
   scope, stop for an explicit product/architecture decision instead of claiming mergeability against stale
   `dev`.

This order makes the replacement branch visibly preserve B-056 instead of recreating it and gives the current
`dev` avatar changes an auditable merge parent.

### Required overlap results

`build.gradle.kts` must retain both branches' additive build behavior:

- Spring Mail remains an implementation dependency.
- WebP ImageIO support remains an implementation dependency.
- the tagged PostgreSQL test setup remains: normal `test` behavior, the explicit
  property-presence opt-out conventionally invoked as `-PskipPostgresTests=true`, and the mandatory
  `postgresTest` task. Existing Gradle behavior skips when the property is present, regardless of its text value;
  changing that parsing is outside this bounded rework.

`RuntimeLoggingSafetyTest.kt` must use the current storage deletion contract
`StorageService.deleteUploaded(UploadResult(...))` while retaining all MEE2-23 secret-safety coverage:

- JWT/access and refresh token safety;
- geocoder and ingestion provider failure safety;
- storage cleanup target and exception safety;
- SMTP recipient, OTP payload, headers, message IDs, and provider-exception safety;
- startup credentials and HMAC key-ring safety;
- unexpected MVC exception safety;
- scheduled OTP cleanup exception safety;
- default and dev logging-level coverage.

`ErrorContractMvcTest.kt` must retain the current `AvatarReplacementService` MVC test dependency and all
MEE2-23 controller imports/wiring for `ClientRequestContextResolver`, `DeviceIdParser`, and
`EmailOtpRequestValidator`. Its phone mocks must use the current `OtpRequestContext` signatures, and its final
test set must include both the current avatar/profile/pagination/community validation coverage and the additive
email OTP/error-contract matrix.

No conflict resolution may take an entire side wholesale for these files. Compilation plus focused tests are the
first proof that the merged constructor and method signatures match the combined production graph.

## Preserved behavior and user flows

The complete contract follows the MEE2-23 authority order above and is implemented by `origin/MEE2-23`.

### Phone authentication

- `POST /auth/send-otp` keeps its existing request, `200` success body, validation text, rate-limit response,
  disabled-SMS response, and absence of `Retry-After`.
- The exact send-success body remains `{"message":"OTP sent successfully"}`. Throttling remains
  `429 RATE_LIMITED` with `Too many OTP requests. Please try again later.`; disabled SMS remains
  `503 SMS_UNAVAILABLE` with `SMS delivery is not configured`.
- `POST /auth/verify-otp` keeps its request and `AuthResponse` shapes. Wrong, unknown, expired, exhausted,
  consumed, and replayed codes remain `401 UNAUTHORIZED` with `Invalid or expired OTP code`.
- Pending challenge insert failure, activation database failure, and activation crossing expiry remain the generic
  `500 INTERNAL_ERROR` envelope with `An unexpected error occurred` and no `Retry-After`. Email-specific 503
  exceptions must never cross into a phone endpoint.
- Phone JWT claims, refresh rotation, logout, profile access, deletion/restoration, and `authVersion`
  invalidation remain unchanged. Phone JWTs retain `sub`, `phone`, and `av`.
- The optional `X-Device-Id` remains additive; its absence preserves existing Android behavior.

### Email authentication

- `POST /auth/email/send-otp` remains additive. Existing, new, and soft-deleted account states take the same path
  and produce the same public result for the same operational outcome, without an account lookup. Successful
  delivery/activation returns `202` with
  `{"message":"If the address can receive email, a verification code will be sent."}`; quota, provider, and
  activation failures still return their defined 429/503 errors.
- Validation and normalization remain deterministic and centralized. Provider-specific alias rewriting is not
  introduced. Preserve the exact required/invalid/length/device/code/name/surname validation messages and the
  nullable-at-deserialization email verification DTO semantics.
- Request quotas are claimed and committed before delivery. The generated OTP is HMAC-SHA-256 hashed with a
  per-challenge salt and key ID; the raw OTP exists only in memory long enough to hash and deliver it.
- A challenge is inserted as unusable `PENDING`; provider delivery occurs outside a database transaction.
  Synchronous provider failure marks the row `DELIVERY_FAILED` when possible and preserves the prior active
  challenge.
- Provider acceptance is followed by locked activation. Only the latest request may activate, and a newer request,
  expiry, or activation failure cannot invalidate the prior active challenge.
- `POST /auth/email/verify-otp` keeps one public invalid/expired response for unknown, wrong, expired, exhausted,
  consumed, and replayed codes.
- Verification remains transactional: identifier lock, challenge lock, persisted attempt budgets, constant-time
  HMAC comparison, single-use consumption, identity lookup/creation, soft-delete restoration, and token
  persistence either commit together or roll back together.
- `auth_identities(type, normalized_identifier)` remains the only login mapping. An unverified `users.email`
  profile value is never used to select or link an account.
- A newly verified email-only user retains canonical `user.email`, null `user.phone`, and `isNewUser=true`.
  Email-only JWTs contain `sub` and `av` and omit both `email` and a null `phone` claim.

### Normative concurrency and rate-limit sequence

- All activation, verification, and identity creation for both channels use the single `OtpIdentifierLock`
  namespace `meet-otp-identifier-v1:<CHANNEL>:<canonicalIdentifier>`.
- Pending challenge creation for both channels acquires that same identifier lock before insert. The subject is
  derived from the immutable canonical identifier, and callers cannot provide an independent lock key.
- Request quota subjects are locked in deterministic sorted order. Request attempts remain persisted in
  `REQUIRES_NEW` before downstream delivery, so provider/activation failure does not refund quota.
- Activation accepts a challenge ID, reloads immutable channel/identifier data, then derives the advisory-lock
  subject from persisted data. Request ID, not SMTP completion order, decides which pending challenge may
  activate; an older slow send cannot supersede a newer request.
- Lifecycle checks resample PostgreSQL `clock_timestamp()` after relevant waits. The application does not use JVM
  time or transaction-start time for activation, verification, rate-window, or cleanup decisions.
- Verification lock order remains identifier advisory lock, active challenge row, then sorted attempt-subject
  advisory locks.
- Unknown/no-active verification charges only eligible IP/device verification budgets. A mismatch against an
  active challenge also charges the identifier-wide persisted budget; the budget survives resends and cannot be
  bypassed by requesting a new code.
- The user row is locked before soft-delete restoration and token issuance. Concurrent successful identity
  creation serializes under the same identifier lock, with database uniqueness as the final invariant.
- Preserve tests for slow older delivery, request/activation ordering, activation-versus-verification races,
  expiry while waiting, resend-resistant lockout, concurrent verification/replay, and concurrent identity
  creation, including concurrent pending inserts that retain deterministic request-ID ordering.

### Normative cryptographic and key-ring contract

- HMAC input framing remains the versioned `meet-otp-v1` contract implemented by `OtpHasher`.
- Every challenge uses a 16-byte random salt and stores only a 32-byte HMAC-SHA-256 result, the salt, and a safe
  key ID. The plaintext `code` column remains absent.
- HMAC keys remain canonical strict-Base64 decoded to at least 32 bytes and encapsulated by `OtpKeyRing`; decoded
  bytes are never exposed to callers. Verification resolves the row's key ID and uses `MessageDigest.isEqual`.
- Current and previous keys remain accepted for verification. Rotation remains two-phase across the fleet:
  first deploy the future key everywhere as previous while the old key is current, then promote the future key
  while retaining the old as previous, wait longer than the maximum OTP lifetime across the fleet, and only then
  remove the old key. Mixed fleets with different accepted key rings are prohibited. Emergency one-step rotation
  stops authentication traffic and revokes active challenges in an approved maintenance window; it must not
  reintroduce plaintext or log key material.

### Unrelated protected behavior

- Admin routes remain gated by the existing security policy and configured admin key.
- A blank admin key remains valid startup configuration but leaves `/admin/**` closed. Nonblank configured keys
  retain the existing filter/policy.
- Controllers and services continue mapping JPA entities to DTOs; entities are not exposed over HTTP.
  `toAuthProfileDto` retains auth-response defaults for interests/preferences, while `toFullProfileDto` retains
  actual full-profile values.
- TIMEPAD code remains under `ingestion/timepad`, keeps the existing provider mapping, and meeting ingestion
  remains idempotent by `(source, sourceExternalId)`.
- Atomic avatar replacement retains validation-before-mutation, restoration/preservation of the old avatar on
  failure, owner-scoped cleanup, safe path handling, and WebP support.

## Failure states

The rework does not add a new public failure state.

- Email malformed input: existing deterministic `400 BAD_REQUEST` messages.
- Email request quota exhausted: `429 OTP_RATE_LIMITED`; no retry estimate header.
- SMTP disabled, rejected, timed out, or unavailable: `503 OTP_DELIVERY_UNAVAILABLE`.
- Provider accepted but challenge activation failed or crossed expiry:
  `503 OTP_ACTIVATION_UNAVAILABLE`.
- Any invalid email verification state: `401 OTP_INVALID_OR_EXPIRED`.
- Phone failures retain their existing status, code, message, and header behavior.
- Expected invalid verification outcomes return from the transaction so failed-attempt writes commit before the
  public exception is created.
- Infrastructure details are translated at the API boundary. Logs and public error payloads must not contain OTPs,
  full or reconstructed email addresses, phone numbers, IPs, device IDs, submitted authentication identifiers,
  request bodies, JWTs, refresh tokens, API/admin keys, database URLs/usernames/passwords, SMTP
  usernames/passwords, provider tokens, SMTP payloads/headers/message IDs, OTP hashes/salts, HMAC key
  IDs/material, or exception/stack-trace details that contain them. Frozen successful response fields, including
  authenticated user profile data, remain allowed. Safe logging remains event/category metadata only.

## Cleanup access-path design

### Query semantics

Keep `OtpChallengeStore.cleanup(retentionHours, batchSize)` semantically unchanged:

- eligibility remains `expires_at <= clock_timestamp() - retention`, but the cutoff is sampled exactly once through
  an uncorrelated scalar subquery:

  ```sql
  WHERE expires_at <= (
      SELECT clock_timestamp() - (? * INTERVAL '1 hour')
  )
  ```

  PostgreSQL turns this into an init-plan parameter, allowing the cutoff to become an index condition while
  retaining the required wall-clock source;
- deterministic oldest-first ordering remains `(expires_at, id)`;
- `LIMIT batchSize` bounds each transaction's selection and delete work;
- `FOR UPDATE SKIP LOCKED` permits concurrent cleanup workers without waiting on already claimed rows;
- all challenge statuses remain eligible after retention. Adding a status predicate would change retention
  semantics and would require a separate product/operations decision.

Validate `retentionHours` and `batchSize` through the existing configuration constraints; this task does not add
another runtime limit or cleanup scheduler.

### Forward migration

Add exactly one new Flyway migration after V6:

`src/main/resources/db/migration/V7__index_otp_cleanup_selection.sql`

Its schema change is:

```sql
CREATE INDEX idx_otp_codes_expires_id
    ON otp_codes (expires_at, id);
```

Do not edit V1–V6 and do not replace the V6 status-leading index. The V6
`idx_otp_codes_status_expires_id` may serve future status-qualified operations but cannot lead the current
status-free selection. The new index matches both the range predicate's leading column and the required order.

The migration is intentionally transactional and uses ordinary `CREATE INDEX`, consistent with the repository's
Flyway setup. Ordinary PostgreSQL `CREATE INDEX` permits reads but blocks writes on the table while it builds.
The authoritative delivery-gate re-scope is recorded in task comment
`comment-84e5d3b5-4939-4543-8d2c-89d3ff67eff6`: NickolayMamonov is the named database/release owner, no
persistent production email-OTP dataset or live OTP write workload exists yet, and PR #19 merge plus workflow
completion may proceed without fabricated production metrics. Before V7 is applied to any persistent shared
database, the PR/deployment owner must record the production metrics (or explicit-zero values), PostgreSQL 16
timing/approved assumptions, exact write-block window, and explicit owner acceptance. If the window is
unacceptable or cannot be assessed, choose and validate an approved nontransactional concurrent-index V7 before
its first persistent application. Once V7 has been applied to any persistent environment, it is immutable and
cannot be edited or replaced.

The migration is backward-compatible with the V6-aware MEE2-23 application. Application rollback therefore
leaves V7 applied; dropping the index is unnecessary for functional rollback and would remove the performance
guard.

## PostgreSQL verification design

Extend migration coverage to prove version boundaries instead of treating V6 and V7 as one opaque latest state:

1. Migrate a disposable PostgreSQL database to V5 and insert representative legacy user/OTP data.
2. Migrate to V6 and retain all existing assertions for plaintext removal, phone identity backfill, no profile
   email linking, constraints, nullable phone, and the three V6 indexes.
3. Assert the V7 index is absent at the V6 target.
4. Migrate from V6 to latest and assert `idx_otp_codes_expires_id` is non-unique, unfiltered, ascending, and exactly
   `(expires_at, id)`.
5. Run Flyway validation at each migration boundary. Separately verify with Git that V1–V6 are byte-for-byte
   unchanged from `origin/MEE2-23`; a fresh migration alone cannot prove historical source immutability.

Add representative-volume plan coverage to `OtpCleanupPostgresTest` or a dedicated tagged PostgreSQL test:

- expose one `internal` cleanup SQL definition owned by `OtpChallengeStore`; runtime execution and the EXPLAIN
  test must consume that same definition and bind the same parameter types, with no hand-copied test query;
- insert exactly 60,000 deterministic rows using set-based `generate_series`: 5,000 clearly beyond retention and
  55,000 clearly live; use a 24-hour retention and 1,000-row batch, then run `ANALYZE otp_codes`;
- run `EXPLAIN (FORMAT JSON, COSTS OFF)` against that shared cleanup statement, including the CTE,
  scalar cutoff init plan, `ORDER BY`, `LIMIT`, and `FOR UPDATE SKIP LOCKED`;
- parse the JSON plan structurally and assert that the eligible-selection subtree uses
  `idx_otp_codes_expires_id`;
- assert the eligible index scan has an `Index Cond` on `expires_at` rather than a row-by-row cutoff filter;
- assert the eligible-selection subtree has no explicit `Sort` node, proving the index supplies
  `(expires_at, id)` order;
- avoid assertions on costs, row estimates, timing, or the exact outer delete join shape, which are
  PostgreSQL-version and statistics sensitive;
- retain the existing behavioral batch-size, live-row retention, and concurrent `SKIP LOCKED`/deadlock coverage.

The plan test is an access-path regression test, not a benchmark. It must run in `postgresTest` and must not
disable sequential scans or otherwise force the desired plan.

Add challenge-specific `SKIP LOCKED` behavior coverage:

1. Insert eligible challenges with known `(expires_at, id)` order plus a live row.
2. Hold a row lock on the oldest eligible challenge in transaction A.
3. Run `OtpChallengeStore.cleanup` in transaction B and prove it completes without waiting, skips the locked row,
   and deletes the next eligible rows up to the batch limit.
4. Prove the live row remains.
5. Release transaction A and prove a later cleanup can delete the previously skipped row.

## Documentation correction

Change README's logging section to state that `spring.mvc.log-resolved-exception=false` remains configured in
both production/default and `dev`. Dev still raises the application package to `DEBUG`, but resolved MVC
exceptions remain disabled to avoid leaking request values or implementation details. Keep
`LoggingProfileConfigurationTest` and `MvcResolvedExceptionLoggingTest` aligned with that statement.
After integrating MEE2-23, `application-dev.yml` already contains the required `false`; preserve it during the
merge rather than reintroducing stale-baseline `true`.

## Verification sequence

Implementation is complete only after the following evidence is recorded:

1. Confirm the merge graph contains the three MEE2-23 commits and current `dev` as parents/ancestors, with no
   force-push or rewrite.
2. Run focused tests for:
   - email normalization, validation, request, delivery, activation, verification, concurrency, replay, expiry,
     and persisted request/verification limits;
   - phone MVC contracts and auth lifecycle;
   - runtime configuration, profile logging, resolved-exception behavior, and source/runtime secret safety;
   - avatar replacement and storage lifecycle/path safety;
   - HMAC framing, key validation/current-previous lookup, storage hash/salt lengths, and constant-time matching;
   - admin blank/nonblank-key gating, both DTO projections, TIMEPAD mapping, and
     `(source, sourceExternalId)` upsert.
3. Run `./gradlew postgresTest`.
4. Run the full `./gradlew test`.
5. Run `./gradlew --no-daemon clean build`.
6. Run `git diff --check`.
7. Exercise packaged startup for default, prod, dev, and test profiles plus the existing fail-fast matrix for
   missing/unsafe JWT, SMTP, OTP HMAC, profile, proxy, and credential settings.
8. Inspect captured runtime logs, test stdout/stderr and reports, packaged runtime resources, and distribution
   artifacts for sensitive markers. Exclude source fixtures and compiled test classes that intentionally contain
   marker strings; unexpected matches fail verification.
9. Record an auditable implementation worklog or PR evidence table containing the final commit, merge ancestry,
   Java/Gradle/PostgreSQL versions, each command and exit status, focused/full test counts, proof PostgreSQL tests
   were not skipped, startup/fail-fast results, V1–V6 blob/checksum comparison, V7 catalog/plan evidence, and the
   sensitive-marker scan result. On plan assertion failure, emit formatted JSON and PostgreSQL server version.
10. Push a replacement branch and open a mergeable PR targeting current `dev`. State that it supersedes PR #18,
   but leave PR #18 open and unchanged.

The controlled-inbox SMTP canary requires operator credentials and inbox access. A-048 is a separate release
gate. Neither blocks implementation completion or the replacement PR.

## Compatibility and rollout

- HTTP changes remain additive; no Android phone endpoint, field, status, message, error code, or response shape
  changes.
- V7 only adds an index and may remain applied when rolling back to a V6-aware MEE2-23/replacement artifact that
  has the compatible HMAC key ring. It does not make the pre-V6 current-dev application compatible with the V6
  schema.
- V6 remains the coordinated auth schema cutover already designed by MEE2-23; its migration and runtime must ship
  together.
- Existing auth identities, sessions, rate-limit attempts, TIMEPAD records, and avatar data are not rewritten by
  this rework.
- Roll back only to a compatible V6-aware artifact if needed; retain V7. Pre-V6 binaries cannot run against the
  V6 schema. Do not down-migrate, restore plaintext OTP storage, or edit applied migrations.
- Emergency HMAC rotation stops OTP authentication traffic, intentionally revokes active challenges during an
  approved maintenance window, and restarts every instance with the same complete accepted key ring. A mixed
  fleet with incomplete/different current or previous key material is prohibited.

## Explicit non-goals

- Reimplementing or redesigning B-056.
- Changing the approved email endpoint, normalization, response, error, identity, or account-linking contract.
- Retiring or renaming phone endpoints, or coordinating Android changes.
- Linking legacy profile emails, adding auth-email change flows, or changing account merge policy.
- Changing OTP lifetimes, quotas, attempt limits, cleanup retention, or scheduler cadence.
- Replacing PostgreSQL locks/rate limits with Redis, a queue, or another service.
- Adding bounce/complaint webhooks, suppression storage, or a provider-specific email SDK.
- Guaranteeing mailbox/deliverability-enumeration opacity; this contract prevents application-account
  enumeration.
- Changing admin authorization, refresh/logout/deletion behavior, DTO projection semantics, TIMEPAD mapping,
  ingestion identity, avatar product behavior, or unrelated APIs.
- Closing or modifying PR #18.
