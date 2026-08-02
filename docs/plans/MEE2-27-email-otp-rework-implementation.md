# MEE2-27 — Email OTP rework implementation plan

## Planning status

This is the executable implementation plan for composing the already-reviewed MEE2-23 email OTP work with
current `dev`, then applying the bounded MEE2-27 cleanup-index and documentation corrections. It does not
redesign B-056.

- **Starting worktree:** `MEE2-27` at
  `d3b34d7f77f3e3f60858a594ff434e36394a0564`, with only the approved MEE2-27 design and architecture documents
  untracked.
- **Pinned inputs at planning time:**
  - `origin/MEE2-23` =
    `681c09b76e2ea33c58557daeb76cd48774e88638`;
  - `origin/dev` =
    `ebb69550950cf96670f6aa084a3aa2cb3e96af90`.
- **Normative inputs:** the approved MEE2-27 design and architecture, followed by MEE2-23 production/tests and
  reviewed architecture/implementation plan according to the authority order recorded there.
- **Planning-node production changes:** none.

### Planning checklist

- [x] Preserve the approved source-history composition and authority order.
- [x] Map the bounded authored delta to exact files and symbols.
- [x] Define ordered implementation slices and per-slice acceptance.
- [x] Define exact automated, PostgreSQL, runtime, security, Git, and PR verification.
- [x] Define the V7 operational gate, cutover, rollback, and explicit non-goals.
- [x] Ensure every packaged profile uses direct per-case datasource properties and prove exact `dev` isolation.
- [ ] Implementation integrates the pinned MEE2-23 commits first.
- [ ] Implementation merges current `dev` second and resolves all overlaps additively.
- [ ] Implementation applies the approved cleanup SQL, V7, test, and README changes.
- [ ] Implementation records all required evidence, commits a clean branch, and opens the replacement PR.

## Authority and stop conditions

Apply this precedence when resolving implementation questions:

1. approved MEE2-27 design for product behavior and constraints;
2. approved MEE2-27 architecture for implementation boundaries;
3. MEE2-23 production code and tests at `681c09b`;
4. reviewed MEE2-23 architecture and implementation plan;
5. earlier MEE2-23 design for unchanged product/API decisions;
6. then-current `dev` for avatar replacement, storage, and WebP behavior.

Stop and return for review instead of choosing silently when:

- the approved MEE2-27 design and architecture appear to conflict;
- a newly fetched `dev` tip adds material scope or changes an approved boundary;
- the authoritative V7 delivery-gate re-scope is contradicted by a later approved task record;
- a persistent environment has already applied a different V7;
- preserving both sides of an overlap would require a product/API behavior change;
- required verification reveals a security, migration, concurrency, Android compatibility, or data-loss defect.

Do not use a persistent shared database for migration or plan tests. Testcontainers or an explicitly disposable
schema/database is required.

## Scope and affected areas

### Final replacement-PR impact relative to `dev`

The replacement PR necessarily contains the complete preserved MEE2-23 surface:

- `AuthController`, `AuthDto`, and `ApiError` additive email endpoints/errors with frozen phone behavior;
- `AuthService`, `AuthTokenIssuer`, `OtpRequestContext`, `UserProfileMapper`, `UserService`, and `JwtService`;
- `service/auth/identifier` canonical identifiers, device parsing, trusted-proxy request context, and validation;
- `service/auth/otp` cryptography, JDBC persistence, quotas, lifecycle, verification, and cleanup;
- `AuthIdentity`, nullable phone/user/repository changes, hashed refresh-token behavior, and V6;
- email delivery adapters, runtime validation, configuration properties/resources, and operations documentation;
- current-dev `MediaController`, `AvatarReplacementService`, `StorageService`, WebP support, and tests.

These integrated files remain review and deployment surfaces even where their blobs are unchanged from a source
branch.

### MEE2-27-authored delta after composition

Production/runtime edits are limited to:

- `build.gradle.kts` — additive merge of Spring Mail, WebP ImageIO, normal `test`, property-presence PostgreSQL
  opt-out, and mandatory `postgresTest`;
- `src/main/kotlin/dev/whysoezzy/meet/service/auth/otp/OtpPersistence.kt` —
  `OtpChallengeStore.CLEANUP_SQL` and the once-sampled cleanup cutoff;
- `src/main/resources/db/migration/V7__index_otp_cleanup_selection.sql` — one new index;
- `README.md` — state that resolved MVC exception logging remains disabled in `dev`.

Merge-related and new test edits are limited to:

- `src/test/kotlin/dev/whysoezzy/meet/RuntimeLoggingSafetyTest.kt`;
- `src/test/kotlin/dev/whysoezzy/meet/api/error/ErrorContractMvcTest.kt`;
- `src/test/kotlin/dev/whysoezzy/meet/integration/EmailOtpMigrationPostgresTest.kt`;
- `src/test/kotlin/dev/whysoezzy/meet/integration/OtpCleanupPostgresTest.kt`.

Documentation/evidence edits may include:

- the approved MEE2-27 design, architecture, and this implementation plan;
- an MEE2-27 implementation worklog or equivalent repository evidence document;
- the replacement PR description.

Do not modify other production files unless a current-dev integration requires a narrow compilation adaptation.
Any such edit must be called out explicitly in the worklog and reviewed against the authority order.

## Ordered implementation plan

Each slice leaves the branch coherent and runs its listed checks before proceeding. Preserve the untracked
MEE2-27 planning artifacts throughout source integration.

### Slice 1 — Reconfirm the worktree and source revisions

1. Record `git status --short --branch`, current `HEAD`, Java, Gradle, Docker, and PostgreSQL versions.
2. Fetch `dev` and `MEE2-23` without changing history:

   ```sh
   git fetch origin dev MEE2-23
   git rev-parse origin/MEE2-23 origin/dev HEAD
   git merge-base origin/MEE2-23 origin/dev
   ```

3. Require the fetched MEE2-23 ref to equal the immutable approved revision, not merely contain it:

   ```sh
   test "$(git rev-parse origin/MEE2-23)" = \
     "681c09b76e2ea33c58557daeb76cd48774e88638" || {
       echo "origin/MEE2-23 is not the approved immutable revision; stopping" >&2
       exit 1
     }
   ```

   Record the equality result. If the ref differs, stop for an explicitly approved source revision; do not import
   additional branch-tip commits. Confirm commits `3851feb`, `6ef2b05`, and `681c09b` occur in order.
4. Compare the fetched `origin/dev` with planning-time `ebb6955`. If it advanced, inspect:

   ```sh
   git log --oneline --decorate ebb6955..origin/dev
   git diff --stat ebb6955..origin/dev
   git diff --name-status ebb6955..origin/dev
   ```

   Repeat overlap analysis for changed files. Material new scope triggers the stop condition above.
5. Confirm only the three MEE2-27 planning documents are locally added and no production/build/runtime/test file
   is modified before integration.

Acceptance:

- source commit IDs, exact MEE2-23 equality, and merge base are recorded;
- the planning artifacts are preserved;
- there are no unexplained local changes;
- any newer `dev` commits have an explicit impact decision before merging.

### Slice 2 — Preserve MEE2-23 history, then merge current dev

1. Fast-forward the task branch to MEE2-23:

   ```sh
   git merge --ff-only 681c09b76e2ea33c58557daeb76cd48774e88638
   ```

   This must preserve the original commits rather than recreate or squash them.
2. Merge the fetched `origin/dev` with a normal merge commit:

   ```sh
   git merge --no-ff origin/dev
   ```

3. Resolve the known overlaps by composing both contracts:

   - `build.gradle.kts`
     - retain `spring-boot-starter-mail`;
     - retain `org.sejda.imageio:webp-imageio:0.1.6`;
     - retain the general JUnit Platform setup;
     - retain ordinary `test` behavior and the presence-based
       `project.hasProperty("skipPostgresTests")` exclusion;
     - retain mandatory tagged `postgresTest`.
   - `RuntimeLoggingSafetyTest.kt`
     - use current-dev `StorageService.deleteUploaded(UploadResult(...))`;
     - retain JWT/refresh, geocoder/ingestion, storage target/cleanup, SMTP recipient/code/payload/header/message-ID
       and provider-failure, startup credential/HMAC, MVC exception, scheduled cleanup, and default/dev
       secret-safety coverage.
   - `ErrorContractMvcTest.kt`
     - retain current-dev `AvatarReplacementService` wiring and avatar/profile/pagination/community coverage;
     - retain MEE2-23 `ClientRequestContextResolver`, `DeviceIdParser`, `EmailOtpRequestValidator`, current phone
       request-context signatures, and the complete email OTP/error matrix.

4. Do not resolve any of those files by taking one side wholesale.
5. Before completing the merge, inspect the unresolved/index result:

   ```sh
   git diff --cc
   git diff --cached --check
   git status --short
   ```

6. Stage only the reviewed resolutions and complete the merge commit:

   ```sh
   git add build.gradle.kts \
     src/test/kotlin/dev/whysoezzy/meet/RuntimeLoggingSafetyTest.kt \
     src/test/kotlin/dev/whysoezzy/meet/api/error/ErrorContractMvcTest.kt
   git diff --cached --check
   git commit
   ```

   If Git reports other conflicted files because `dev` advanced, review and stage each explicitly under the
   authority order; do not use blanket `git add .`.
   If Git unexpectedly auto-completed a conflict-free merge, do not create an extra empty commit; verify that
   `HEAD` is already the two-parent merge commit and proceed to inspection.
7. Inspect the completed merge from both parents:

   ```sh
   git show --cc --stat --oneline HEAD
   git diff --stat HEAD^1..HEAD
   git diff --stat HEAD^2..HEAD
   git log --graph --oneline --decorate -12
   ```

8. Run a compile gate before adding MEE2-27 behavior:

   ```sh
   ./gradlew compileTestKotlin -PskipPostgresTests=true
   ```

Acceptance:

- the graph retains MEE2-23's three original commits and a normal current-dev merge;
- Spring Mail, WebP, and mandatory PostgreSQL test behavior coexist;
- both overlap test files contain the union of required coverage;
- the merged source and tests compile;
- no rebase, squash, cherry-pick recreation, force-push, or PR #18 mutation occurred.

### Slice 3 — Make cleanup SQL one owned, bounded source of truth

Edit only `OtpPersistence.kt` for the cleanup behavior.

1. In `OtpChallengeStore`, expose exactly:

   ```kotlin
   internal val CLEANUP_SQL: String
   ```

   available to tests as `OtpChallengeStore.CLEANUP_SQL`.
2. Define the SQL once, with this semantic and structural shape:

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

3. Make `OtpChallengeStore.cleanup` execute that exact constant via `JdbcTemplate.update`; do not duplicate,
   interpolate, or reformat a second runtime query.
4. Bind parameter 1 as Kotlin `Long`/PostgreSQL `BIGINT` retention hours and parameter 2 as Kotlin
   `Int`/PostgreSQL `INTEGER` batch size.
5. Keep cleanup status-free, oldest-first, bounded, one-transaction, and `SKIP LOCKED`.
6. Do not change existing configuration validation, scheduling, retention defaults, status transitions, or
   cleanup logging.

Acceptance:

- there is one application-owned cleanup SQL symbol;
- runtime and later EXPLAIN coverage consume the same value;
- `clock_timestamp()` is sampled once through the uncorrelated scalar subquery;
- no status predicate or second `otp_codes` persistence owner is introduced;
- existing cleanup behavior tests still pass.

### Slice 4 — Add monotonic V7 and migration boundary coverage

1. Add exactly:

   `src/main/resources/db/migration/V7__index_otp_cleanup_selection.sql`

   with:

   ```sql
   CREATE INDEX idx_otp_codes_expires_id ON otp_codes (expires_at, id);
   ```

2. Do not modify, rename, replace, or delete V1–V6. Retain V6's
   `idx_otp_codes_status_expires_id`.
3. Extend `EmailOtpMigrationPostgresTest` to use one fresh schema:
   - migrate to V5;
   - insert the existing legacy fixtures;
   - migrate that same schema specifically to V6;
   - retain all current V6 assertions for plaintext removal, challenge schema, phone identity backfill, no legacy
     profile-email linking, constraints, nullable phone, and V6 indexes;
   - assert V7 is absent;
   - run Flyway validation;
   - migrate the same schema to latest/V7;
   - assert `idx_otp_codes_expires_id` is valid, ready, non-unique, unfiltered, ascending, and exactly
     `(expires_at, id)`;
   - run Flyway validation again.
4. Keep Git blob evidence separate from migration behavior. Record:

   ```sh
   for f in src/main/resources/db/migration/V{1,2,3,4,5,6}__*.sql; do
     test "$(git hash-object "$f")" = "$(git rev-parse "origin/MEE2-23:$f")" || exit 1
   done
   ```

Acceptance:

- V7 is the only new migration;
- all V1–V6 blobs match `origin/MEE2-23`;
- one schema proves both V5→V6 and V6→V7 boundaries;
- V7 catalog assertions prove the exact usable index shape;
- Flyway validation passes at both boundaries.

### Slice 5 — Add representative-volume plan and challenge concurrency proofs

Extend `OtpCleanupPostgresTest`; do not add another production query or cleanup owner.

#### Exact-SQL EXPLAIN test

1. Insert exactly 60,000 deterministic rows with set-based SQL:
   - 5,000 clearly older than 24 hours;
   - 55,000 clearly live.
2. Run `ANALYZE otp_codes`.
3. Execute:

   ```text
   EXPLAIN (FORMAT JSON, COSTS OFF) + OtpChallengeStore.CLEANUP_SQL
   ```

   Bind retention as `24L` and batch size as `1_000`.
4. Parse the returned JSON structurally.
5. Find the subtree with `Subplan Name = "CTE eligible"` and prove:
   - the eligible `otp_codes` path is under `Limit` and `LockRows`;
   - it uses `idx_otp_codes_expires_id`;
   - `Index Cond` references `expires_at`;
   - no `Sort` exists in the eligible subtree.
6. Do not assert planner costs, row estimates, timings, exact outer delete join, or brittle exact nesting.
7. Do not set `enable_seqscan`, force an index, or tune planner settings.
8. On assertion failure, include pretty JSON and the PostgreSQL server version.

#### Challenge-specific SKIP LOCKED test

1. Insert ordered eligible challenge rows plus one live row.
2. Transaction A locks the oldest eligible challenge row and waits on a synchronization primitive.
3. Transaction B invokes `OtpChallengeStore.cleanup` with a batch smaller than the eligible set.
4. Require B to complete within a bounded test timeout, skip A's lock, delete the next oldest rows up to the
   batch, and retain both the locked row and live row.
5. Release A, then prove a later cleanup deletes the previously skipped row.

Acceptance:

- the plan test uses the exact production SQL and deterministic 60,000-row fixture;
- the eligible path uses V7 without a Sort and without planner forcing;
- the independent concurrency test proves nonblocking challenge cleanup and later retry;
- failures provide enough PostgreSQL/version/JSON evidence to diagnose planner drift.

### Slice 6 — Correct documentation and complete overlap regressions

1. Correct README wording to match runtime configuration:
   - `spring.mvc.log-resolved-exception=false` remains disabled in `dev`;
   - package logging under `dev.whysoezzy` remains DEBUG in `dev`.
2. Do not change `application-dev.yml` or enable resolved-exception logging.
3. Complete any compile-level adaptations in the two overlap tests while preserving the full union described in
   Slice 2.
4. Run focused non-PostgreSQL coverage:

   ```sh
   ./gradlew test -PskipPostgresTests=true \
     --tests 'dev.whysoezzy.meet.api.error.ErrorContractMvcTest' \
     --tests 'dev.whysoezzy.meet.api.error.MvcResolvedExceptionLoggingTest' \
     --tests 'dev.whysoezzy.meet.LoggingSafetySourceTest' \
     --tests 'dev.whysoezzy.meet.RuntimeLoggingSafetyTest' \
     --tests 'dev.whysoezzy.meet.config.*' \
     --tests 'dev.whysoezzy.meet.security.*' \
     --tests 'dev.whysoezzy.meet.service.AuthServiceTest' \
     --tests 'dev.whysoezzy.meet.service.AuthTokenIssuerTest' \
     --tests 'dev.whysoezzy.meet.service.UserServiceTest' \
     --tests 'dev.whysoezzy.meet.service.auth.identifier.*' \
     --tests 'dev.whysoezzy.meet.service.auth.otp.OtpHasherTest' \
     --tests 'dev.whysoezzy.meet.service.auth.otp.OtpRequestCoordinatorTest' \
     --tests 'dev.whysoezzy.meet.service.email.*' \
     --tests 'dev.whysoezzy.meet.service.AvatarReplacementServiceTest' \
     --tests 'dev.whysoezzy.meet.service.StorageServiceTest' \
     --tests 'dev.whysoezzy.meet.ingestion.timepad.TimepadProviderTest' \
     --tests 'dev.whysoezzy.meet.service.MeetingServiceTest'
   ```

Acceptance:

- README and runtime/test expectations agree;
- resolved MVC exception detail logging remains disabled;
- secret-safety, phone/email MVC, auth lifecycle, avatar/storage, admin/DTO, TIMEPAD, and ingestion-adjacent
  focused tests pass.

### Slice 7 — Satisfy the V7 operational gate

Ordinary transactional `CREATE INDEX` permits reads but blocks writes to `otp_codes` during the build. The
authoritative delivery-gate re-scope is recorded in task comment
`comment-84e5d3b5-4939-4543-8d2c-89d3ff67eff6`. It names NickolayMamonov as the database/release owner and
explicitly permits PR #19 merge and workflow completion because no persistent production email-OTP dataset or
live OTP write workload exists yet. Production measurements must not be fabricated.

The hard pre-deployment gate remains mandatory before V7 is applied to any persistent environment:

1. named owner supplies or validates aggregate evidence in a task comment or approved release record;
2. the implementation worklog references that record without copying credentials or sensitive operational data;
3. the replacement PR repeats the owner, decision, offered window, and evidence reference;
4. the owner approval remains externally auditable before merge.

For this re-scope, the durable record records that the production metrics are not yet applicable. Before
persistent V7 use, the same gate must record actual or explicit-zero row/size/write-rate metrics, PostgreSQL 16
timing or approved assumptions, an exact maintenance/write-block window, and explicit owner acceptance.

Safe database-size queries for an authorized operator to run are:

```sql
SELECT count(*) AS otp_codes_rows FROM otp_codes;
SELECT pg_size_pretty(pg_relation_size('otp_codes')) AS table_size,
       pg_size_pretty(pg_indexes_size('otp_codes')) AS indexes_size;
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE relname = 'otp_codes'
ORDER BY indexrelname;
```

Write rates come from the production monitoring system over an agreed representative normal interval and peak
interval; do not infer them from a one-off repository test. Build duration comes from an ephemeral
production-sized PostgreSQL 16 staging clone when available. If no clone is available, the named owner must
approve a documented estimate that states row count, total bytes, hardware/I/O, concurrent load, and safety
margin.

Before V7 is applied to any persistent shared database, record:

1. production `otp_codes` row count;
2. table size and every existing index size;
3. normal and peak `otp_codes` write rates;
4. PostgreSQL 16 index-build duration from a production-sized staging clone, or a documented estimate with data
   volume, hardware, I/O, and load assumptions;
5. the offered write-block/maintenance window;
6. the named database or release owner;
7. that owner's explicit acceptance of the window;
8. the durable evidence location and approval record.

Disposable Testcontainers execution is allowed before this gate. PR merge and workflow completion are allowed
under the authoritative re-scope, but persistent V7 application is not.

If the hard pre-deployment owner approval, metrics/estimate, timing assumptions, or exact window is absent, block
only persistent V7 application and production rollout. Do not silently switch to `CREATE INDEX CONCURRENTLY`;
return for a separately reviewed nontransactional Flyway migration design before V7 has any persistent use. Once
V7 is applied persistently, treat its filename and contents as immutable.

Acceptance:

- the authoritative re-scope and its durable record are referenced;
- NickolayMamonov is recorded as the named database/release owner;
- the absence of a persistent production dataset/workload is recorded without fabricated metrics;
- the hard pre-deployment gate's required actual/zero metrics, timing assumptions, exact window, and explicit
  owner acceptance remain a precondition to persistent V7 application;
- no persistent V7 application occurred before approval.

### Slice 8 — Run complete automated and packaged-runtime verification

#### PostgreSQL suite

Run the mandatory tagged suite with no skip property:

```sh
./gradlew postgresTest
```

Record task output and JUnit counts proving PostgreSQL tests executed with zero skips. This must include:

- V5→V6→V7 migration and catalog checks;
- exact-SQL 60,000-row EXPLAIN;
- challenge cleanup `SKIP LOCKED`;
- challenge lifecycle/order/activation;
- verification, replay, expiry, rollback, and identity concurrency;
- persisted request/verification limits;
- meeting `(source, sourceExternalId)` idempotent upsert.

#### Full suites

```sh
./gradlew test
./gradlew --no-daemon clean build
```

Record every command, exit code, test count, failure count, and skip count. `clean build` must run with PostgreSQL
tests enabled, not with `-PskipPostgresTests`.

#### Packaged startup and fail-fast matrix

Build the boot JAR once, then launch that packaged artifact against an explicitly disposable PostgreSQL 16
database/schema. Use generated non-production marker values that are not real credentials and never commit them.
Capture bounded startup logs outside the worktree.

Use this executable harness shape directly in Git Bash; it creates no repository file:

```sh
set -euo pipefail
run_id="mee2-27-$RANDOM-$$"
pg_container="$run_id-postgres"
runtime_dir="$(mktemp -d)"
app_pid=""

stop_app() {
  pid="${1:-${app_pid:-}}"
  test -n "$pid" || return 0
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  wait "$pid" 2>/dev/null || true
  if test "${app_pid:-}" = "$pid"; then app_pid=""; fi
}

cleanup_runtime() {
  stop_app
  docker rm -f "$pg_container" >/dev/null 2>&1 || true
  rm -rf "$runtime_dir"
}
trap cleanup_runtime EXIT
marker_nonce="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \r\n')"
db_password="db-${marker_nonce}"
jwt_secret="jwt-${marker_nonce}-signing-material"
smtp_user="smtp-user-${marker_nonce}"
smtp_password="smtp-password-${marker_nonce}"
from_address="no-reply@${marker_nonce}.invalid"
hmac_key_id="runtime-${marker_nonce}"
hmac_key_base64="$(head -c 32 /dev/urandom | base64 | tr -d '\r\n')"

docker run --rm -d --name "$pg_container" \
  -e POSTGRES_DB=meet \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD="$db_password" \
  -p 127.0.0.1::5432 postgres:16-alpine >/dev/null
until docker exec "$pg_container" pg_isready -U postgres -d meet >/dev/null 2>&1; do sleep 1; done
db_port="$(docker port "$pg_container" 5432/tcp | sed -E 's/.*:([0-9]+)$/\1/')"

./gradlew --no-daemon bootJar
jar_path="$(find build/libs -maxdepth 1 -type f -name '*.jar' ! -name '*-plain.jar' -print -quit)"
test -n "$jar_path"

common_env=(
  "APP_JWT_SECRET=$jwt_secret"
  "APP_SMS_PROVIDER=disabled"
  "APP_EMAIL_PROVIDER=smtp"
  "APP_EMAIL_FROM=$from_address"
  "SPRING_MAIL_HOST=127.0.0.1"
  "SPRING_MAIL_PORT=2525"
  "SPRING_MAIL_USERNAME=$smtp_user"
  "SPRING_MAIL_PASSWORD=$smtp_password"
  "APP_OTP_HMAC_CURRENT_KEY_ID=$hmac_key_id"
  "APP_OTP_HMAC_CURRENT_KEY_BASE64=$hmac_key_base64"
  "INGESTION_ENABLED=false"
)

run_startup() {
  label="$1"; profile="$2"; shift 2
  log="$runtime_dir/$label.log"
  db_name="meet_${label//[^A-Za-z0-9_]/_}"
  docker exec "$pg_container" createdb -U postgres "$db_name"
  env "${common_env[@]}" \
    SPRING_DATASOURCE_URL="jdbc:postgresql://127.0.0.1:$db_port/$db_name" \
    SPRING_DATASOURCE_USERNAME=postgres \
    SPRING_DATASOURCE_PASSWORD="$db_password" \
    SPRING_PROFILES_ACTIVE="$profile" \
    java -jar "$jar_path" \
      --server.port=0 \
      --app.geocoder.enabled=false \
      --app.timepad.enabled=false \
      "$@" >"$log" 2>&1 &
  app_pid=$!
  pid=$app_pid
  deadline=$((SECONDS + 45))
  while kill -0 "$pid" 2>/dev/null; do
    if grep -Fq 'Started MeetBackendApplication' "$log"; then
      expected_dev_seed=f
      if test "$profile" = dev; then expected_dev_seed=t; fi
      datasource_proof="$(
        docker exec "$pg_container" \
          psql -U postgres -d "$db_name" -At -F '|' \
          -c "SELECT current_database(), EXISTS (
                SELECT 1
                FROM flyway_schema_history
                WHERE version = '5.1' AND success
              )" | tr -d '\r'
      )"
      test "$datasource_proof" = "$db_name|$expected_dev_seed"
      echo "$label temporary-datasource-proof=$datasource_proof"
      stop_app "$pid"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      stop_app "$pid"
      echo "$label did not reach packaged startup readiness" >&2
      return 1
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  app_pid=""
  grep -Fq 'Started MeetBackendApplication' "$log"
}

run_failure() {
  label="$1"; profile="$2"; shift 2
  log="$runtime_dir/$label.log"
  db_name="meet_${label//[^A-Za-z0-9_]/_}"
  docker exec "$pg_container" createdb -U postgres "$db_name"
  env "${common_env[@]}" \
    SPRING_DATASOURCE_URL="jdbc:postgresql://127.0.0.1:$db_port/$db_name" \
    SPRING_DATASOURCE_USERNAME=postgres \
    SPRING_DATASOURCE_PASSWORD="$db_password" \
    SPRING_PROFILES_ACTIVE="$profile" \
    java -jar "$jar_path" \
      --server.port=0 \
      --app.geocoder.enabled=false \
      --app.timepad.enabled=false \
      "$@" >"$log" 2>&1 &
  app_pid=$!
  pid=$app_pid
  deadline=$((SECONDS + 45))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      stop_app "$pid"
      echo "$label timed out instead of failing fast" >&2
      return 1
    fi
    sleep 1
  done
  set +e
  wait "$pid"
  status=$?
  set -e
  app_pid=""
  test "$status" -ne 0
  ! grep -Fq 'Started MeetBackendApplication' "$log"
}

run_missing() {
  label="$1"; profile="$2"; variable="$3"; shift 3
  log="$runtime_dir/$label.log"
  db_name="meet_${label//[^A-Za-z0-9_]/_}"
  docker exec "$pg_container" createdb -U postgres "$db_name"
  effective_env=(
    "${common_env[@]}"
    "SPRING_DATASOURCE_URL=jdbc:postgresql://127.0.0.1:$db_port/$db_name"
    "SPRING_DATASOURCE_USERNAME=postgres"
    "SPRING_DATASOURCE_PASSWORD=$db_password"
  )
  filtered_env=()
  for assignment in "${effective_env[@]}"; do
    case "$assignment" in
      "$variable="*) ;;
      *) filtered_env+=("$assignment") ;;
    esac
  done
  missing_override=()
  case "$variable" in
    SPRING_DATASOURCE_URL) missing_override=(--spring.datasource.url=) ;;
    SPRING_DATASOURCE_USERNAME) missing_override=(--spring.datasource.username=) ;;
    SPRING_DATASOURCE_PASSWORD) missing_override=(--spring.datasource.password=) ;;
  esac
  env -u "$variable" "${filtered_env[@]}" \
    SPRING_PROFILES_ACTIVE="$profile" \
    java -jar "$jar_path" \
      --server.port=0 \
      --app.geocoder.enabled=false \
      --app.timepad.enabled=false \
      "${missing_override[@]}" \
      "$@" >"$log" 2>&1 &
  app_pid=$!
  pid=$app_pid
  deadline=$((SECONDS + 45))
  while kill -0 "$pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      stop_app "$pid"
      echo "$label timed out instead of failing fast" >&2
      return 1
    fi
    sleep 1
  done
  set +e
  wait "$pid"
  status=$?
  set -e
  app_pid=""
  test "$status" -ne 0
  ! grep -Fq 'Started MeetBackendApplication' "$log"
}
```

Every helper creates a fresh database and passes direct effective `SPRING_DATASOURCE_URL`,
`SPRING_DATASOURCE_USERNAME`, and `SPRING_DATASOURCE_PASSWORD` values. Those properties outrank
`application-dev.yml` literals, so exact `dev` cannot fall back to `localhost:5432/meet_db`. This is required
because `dev` also includes `classpath:db/seed` and its V5.1 migration, while default/prod/test do not.

On every successful launch, query the unique database inside the temporary container before stopping the JVM.
Require `current_database()` to equal the per-case name. Require successful Flyway version `5.1` only for exact
`dev`; require it absent for default/prod/test. This proves exact `dev` used the temporary container and exercised
its profile-specific seed location rather than touching a host/shared database.

Use unique labels for every case. `run_missing` filters the selected effective direct property and removes any
inherited value. For a datasource property it also supplies an explicit empty command-line property, which
outranks every profile YAML fallback. Keep logs in `runtime_dir`, outside the worktree, until the marker scan
completes.

The exact successful invocations are:

```sh
run_startup default ''
run_startup prod prod
```

For exact `dev` and `test`, override the production email/HMAC values with the repository's approved
nonproduction fixture values while retaining the disposable datasource. Read those values at execution time so
the plan, command record, worklog, PR, and task comments never contain key material:

```sh
dev_key_id="$(awk '$1 == "current-key-id:" { print $2; exit }' src/main/resources/application-dev.yml)"
dev_key_base64="$(awk '$1 == "current-key-base64:" { print $2; exit }' src/main/resources/application-dev.yml)"
test_key_id="$(awk '$1 == "current-key-id:" { print $2; exit }' src/test/resources/application.yml)"
test_key_base64="$(awk '$1 == "current-key-base64:" { print $2; exit }' src/test/resources/application.yml)"
test -n "$dev_key_id" && test -n "$dev_key_base64"
test -n "$test_key_id" && test -n "$test_key_base64"

run_startup dev dev \
  --app.email.provider=fake \
  --app.otp.hash.current-key-id="$dev_key_id" \
  --app.otp.hash.current-key-base64="$dev_key_base64"
run_startup test test \
  --app.email.provider=fake \
  --app.otp.hash.current-key-id="$test_key_id" \
  --app.otp.hash.current-key-base64="$test_key_base64"
```

The helpers distinguish readiness, genuine early failure, and deadline expiry without relying on platform-specific
`timeout` exit codes. `stop_app` gives the JVM a bounded five-second TERM grace period and then uses KILL before
the final reap; the EXIT trap also terminates any active JVM. A deadline expiry is always a failed verification,
never a fail-fast pass.

Prove successful packaged startup readiness for:

1. no active profile with complete safe datasource/JWT/SMTP/HMAC settings;
2. exactly `prod` with the same complete safe settings;
3. exactly `dev`;
4. exactly `test`.

Prove startup fails before accepting traffic for:

- missing datasource URL, username, and password, one case at a time;
- missing JWT secret;
- email provider disabled outside exact dev/test;
- missing SMTP host, username, password, and From address, one case at a time;
- missing HMAC current key ID and key material, one case at a time;
- mixed `prod,dev`, `dev,test`, and `test,staging` profiles;
- unsafe Spring Mail overrides covered by `RuntimeConfigurationInitializerTest`, including disabled auth or
  STARTTLS, disabled hostname verification, trust-all, implicit SMTPS, JNDI, test connection, debug/TRACE,
  custom socket factory, unsafe TLS protocol/cipher override, and out-of-range timeout.

Use one `run_failure` call per unsafe property:

```text
--app.email.provider=disabled
--spring.mail.host=
--spring.mail.username=
--spring.mail.password=
--app.email.from-address=
--app.otp.hash.current-key-id=
--app.otp.hash.current-key-base64=
--spring.profiles.active=prod,dev
--spring.profiles.active=dev,test
--spring.profiles.active=test,staging
--spring.mail.jndi-name=java:comp/env/mail/session
--spring.mail.protocol=smtps
--spring.mail.test-connection=true
--spring.mail.properties.mail.smtp.auth=false
--spring.mail.properties.mail.smtp.starttls.enable=false
--spring.mail.properties.mail.smtp.starttls.required=false
--spring.mail.properties.mail.smtp.ssl.checkserveridentity=false
--spring.mail.properties.mail.smtp.ssl.enable=true
--spring.mail.properties.mail.smtp.ssl.trust=*
--spring.mail.properties.mail.smtp.ssl.protocols=TLSv1
--spring.mail.properties.mail.smtp.ssl.ciphersuites=TLS_RSA_WITH_AES_128_CBC_SHA
--spring.mail.properties.mail.smtp.ssl.socketFactory.class=unsafe.Factory
--spring.mail.properties.mail.debug=true
--spring.mail.properties.mail.smtp.timeout=999
--logging.level.org.eclipse.angus.mail=TRACE
```

Use `run_missing` for `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`,
`SPRING_DATASOURCE_PASSWORD`, and `APP_JWT_SECRET`. For the three datasource variables, the helper removes the
effective direct environment property and adds the corresponding empty `--spring.datasource.*=` command-line
property. This prevents default, `prod`, `dev`, or any future profile from falling back to a literal datasource.
Run each missing case against both default and `prod` as required by the approved matrix; a datasource timeout
does not count as fail-fast success.

For every case:

- bound process lifetime with a timeout;
- record expected/actual exit behavior;
- prove marker values are absent from logs and throwable text;
- do not connect to a real SMTP provider or send a real message.

The controlled-inbox SMTP send/verify canary remains an external release gate because it requires operator
credentials and inbox access; do not fabricate success. A-048 remains a separate release gate.

Acceptance:

- focused, PostgreSQL, full, and clean-build checks pass;
- PostgreSQL tests demonstrably ran rather than skipped;
- all four packaged startup cases pass;
- every successful case proves the exact unique database inside the temporary PostgreSQL container, and exact
  `dev` alone proves V5.1 seed application;
- every unsafe/missing-setting case fails fast as expected;
- captured output contains none of the generated secret/sensitive markers.

### Slice 9 — Audit security, migration integrity, and repository state

1. Run a scoped sensitive-marker scan over:
   - tracked source/resources/docs;
   - generated test reports and runtime logs;
   - packaged JAR contents/resources;
   - distribution artifacts.
2. Search for generated unique markers covering OTP, email, phone, IP, device ID, JWT, refresh token, database
   password, SMTP password, provider token/payload/message ID, OTP hash/salt, HMAC key ID/material, and unsafe
   exception text. Exclude only intentional test-fixture source literals, and document every exclusion.
3. Confirm no plaintext OTP column or JPA `OtpCode` owner has returned:

   ```sh
   git grep -n -E 'class OtpCode|interface OtpRepository|\\bcode\\b.*otp_codes' -- \
     src/main/kotlin src/main/resources/db/migration
   ```

   Review matches semantically; migration history may intentionally reference the dropped legacy column.
4. Confirm one cleanup SQL owner and no test copy:

   ```sh
   git grep -n 'CLEANUP_SQL\\|WITH eligible AS' -- src/main src/test
   ```

5. Re-run V1–V6 blob comparison from Slice 4.
6. Run:

   ```sh
   git diff --check
   git status --short
   ```

Acceptance:

- no sensitive marker appears outside an intentional fixture location;
- no secret is present in commands, comments, commits, logs, reports, or artifacts;
- OTP persistence remains JDBC/HMAC-only and singly owned;
- V1–V6 remain byte-identical to MEE2-23;
- the SQL-source scan shows one production definition consumed by runtime and tests;
- `git diff --check` passes.

### Slice 10 — Checkpoint, re-fetch dev, repeat affected checks, and open the replacement PR

1. After Slices 3–9 and their first verification pass, commit an implementation checkpoint containing the
   approved source, migration, tests, README, planning artifacts, and then-current evidence. Record this commit as
   the **verified implementation commit**:

   ```sh
   git diff --check
   git add <reviewed-paths-only>
   git commit
   verified_implementation_commit="$(git rev-parse HEAD)"
   ```

   Do not put a claim about this commit into a file before it exists. Add it to the worklog in the next evidence
   commit.
2. Immediately before final verification and PR creation:

   ```sh
   git fetch origin dev
   git rev-parse origin/dev
   ```

3. If `origin/dev` advanced since Slice 1:
   - inspect the full intervening log/diff;
   - merge the new tip normally, resolve/stage reviewed conflicts, and complete its merge commit;
   - repeat overlap analysis;
   - rerun every affected focused check and then all Slice 8 and Slice 9 final checks;
   - return to design/architecture review if scope became material.
4. Create or finish the implementation worklog/evidence table with:
   - verified implementation commit and graph/parent ancestry;
   - integrated MEE2-23 and dev commit IDs;
   - Java, Gradle, Docker, and PostgreSQL versions;
   - every verification command, exit code, and test count;
   - proof `postgresTest` was not skipped;
   - packaged startup/fail-fast results;
   - V1–V6 blob evidence;
   - V7 catalog output and Flyway validations;
   - formatted plan evidence and PostgreSQL version;
   - `SKIP LOCKED` result;
   - V7 operational-gate evidence and named approval;
   - marker-scan scope/results/exclusions;
   - external SMTP canary and A-048 status as external gates.
5. Review the final diff relative to both source lines and then-current `dev`.
6. Commit the updated evidence and any reviewed final-dev conflict adaptations as a separate evidence/finalization
   commit. Do not amend unrelated history.
7. Require:

   ```sh
   git diff --check
   test -z "$(git status --short)"
   ```

8. Push the task branch without force. Record the resulting **final branch head** in the task record and PR
   description; the committed worklog is not required to contain its own commit SHA.
9. Open a replacement PR targeting then-current `dev`. The description must:
   - state that it supersedes PR #18;
   - leave PR #18 open and unchanged;
   - summarize the preserved MEE2-23 surface and current-dev avatar/storage surface;
   - isolate the small MEE2-27-authored delta;
   - include verification, migration, V7 gate, rollout, rollback, and external-gate evidence.
10. Verify the PR is open, targets `dev`, is mergeable against the fetched tip, and contains the intended commit
   ancestry.

Acceptance:

- the branch contains the current `dev` tip and preserved MEE2-23 ancestry;
- all final checks were run after the last integration;
- all approved files are committed and `git status --short` is empty;
- the pushed PR is mergeable into current `dev`, explicitly supersedes but does not mutate PR #18, and carries
  complete evidence.

## Cross-cutting acceptance criteria

The implementation is acceptable only when all of the following are observable:

### Git and composition

- MEE2-23 commits `3851feb`, `6ef2b05`, and `681c09b` remain ancestors of the final branch.
- Then-current `origin/dev` is integrated with normal merge history.
- No rebase, squash, history recreation, force-push, or PR #18 mutation occurred.
- `build.gradle.kts`, `RuntimeLoggingSafetyTest`, and `ErrorContractMvcTest` preserve both branches' required
  behavior.

### Product and architecture

- Android phone endpoints remain byte-stable in success/error bodies, statuses, codes, messages, claims, and
  headers.
- Email endpoints remain additive and account-enumeration-safe.
- `AuthController`/DTO/error handler remain HTTP boundaries; `AuthService` remains the channel-aware facade.
- `service/auth/identifier` remains the sole canonical identifier/trusted request-context boundary.
- `service/auth/otp` remains JDBC-owned with one challenge persistence owner and the approved request and
  verification transaction/lock order.
- `auth_identities` remains the sole login mapping; profile email/phone are not alternate auth sources.
- HMAC framing, salt/hash sizes, key-ring validation/rotation, constant-time comparison, and raw-code lifetime are
  unchanged.
- Admin gating, DTO projection boundaries, TIMEPAD mapping/location, ingestion identity, refresh/logout/deletion,
  and atomic avatar/storage behavior remain unchanged.

### Cleanup and migration

- Runtime and EXPLAIN use `OtpChallengeStore.CLEANUP_SQL` verbatim.
- Cleanup samples `clock_timestamp()` once, is status-free and oldest-first, and uses bounded `LIMIT` plus
  `FOR UPDATE SKIP LOCKED`.
- V7 contains only `idx_otp_codes_expires_id (expires_at, id)`; V1–V6 and the V6 status-leading index remain
  unchanged.
- One-schema migration coverage proves V5→V6→V7 and exact catalog shape.
- The 60,000-row unforced JSON plan uses V7 with an `expires_at` index condition and no eligible-path Sort.
- Separate concurrency proves locked-oldest-row skip and later deletion.
- The authoritative re-scope is recorded and explicitly permits merge/workflow completion; the hard
  pre-deployment operational gate remains required before persistent V7 use.

### Verification, security, and release

- Focused tests, mandatory `postgresTest`, full `test`, and no-daemon `clean build` pass.
- Packaged default/prod/dev/test startup uses direct per-case Spring datasource properties and fresh temporary
  PostgreSQL databases; each case proves its unique database in the temporary container, exact `dev` proves V5.1,
  and default/prod/test prove V5.1 absent.
- All missing/unsafe fail-fast cases behave as required. Missing datasource cases remove the effective direct
  property and use an empty higher-precedence command-line override, so profile YAML cannot supply a fallback.
- Logs, errors, test output, task comments, commits, and artifacts expose none of the prohibited sensitive data.
- README correctly states resolved MVC exception logging is disabled in `dev`.
- Committed evidence records the verified implementation commit, versions, commands/exits, test counts,
  migration/catalog/plan/concurrency proof, gate approval, marker scan, ancestry, and clean-worktree check. The
  PR/task record separately records the final branch-head SHA after the evidence commit exists.
- Controlled SMTP canary and A-048 are accurately reported as external release gates, not falsely marked passed.

## Production rollout and rollback

The initial production release moves from pre-V6 `dev` to the V6/V7-aware application and must be coordinated:

1. Verify production email/DNS/provider readiness, SMTP secrets, trusted-proxy CIDRs, backup ownership, accepted
   V7 window, and an identical complete HMAC key ring for every instance.
2. Back up PostgreSQL and stop every pre-V6 application instance plus profile/auth writers.
3. Apply V6 and V7 under the approved index-build plan.
4. Start every application instance with the same accepted current/previous key ring.
5. Validate schema and safe logs.
6. Run phone compatibility and controlled email send, verify, refresh, and logout canaries.
7. Reopen public traffic only after all canaries pass.

Rollback:

- Before public traffic or post-cutover writes, restore the pre-cutover database backup and pre-V6 artifact.
- After post-cutover writes, forward-fix by default. Restore the backup only if an authorized recovery owner
  explicitly accepts losing all post-cutover writes.
- For later releases, a known V6-aware artifact may roll back while retaining V7 if schema and key-ring
  compatibility are confirmed.
- Never run a pre-V6 binary against V6/V7, down-migrate in place, edit applied V6/V7, or recreate plaintext OTP
  storage.

## Explicit non-goals

- Reimplementing or redesigning B-056.
- Changing phone or email endpoint contracts, quotas, retention, retry headers, JWT claims, or lifecycle behavior.
- Linking a legacy `users.email` profile value to an auth identity.
- Adding provider-specific email aliases, Redis, queues, outboxes, provider SDKs, services, tables, schedulers, or
  deployables.
- Adding a status predicate to cleanup or dropping/replacing the V6 index.
- Copying cleanup SQL into tests, forcing planner settings, or asserting timing/cost/estimate details.
- Editing V1–V6 or changing V7 after persistent use.
- Changing admin policy, DTO projections, TIMEPAD mapping/package, ingestion upsert identity, or avatar/storage
  ownership.
- Guaranteeing mailbox/deliverability-enumeration opacity beyond application-account enumeration resistance.
- Completing the operator-controlled SMTP inbox canary or A-048 inside repository automation.
- Rebasing, squashing, force-pushing, closing PR #18, or otherwise rewriting/mutating its history or state.
