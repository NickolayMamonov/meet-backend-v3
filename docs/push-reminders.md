# Push reminders: operator notes

This document records the application contract and the gates around enabling
private meeting reminders. It is an operator guide for the reviewed backend
implementation, not authorization to send live notifications.

## Safe defaults and enablement flags

All push enablement flags default to `false`, including production:

```dotenv
APP_PUSH_PROVIDER_ENABLED=false
APP_PUSH_DISCOVERY_ENABLED=false
APP_PUSH_DISPATCH_ENABLED=false
APP_PUSH_DIAGNOSTIC_ENABLED=false
APP_PUSH_MAINTENANCE_ENABLED=false
APP_PUSH_PROJECT_ID=meeting-1d258
APP_PUSH_CREDENTIALS_FILE="<PROTECTED_ADC_FILE>"
```

`APP_PUSH_CREDENTIALS_FILE` is a placeholder only. Do not put a service-account
key, FID, JWT, or credential path in source control, issue comments, shell
history, logs, or this document. Disabled contexts do not load ADC or create a
Firebase client. Discovery, dispatch, and the diagnostic require the provider
flag; credential-free maintenance may still run when maintenance, discovery,
or dispatch is enabled.

The rollout order is:

1. Deploy the additive backend and migration with all sending flags disabled.
2. Verify the compatible Android registration candidate and API behavior.
3. At a separately approved gate, install a regular protected read-only ADC
   file readable by runtime UID/GID `10001:10001`, then prove that the
   canonical deployment definition captures that file mount across both
   upgrade and rollback.
4. Enable the provider and one exact-target diagnostic only after the mount,
   configuration, and operator authorization checks pass.
5. Enable ordinary discovery and dispatch only after the Android device proof.

This ticket does not apply credentials, edit the base Compose/deployment
tooling, mutate a VPS, dispatch a workflow, or send a live push.

## Protected diagnostic

The diagnostic is default-off and remains behind the existing admin-key-derived
`ROLE_ADMIN` boundary. A bearer JWT alone is not sufficient. The endpoint is:

```http
POST /admin/push/diagnostic
X-Admin-Key: <ADMIN_KEY>
Authorization: Bearer <JWT>
Content-Type: application/json
```

Illustrative request template, with placeholders for every selected value.
Replace the numeric placeholders before sending; the block is intentionally
not literal JSON until those substitutions are made:

```text
{
  "userId": <USER_ID>,
  "installationId": "<INSTALLATION_UUID>",
  "meetingId": <MEETING_ID>,
  "reminderOffsetMinutes": 60,
  "mode": "SINGLE"
}
```

Only `userId`, `installationId`, `meetingId`, `reminderOffsetMinutes`, and
`mode` are accepted. IDs must be positive, the installation UUID must be
canonical lowercase, the offset must be `60` or `1440`, and the mode must be
`SINGLE` or `DEDUP_PAIR`. The selected user must be nondeleted and opted in;
the installation must be owned, active, fresh, and have its current FID; and
the user must be joined to an active future meeting. The diagnostic does not
need to be inside the ordinary reminder due window.

The endpoint never accepts topics, token lists, broadcasts, wildcards, query
targeting, caller-supplied event IDs/timestamps/content, or arbitrary extra
JSON fields. Unknown, inactive, or not-owned selections are intentionally
indistinguishable. Responses contain category values only:

- `SINGLE`: `{ "result": "ACCEPTED" }` (or another typed category).
- `DEDUP_PAIR`: `{ "result": "ACCEPTED_PAIR", "first": "ACCEPTED", "second": "ACCEPTED" }`
  only when both sequential calls are accepted; all other combinations are
  `INCONCLUSIVE`.

Possible per-call categories are `ACCEPTED`, `INVALID_TARGET`,
`RETRYABLE_FAILURE`, `PROVIDER_UNAVAILABLE`, and `NOT_ATTEMPTED`. The service
does not return selected IDs, FIDs, payloads, provider message IDs or bodies,
exception text, or SDK details.

## Delivery and timeout limits

The backend provides durable logical deduplication and **at-least-once**
external delivery. `ACCEPTED` means the provider accepted the request; it does
not prove device receipt, display, or tap navigation. A process death after
provider acceptance, a lease overrun, or a race after the final eligibility
check can produce a duplicate with the same event ID. Android owns
account-scoped duplicate presentation suppression.

The bounded application policy is:

- Two offsets: `1440` and `60` minutes before the meeting start.
- Four sequential dispatch workers, with one occupied provider call per worker.
- At most five logical leased attempts for one target; no sixth call.
- Ten-minute database leases, with a fifteen-minute claim grace window.
- Discovery, maintenance, and recovery passes are bounded to 100 candidates.
- One nonblocking diagnostic permit covers a whole `DEDUP_PAIR`; saturation is
  rejected rather than queued.
- FCM connect/read/write timeouts are 5,000 ms each.
- Firebase's supported SDK may perform internal HTTP 503 retries and honor
  `Retry-After` for up to 60 seconds. An individual FCM operation has an
  approximate 315-second operational phase estimate, not a hard total-call
  deadline.

OAuth credential refresh has a potentially unbounded write phase in the
official SDK. Cancellation does not prove that network I/O stopped, and an
occupied worker/diagnostic slot remains occupied until the synchronous provider
call actually returns. These are accepted operational limitations; do not
report a watchdog timeout as proof of delivery failure or call termination.

Retryable transport, timeout, quota, `INTERNAL`, and `UNAVAILABLE` outcomes
remain non-terminal while the deadline and meeting start permit another
logical attempt. Only the documented `UNREGISTERED` result permits exact-FID
installation invalidation. Authentication, permission, project mismatch,
generic invalid argument, payload/configuration, and unknown failures are
noninvalidating unavailable outcomes.

## Sanitized state interpretation

Installation history distinguishes `ACTIVE`, `UNREGISTERED`, `INVALID`,
`EXPIRED`, `TRANSFERRED`, and `ACCOUNT_DELETED`. Only `ACTIVE` rows retain a
current FID. Historical reminder targets retain owner and installation
identity, but never copy FIDs, payloads, provider responses, or message IDs.

Reminder target states are `PENDING`, `LEASED`, `RETRY_WAIT`, `SENT`, `INVALID`,
`FAILED`, and `SKIPPED`. Claim states are `PENDING`, `SENT`, `FAILED`,
`SKIPPED`, and discovery-only `NO_TARGET`. Terminal history is not reopened,
and deduplication keys are not recycled. A stale lease completion has no
side effects, including no retry, invalidation, reduction, or success
accounting.

Logs and API errors use static, sanitized categories. They must not contain
FIDs, credential values or paths, JWTs, OTPs, payload PII, provider details,
message IDs, SDK messages, or secret-bearing causes. Treat a provider
acceptance as an external-delivery observation, not a client receipt
observation.

## Android compatibility candidate

The reviewed compatibility candidate is Android `NickolayMamonov/Meeting` PR 79,
head `83d2caace8b0ce53a45870ad4ef826fa8c1e9b69` (inspected September 11,
2026). It registers Firebase Installation IDs (FIDs), not legacy FCM tokens.
The backend registration lifecycle must therefore preserve the exact FID and
owner boundary; a transferred-away installation UUID is permanently retired.

Reminder messages are data-only and contain exactly these seven string fields:

| Field | Value |
| --- | --- |
| `eventType` | `MEETING_REMINDER` |
| `schemaVersion` | `1` |
| `eventId` | canonical lowercase UUID |
| `meetingId` | canonical positive decimal |
| `reminderOffsetMinutes` | `60` or `1440` |
| `issuedAt` | canonical UTC `Instant.toString()` value |
| `destination` | `MEETING_DETAILS` |

There is no notification block, title/body, meeting metadata, account data,
or extra key. Android owns permission prompts, generic notification copy,
durable event-ID suppression, and validated meeting-detail navigation. Backend
compatibility is necessary but does not establish device receipt or a
single-presentation result.

## Evidence and release gate

Application verification includes focused push/configuration/API tests, the
full non-PostgreSQL Gradle suite, PostgreSQL integration tests, shell syntax
and ShellCheck, and workflow actionlint. The CI workflow records the actual
`git rev-parse HEAD` for each Gradle, PostgreSQL, scripts, and Docker job.
Ordinary pull requests resolve reviewed source in this order:

1. Explicit reusable-call `inputs.ref`, when supplied.
2. Pull-request head SHA.
3. `github.sha` for pushes and other non-PR runs.

Explicit release calls retain separate `tooling` at `github.sha` and `source`
at the exact `inputs.source_sha`; the recorded source identity must match the
release SHA. Missing actionlint, ShellCheck, Docker, PostgreSQL, or hosted
workflow evidence is a blocker, not a verification waiver. No live provider
or device proof is claimed by local tests.

Required later operator evidence is separate: protected ADC mount readability
as the runtime UID/GID, upgrade/rollback mount capture, authorized exact-target
SINGLE receipt and tap in foreground/background/terminated states, accepted
pair with one presentation/navigation, and controlled 24-hour/1-hour reminder
delivery. Enablement remains off until those gates are reviewed.

On rollback, disable sending first and use a compatible prior binary while
retaining V10 and reminder history. Do not down-migrate or delete/recycle
deduplication keys.
