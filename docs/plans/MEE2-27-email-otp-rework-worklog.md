# MEE2-27 implementation evidence

Date: August 2, 2026

Verified implementation commit: `70c2adb771cd2058e84ecce9eff55c7528d64c6b`.

## Source composition

- Started from the task worktree at `d3b34d7`.
- Fast-forwarded to `origin/MEE2-23@681c09b`, preserving `3851feb`, `6ef2b05`, and `681c09b`.
- Merged `origin/dev@ebb6955` with a normal merge commit.
- Composed the `build.gradle.kts`, `RuntimeLoggingSafetyTest`, and `ErrorContractMvcTest` overlaps. The
  logging test retains OTP/SMTP/configuration safety coverage and uses the current `StorageService.deleteUploaded`
  contract; the MVC test retains both email/auth and avatar/storage coverage.
- PR #18 remains open and unchanged.

## Authored implementation delta

- `OtpChallengeStore.CLEANUP_SQL` is the single shared challenge-cleanup SQL value used by runtime cleanup and
  PostgreSQL plan coverage. It samples `clock_timestamp()` once, orders by `(expires_at, id)`, limits the batch,
  and uses `FOR UPDATE SKIP LOCKED`.
- Added only `V7__index_otp_cleanup_selection.sql`, creating
  `idx_otp_codes_expires_id (expires_at, id)`. V1 through V6 remain immutable.
- Extended migration coverage through an explicit V5 to V6 boundary followed by V6 to V7 catalog and Flyway
  validation.
- Added a deterministic 60,000-row PostgreSQL plan proof and a locked-oldest-row cleanup/retry proof.
- Corrected the README to state that resolved MVC exception logging remains disabled in both production and `dev`.

## Verification

All PostgreSQL checks used a fresh disposable PostgreSQL 16 container through the repository's external test
database configuration. No shared or persistent database was used.

| Command or check | Result |
| --- | --- |
| `./gradlew compileTestKotlin -PskipPostgresTests=true` | Passed |
| Focused non-PostgreSQL auth/config/logging/avatar/storage/TIMEPAD tests with `-PskipPostgresTests=true` | Passed |
| Focused migration and cleanup PostgreSQL tests | 5 passed, 0 failed |
| `./gradlew postgresTest` | 36 passed, 0 failed, 0 skipped |
| `./gradlew test` | 116 passed, 0 failed, 0 skipped |
| `./gradlew --no-daemon clean build` | Passed; 10 actionable tasks |
| `git diff --check` | Passed |
| V1 through V6 Git blob comparison against `origin/MEE2-23` | All matched |
| Cleanup SQL ownership and plaintext OTP-owner scan | Passed; no legacy persistence owner restored |

The packaged runtime matrix passed with generated non-production markers and logs kept outside the worktree:

- default, `prod`, exact `dev`, and `test` each used a fresh per-case database through direct effective
  `SPRING_DATASOURCE_URL`, `SPRING_DATASOURCE_USERNAME`, and `SPRING_DATASOURCE_PASSWORD` properties;
- each successful JVM was checked with `current_database()` inside the temporary container;
- only exact `dev` contained successful Flyway version `5.1`; default, `prod`, and `test` did not;
- missing datasource URL, username, and password were run for default and `prod` after removing the effective
  environment property and supplying the empty higher-precedence command-line override;
- missing JWT, disabled email, missing SMTP/from/HMAC settings, mixed profiles, and all unsafe SMTP/logging
  overrides failed with bounded nonzero exits; timeout was never accepted;
- generated database/JWT/SMTP/from/HMAC markers were absent from captured logs.

## Operational and external gates

V7 was applied only in disposable test databases. Production row/size/write-rate evidence and named
database/release-owner approval for the ordinary transactional index-build window remain required before any
persistent V7 application or production rollout. The controlled-inbox SMTP canary and A-048 remain external
release gates and were not fabricated as repository-test results.
