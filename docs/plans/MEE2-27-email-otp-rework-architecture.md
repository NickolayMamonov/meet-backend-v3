# MEE2-27 — Email OTP rework architecture

## Status and checklist

This architecture translates the approved MEE2-27 design into the smallest production change set. It preserves
the existing MEE2-23 modular-monolith architecture and current-dev avatar architecture; it does not introduce a
new subsystem.

This workflow node is documentation-only. Until architecture approval completes, do not modify `src/main/**`,
runtime configuration, migrations, build configuration, or any other production path. The current worktree may
contain only the MEE2-27 design and architecture artifacts.

- [x] Define source-history integration and merge boundaries.
- [x] Define preserved HTTP, application, persistence, transaction, and security contracts.
- [x] Define the cleanup SQL ownership and PostgreSQL access path.
- [x] Define V7 migration, rollout, and rollback constraints.
- [x] Define test architecture and auditable verification evidence.
- [x] Define affected areas and rejected alternatives.
- [ ] Implementation integrates the pinned branches in the required order.
- [ ] Implementation applies only the architecture-approved deltas.
- [ ] Implementation records verification and replacement-PR evidence.

## Architectural stance

Keep one Spring Boot/PostgreSQL modular monolith. `origin/MEE2-23` at `681c09b` already contains the approved
email OTP architecture: API adapters, identifier/value types, request context, JDBC-owned challenge persistence,
transactional lifecycle services, persisted rate limits, email delivery adapters, auth identities, runtime
validation, DTO mapping, and tests. `origin/dev` at `ebb6955` already contains the approved atomic avatar/storage
architecture.

MEE2-27 therefore has only three architectural responsibilities:

1. compose those two existing implementations without losing either branch's contracts;
2. make the challenge cleanup access path match its status-free `(expires_at, id)` selection;
3. correct documentation that contradicts the already-safe dev runtime configuration.

Do not refactor the OTP component graph, introduce a second persistence owner, or redesign public auth behavior
while resolving the merge.

## Authority and integration boundary

### Normative authority

Apply this precedence when implementation artifacts differ:

1. MEE2-27 approved design for product behavior and constraints;
2. this architecture for implementation boundaries that realize the approved design;
3. MEE2-23 production code and tests at `681c09b`;
4. MEE2-23 reviewed architecture and implementation plan for resolved internal contracts;
5. MEE2-23 design for unchanged product/API decisions;
6. current `dev` at `ebb6955` for avatar replacement, storage, and WebP behavior.

This prevents earlier MEE2-23 alternatives such as JPA-owned challenges, `created_at` request ordering, or
transaction-start time from reappearing.

If the approved design and architecture appear to conflict, implementation stops for review rather than choosing
one silently.

### Git composition

The implementation branch begins at common ancestor `d3b34d7`; the only expected local additions are these
workflow design/architecture artifacts, which must be preserved without altering product history.

1. Fetch and verify `origin/MEE2-23=681c09b` and `origin/dev=ebb6955`.
2. Fast-forward to `origin/MEE2-23`, preserving commits `3851feb`, `6ef2b05`, and `681c09b`.
3. Merge `origin/dev` with a normal merge commit. No rebase, squash, cherry-pick recreation, force-push, or
   history replacement is allowed.
4. Resolve the three known overlaps according to the contracts below.
5. Immediately before final verification and PR creation, fetch `origin/dev` again. If it advanced, inspect and
   integrate the new commits, repeat overlap analysis, and rerun affected verification. Material new scope
   returns to design/architecture review.

The replacement PR targets the then-current `dev`. It states that it supersedes PR #18 while leaving PR #18 open
and unchanged.

## Module and component boundaries

### API boundary

`AuthController` remains the sole `/auth` HTTP adapter.

- Existing phone methods keep the Android-visible endpoint, DTO, status, body, error, and header contracts.
- Email methods remain additive:
  - `POST /auth/email/send-otp`;
  - `POST /auth/email/verify-otp`.
- Controllers may validate DTOs, parse `X-Device-Id`, resolve trusted request context, and delegate to
  `AuthService`.
- Controllers do not generate OTPs, normalize identifiers independently, query account existence, call SMTP/SMS
  directly, or access challenge/identity repositories.

`AuthDto.kt` remains the HTTP serialization boundary. Email DTOs remain nullable at deserialization and are
validated by `EmailOtpRequestValidator`. JPA entities are never returned.

`ApiExceptionHandler` and `ApiErrorResponseWriter` remain the single public error boundary. Channel-specific
application errors are mapped there without exposing provider/database details.

### Application boundary

`AuthService` remains the channel-aware facade:

- it maps common OTP outcomes to the frozen phone errors or additive email errors;
- it delegates challenge mechanics to `OtpRequestCoordinator` and `OtpVerificationExecutor`;
- it retains refresh rotation and logout behavior;
- it does not own challenge SQL or provider transaction boundaries.

Do not merge phone and email public exceptions. The same internal outcome intentionally maps differently:

- phone delivery unavailable -> existing `SMS_UNAVAILABLE`;
- email delivery unavailable -> `OTP_DELIVERY_UNAVAILABLE`;
- phone activation/persistence failures -> existing generic 500;
- email activation failure -> `OTP_ACTIVATION_UNAVAILABLE`;
- phone invalid verification -> existing `UNAUTHORIZED`;
- email invalid verification -> `OTP_INVALID_OR_EXPIRED`.

`AuthTokenIssuer` remains the token boundary. It persists only refresh-token hashes and uses `UserProfileMapper`
for the auth response. `UserService` continues using the full-profile projection. The two projections remain
explicit because their defaults are observably different.

### Identifier and request-context boundary

`service/auth/identifier` remains the only source of canonical auth identifiers and request quota subjects.

- `AuthIdentifier` owns channel plus canonical value and has a redacted `toString()`.
- Email normalization remains exactly the MEE2-23 contract.
- `ClientRequestContextResolver` remains the trusted-proxy-aware IP boundary.
- `DeviceId` remains an optional supplemental quota subject, never a credential.
- Raw strings do not cross into challenge locks, hashing, identity lookup, or rate-limit APIs.

### OTP domain and transaction boundary

`service/auth/otp` remains a deep module with one persistence owner.

#### Request path

```text
AuthController
  -> EmailOtpRequestValidator / phone Bean Validation
  -> ClientRequestContextResolver
  -> AuthService
  -> OtpRequestCoordinator
       -> OtpRequestRateLimiter (REQUIRES_NEW)
       -> OtpCodeGenerator
       -> OtpHasher
       -> OtpChallengeLifecycle.createPending (short transaction)
       -> OtpDeliveryRouter (no database transaction)
       -> OtpChallengeLifecycle.activate or markDeliveryFailed (short transaction)
```

Required sequencing:

1. Persist request claims before generating/delivering a usable challenge.
2. Generate a six-digit code and create only versioned HMAC material.
3. Acquire the shared identifier advisory lock before inserting `PENDING`.
4. Release the database transaction before network delivery.
5. On synchronous provider failure, mark only the pending row `DELIVERY_FAILED` when possible.
6. On provider acceptance, reload immutable persisted channel/identifier data from challenge ID, derive the same
   advisory lock, and activate only if this remains the latest request.

Request ID is the ordering key. SMTP/SMS completion order never decides activation. The previous `ACTIVE`
challenge remains usable until a newer unexpired challenge successfully activates.

#### Verification path

```text
AuthService
  -> OtpVerificationExecutor (one transaction)
       -> OtpIdentifierLock
       -> OtpChallengeStore
       -> OtpVerificationLimiter / OtpAttemptStore
       -> OtpHasher
       -> AuthIdentityRepository
       -> UserRepository
       -> AuthTokenIssuer
```

Lock order remains:

1. channel+canonical-identifier advisory lock;
2. active challenge row lock;
3. sorted attempt-subject advisory locks;
4. user row lock when an identity already exists.

Invalid outcomes return from the transaction so applicable failed-attempt records commit before `AuthService`
throws the public 401. Successful challenge consumption, identity/user creation or restoration, refresh-token
insertion, and response creation share one transaction. A downstream database failure rolls them all back.

`auth_identities(type, normalized_identifier)` remains the sole login mapping. Verification never queries
`users.email` or `users.phone` as an alternate authentication source.

### Cryptography boundary

`OtpHasher` and `OtpKeyRing` remain the only HMAC owners:

- exact `meet-otp-v1` binary framing;
- 16-byte random salt;
- HMAC-SHA-256 with a 32-byte persisted result;
- safe persisted key ID;
- canonical strict-Base64 current/previous keys decoding to at least 32 bytes;
- constant-time `MessageDigest.isEqual`;
- no decoded key-byte access outside the key ring.

The raw OTP is permitted only in generator, hasher input, and delivery message stack frames. It is not persisted,
logged, placed in exceptions, or returned by `toString()`.

### Persistence ownership

- `OtpChallengeStore` remains the only runtime/application owner of `otp_codes` reads and writes. Flyway and
  PostgreSQL integration tests are intentional schema/verification exceptions.
- `OtpAttemptStore` remains the only owner of `otp_rate_limit_attempts` SQL.
- `AuthIdentityRepository` owns JPA access to `auth_identities`.
- `UserRepository` owns users and row locking.
- `RefreshTokenRepository` owns hashed refresh-token persistence.

Do not add a JPA `OtpCode`, another cleanup repository, native-query repository duplication, or a test-only
production query implementation.

### Delivery and configuration boundary

`OtpDeliveryRouter` selects the existing `SmsSender` or `EmailOtpSender`.

- SMTP calls remain outside database transactions.
- Provider exceptions are translated into safe internal delivery failure.
- Runtime startup validation remains fail-fast outside exactly `dev` or exactly `test`.
- Dev retains fake email delivery and package-level DEBUG.
- `spring.mvc.log-resolved-exception` remains `false` in default/prod/dev/test expectations; the README must
  describe that accurately.

### Unrelated preserved boundaries

- `AvatarReplacementService` remains the atomic avatar orchestration owner.
- `StorageService` remains the storage/path safety owner and uses `UploadResult` for deletion.
- Admin endpoints retain `AdminKeyAuthFilter`/security gating; blank configuration keeps the endpoints closed.
- TIMEPAD implementation remains under `ingestion/timepad`.
- `MeetingUpsertService` retains `(source, sourceExternalId)` as ingestion identity.
- No auth merge may alter these packages' public behavior.

## Cleanup architecture

### One SQL source of truth

`OtpChallengeStore` owns exactly one immutable test-visible symbol:

```kotlin
internal val CLEANUP_SQL: String
```

It is exposed as `OtpChallengeStore.CLEANUP_SQL`. `OtpChallengeStore.cleanup` executes that exact value.
The PostgreSQL plan test prefixes that exact value with `EXPLAIN (FORMAT JSON, COSTS OFF)`. No copied,
reformatted, or test-specific equivalent query is allowed.

The statement shape is:

```sql
WITH eligible AS (
    SELECT id
    FROM otp_codes
    WHERE expires_at <= (
        SELECT clock_timestamp() - (? * INTERVAL '1 hour')
    )
    ORDER BY expires_at, id
    LIMIT ?
    FOR UPDATE SKIP LOCKED
)
DELETE FROM otp_codes
WHERE id IN (SELECT id FROM eligible)
```

Both runtime and EXPLAIN paths bind parameter 1 as Kotlin `Long`/PostgreSQL `BIGINT` retention hours and
parameter 2 as Kotlin `Int`/PostgreSQL `INTEGER` batch size. Runtime uses `JdbcTemplate.update`.

The scalar subquery is architectural, not cosmetic. It samples wall time once into a PostgreSQL init-plan
parameter. That gives one statement-consistent cutoff after lock waits and allows `expires_at` to appear in the
index condition. Calling `clock_timestamp()` directly for each scanned row would leave it as a filter and weaken
the bounded access path.

Cleanup remains:

- status-free;
- oldest-first by `(expires_at, id)`;
- limited to one configured batch;
- concurrent-worker safe through `FOR UPDATE SKIP LOCKED`;
- one short transaction per scheduled invocation;
- silent about identifiers, hashes, and exception details.

Do not add a status predicate to reuse the V6 index. That would change retention semantics for stale `PENDING`,
expired `ACTIVE`, and terminal rows.

### PostgreSQL index

Add one monotonic migration:

`src/main/resources/db/migration/V7__index_otp_cleanup_selection.sql`

```sql
CREATE INDEX idx_otp_codes_expires_id
    ON otp_codes (expires_at, id);
```

Retain `idx_otp_codes_status_expires_id`. It is not a substitute because cleanup has no leading status equality.
V1–V6 remain byte-for-byte unchanged.

The selected default is ordinary transactional `CREATE INDEX`, matching current Flyway conventions. It permits
reads but blocks writes to `otp_codes` during the build. The authoritative delivery-gate re-scope is recorded
in task comment `comment-84e5d3b5-4939-4543-8d2c-89d3ff67eff6`: NickolayMamonov is the named database/release
owner, no persistent production email-OTP dataset or live OTP write workload exists yet, and PR #19 merge plus
workflow completion may proceed without fabricated production metrics. Before V7 is applied to a persistent
shared database, the deployment evidence must record:

- production `otp_codes` row count plus table and existing-index sizes;
- normal and peak `otp_codes` write rates;
- representative PostgreSQL 16 index-build duration from a production-sized staging clone, or a documented
  estimate and its assumptions when a clone is unavailable;
- the offered maintenance/write-block window;
- the named database/release owner and their explicit approval;
- the worklog or PR evidence location containing the decision.

Without that hard pre-deployment approval, persistent V7 application stops and the task returns for separately
reviewed nontransactional Flyway migration design. Once applied anywhere persistent, V7 is immutable.

## Failure handling

### Public failures

No new public error is introduced.

- Phone success and failures remain byte-stable, including generic 500 for pending insert, activation database
  failure, and activation crossing expiry.
- Email send retains deterministic 400, account-safe 202, 429 rate-limit, 503 delivery, and 503 activation
  mappings.
- Email verify retains one 401 invalid-or-expired mapping.
- No auth error includes truthful-looking retry timing when the system cannot calculate it.

### Internal failures

- Quota exhaustion aborts before challenge creation; committed quota history remains authoritative.
- Pending insert failure produces channel-specific existing mapping and no delivery call.
- Provider failure leaves the previous active challenge intact; compensation failure can leave only unusable
  `PENDING`.
- Activation database failure or expiry leaves no new usable challenge and preserves the previous active row.
- Verification mismatch/unknown/expiry commits only the approved counters and never issues tokens.
- Identity/token persistence failure rolls back successful challenge consumption.
- Cleanup skips locked eligible rows and retries them on a later scheduled run.
- Cleanup exceptions are logged only as safe event categories; scheduler retries on its next fixed delay.

### Sensitive-data boundary

Allowed operational logging remains route/event name, provider kind, latency, safe outcome category, and numeric
counters. Logs and public errors exclude OTPs, auth identifiers, addresses, phone numbers, IPs, device IDs,
request bodies, JWTs, refresh tokens, API/admin keys, database and SMTP credentials, provider tokens/payloads,
SMTP headers/message IDs, OTP hashes/salts, HMAC key IDs/material, and unsafe throwable details.

Successful authenticated response fields remain part of the frozen API and are not prohibited by this logging
rule.

## Test architecture

### Merge contract tests

`build.gradle.kts` must compile with all of:

- Spring Mail;
- WebP ImageIO;
- existing tagged PostgreSQL tests;
- presence-based `skipPostgresTests` opt-out;
- mandatory `postgresTest`.

`RuntimeLoggingSafetyTest` combines `UploadResult` storage deletion with MEE2-23 SMTP, key-ring, MVC, cleanup,
JWT, provider, and credential marker coverage.

`ErrorContractMvcTest` combines `AvatarReplacementService` wiring and current avatar/profile validation coverage
with MEE2-23 email/phone DTO, context, response, and error assertions.

### Migration tests

Extend `EmailOtpMigrationPostgresTest` using one fresh schema through explicit boundaries:

1. migrate to V5 and insert legacy fixtures;
2. migrate that same schema specifically to V6;
3. assert the complete existing auth schema and absence of V7;
4. run Flyway validation;
5. migrate that same schema to latest/V7;
6. assert `idx_otp_codes_expires_id` is valid, ready, non-unique, unfiltered, ascending, and
   exactly `(expires_at, id)`;
7. run Flyway validation again.

Git evidence separately proves V1–V6 blobs are unchanged from `origin/MEE2-23`; a fresh Flyway database cannot
prove source-file immutability.

### Cleanup plan test

Use the exact production cleanup SQL prefixed with `EXPLAIN (FORMAT JSON, COSTS OFF)`.

Fixture:

- PostgreSQL integration database;
- exactly 60,000 challenge rows inserted set-wise;
- 5,000 clearly older than a 24-hour retention cutoff;
- 55,000 clearly live;
- batch size 1,000;
- `ANALYZE otp_codes`;
- no disabled sequential scans or planner forcing.

Parse the JSON plan structurally:

1. find the plan subtree whose `Subplan Name` is `CTE eligible`;
2. confirm that it is the `otp_codes` eligible-selection path through `Limit` and `LockRows`;
3. assert that subtree contains an index scan named `idx_otp_codes_expires_id`;
4. assert its `Index Cond` references `expires_at`;
5. assert the eligible subtree contains no `Sort`;
6. do not assert costs, row estimates, timing, exact nesting, or the outer delete join shape.

On failure, include formatted plan JSON and PostgreSQL version in the assertion diagnostic.

### Cleanup concurrency test

Add a challenge-specific deterministic test:

1. insert ordered eligible rows and one live row;
2. transaction A locks the oldest eligible row and waits on a latch;
3. transaction B invokes `OtpChallengeStore.cleanup` with a smaller batch;
4. assert B completes within the test timeout, deletes the next rows in order, and retains the locked and live
   rows;
5. release A and assert a later cleanup deletes the previously skipped row.

This verifies behavior independently of the planner assertion.

### Preserved regression suites

Retain focused coverage for:

- phone and email MVC contracts;
- normalization and trusted request context;
- HMAC/key-ring/current-previous verification;
- request ordering, slow provider completion, activation races, expiry after waits, replay, and concurrent identity
  creation;
- persisted request and verification quotas, including resend-resistant identifier budget;
- refresh rotation, logout, deletion/restoration, and auth-version invalidation;
- runtime configuration/startup fail-fast matrix;
- resolved MVC exception and source/runtime logging safety;
- avatar replacement and storage lifecycle/path safety;
- admin blank/nonblank-key behavior and DTO projections;
- TIMEPAD mapping and idempotent upsert.

## Migration, rollout, and rollback

### Implementation and PR verification

1. Integrate and verify both source histories.
2. Add V7, cleanup SQL adjustment, plan/concurrency tests, and README correction.
3. Verify V1–V6 Git blobs and Flyway migration boundaries.
4. Before any persistent V7 application, record index-build acceptance or redesign V7 before first use.
5. Run focused tests, `postgresTest`, full `test`, and final no-daemon clean build.
6. Run packaged startup for default/prod/dev/test plus unsafe/missing-setting fail-fast cases.
7. Scan runtime logs, test output/reports, packaged runtime resources, and distribution artifacts for sensitive
   markers, excluding intentional source/test fixture bytes.
8. Re-fetch and integrate current `dev`, then rerun affected and final verification.
9. Run `git diff --check`.
10. Record an evidence table containing the final commit and merge ancestry, Java/Gradle/PostgreSQL versions,
    every command and exit status, focused/full test counts, proof `postgresTest` executed without skips,
    startup/fail-fast results, V1–V6 blob/checksum evidence, V7 catalog and EXPLAIN evidence, index-build gate
    decision, and sensitive-marker scan result.
11. Commit the approved artifacts and implementation, then require empty `git status --short` output.
12. Push the replacement branch and open the replacement PR.

### Initial production cutover from pre-V6 dev

The first deployment from the current pre-V6 `dev` is a coordinated auth schema cutover:

1. Verify the production email/DNS/provider, SMTP credential, trusted-proxy, backup, and identical HMAC key-ring
   prerequisites from the MEE2-23 operations runbook.
2. Back up PostgreSQL and stop all pre-V6 application instances plus profile/auth writers.
3. Apply V6 and V7 under the accepted index-build plan.
4. Start every instance with the same complete accepted current/previous HMAC key ring.
5. Run phone compatibility plus controlled email send, verify, refresh, and logout canaries.
6. Reopen traffic only after schema validation, canaries, and safe-log checks pass.

Rollback depends on when failure occurs:

- Before public traffic or post-cutover writes, restore the pre-cutover database backup and pre-V6 artifact.
- After post-cutover writes, do not run a pre-V6 artifact or down-migrate in place. Forward-fix by default.
  Restoring the backup is allowed only when an authorized recovery owner explicitly accepts losing all
  post-cutover writes.
- On later deployments with a known compatible V6-aware artifact, application rollback may retain V7 when the
  schema and accepted HMAC key ring are compatible.

Pre-V6 binaries cannot run against V6/V7. Do not restore plaintext OTP columns or edit applied migrations.

Normal HMAC rotation remains two-phase across the whole fleet. Emergency rotation stops OTP authentication,
revokes active challenges during an approved maintenance window, and restarts every instance with the same
complete accepted key ring.

The controlled-inbox SMTP canary and A-048 remain external, nonblocking release gates.

## Affected areas

### Final replacement-PR/runtime impact relative to `dev@ebb6955`

The replacement PR introduces the complete preserved MEE2-23 surface to current `dev`:

- API and errors: `AuthController`, `AuthDto`, and `ApiError` additive email contracts plus phone compatibility.
- Auth application: `AuthService`, `AuthTokenIssuer`, `OtpRequestContext`, `UserProfileMapper`, `UserService`, and
  `JwtService`.
- Identifier/request context: `service/auth/identifier`.
- OTP: `service/auth/otp` cryptography, JDBC persistence, rate limits, request/verification transactions, and
  cleanup jobs.
- Identity/persistence: nullable user phone, `AuthIdentity`, auth/user repositories, and V6's destructive legacy
  OTP conversion plus phone-identity backfill.
- Email/configuration: `service/email`, email/OTP/client-IP properties, SMTP settings, runtime validation and
  initialization, `application.yml`, `application-dev.yml`, test configuration, and `.env.example`.
- Operations: email OTP runbook and existing MEE2-23 design/architecture/implementation documentation.
- Current-dev avatar/storage: `MediaController`, `AvatarReplacementService`, `StorageService`, WebP dependency,
  and their regression tests.

These are material review and deployment surfaces even where the MEE2-23 files are integrated byte-for-byte.

### MEE2-27-authored production/runtime delta after composition

- `build.gradle.kts` — additive dependency and PostgreSQL task merge.
- `src/main/kotlin/dev/whysoezzy/meet/service/auth/otp/OtpPersistence.kt` — shared cleanup SQL and scalar cutoff.
- `src/main/resources/db/migration/V7__index_otp_cleanup_selection.sql` — new index only.
- `README.md` — resolved-exception logging correction.

All other MEE2-23 production files are integrated unchanged except where a current-dev merge requires compilation
adaptation. Current-dev production files remain authoritative for:

- `api/controller/MediaController.kt`;
- `service/AvatarReplacementService.kt`;
- `service/StorageService.kt`.

### Tests

- `RuntimeLoggingSafetyTest.kt`;
- `api/error/ErrorContractMvcTest.kt`;
- `integration/EmailOtpMigrationPostgresTest.kt`;
- `integration/OtpCleanupPostgresTest.kt`;
- focused existing auth/config/logging/avatar/storage/TIMEPAD suites as verification targets.

### Documentation/evidence

- this architecture and the approved MEE2-27 design;
- existing MEE2-23 operations documentation;
- implementation worklog or replacement PR evidence table;
- replacement PR description.

No new endpoint, DTO, service package, table, scheduler, external service, or deployable is added.

## Technical constraints

- Java 21, Gradle wrapper 8.5, Spring Boot 3.2.2, Kotlin 1.9.25, PostgreSQL 16/Testcontainers.
- PostgreSQL remains the source of truth for challenge state, request ordering, locks, clocks, identities, and
  rate limits.
- `postgresTest` must execute tagged database tests rather than pass through skips.
- Production SQL and EXPLAIN tests share one definition.
- Planner tests do not force an index.
- V1–V7 are immutable after persistent application.
- No force-push, applied-migration edit, secret-bearing command/comment/commit, or PR #18 mutation.
- Admin, DTO, TIMEPAD, ingestion identity, auth lifecycle, and Android compatibility remain frozen.

## Rejected alternatives

- Reimplementing B-056 on top of current `dev`: loses reviewed history and risks behavioral drift.
- Rebasing/squashing/cherry-picking the OTP branch: obscures provenance and violates the required integration
  order.
- Taking either side wholesale in overlapping tests/build configuration: drops required coverage or dependencies.
- Adding `status` to cleanup to reuse V6: changes retention semantics.
- Dropping/replacing the V6 status-leading index: edits or invalidates an applied migration assumption.
- Editing V6: violates Flyway monotonicity and checksum compatibility.
- Calling `clock_timestamp()` directly per scanned row: prevents a single cutoff and weakens index qualification.
- Copying cleanup SQL into the plan test: creates two sources of truth.
- Disabling sequential scans in the plan test: proves a forced plan, not production planner behavior.
- Using wall-clock timing as the performance assertion: flaky and environment-dependent.
- Adding Redis, a queue, an outbox, another cleanup service, or a provider-specific SDK: unnecessary for the
  bounded rework.
- Using `CREATE INDEX CONCURRENTLY` without pre-application operational approval and Flyway transaction design:
  introduces a different migration mode without evidence it is needed.
- Rolling back to pre-V6 binaries or recreating plaintext OTP storage: schema-incompatible and security-regressive.
