# Test-VPS Timepad cutover and recovery

> **First Timepad transition: set `run_rollback_drill=false`.** The ordinary
> first-promotion guidance in
> [`operations/test-vps-deployment.md`](operations/test-vps-deployment.md#rollback-drill)
> says to enable the rollback drill for a new image. That guidance applies to
> reviewed, compatible promotions—not to the first migration-capable
> transition. A predecessor that has only pre-transition proof is not
> approved to start after the Timepad barrier. The guarded workflow must reject
> a requested drill before any writer runs. Set the input explicitly to
> `false` for the first transition; do not rely on a default or silently skip
> the drill. This exception does not weaken signal handling, failure
> quiescence, or the durable cutover fence.

## Scope and activation boundary

This procedure describes the guarded source workflow and its recovery contract.
The implementation template is intentionally inactive: merging source or
passing synthetic fixtures does **not** authorize production use. Do not
bootstrap or deploy a Timepad-capable release until the protected operator
authority, reviewed initial-state proof, and exact release evidence have been
separately supplied and approved. In particular, this document does not supply
real migration numbers, image identities, schema contents, guard evidence,
dependency floors, or retry-safety facts. MEE2-97 and the activation review
must provide those facts; do not infer them from version labels, health checks,
or this procedure.

No live VPS operation, database mutation, credential preparation, migration,
Flyway repair, down migration, image substitution, or state reset is authorized
by this document. Keep using the existing release and protected-environment
checks. The independent closed-beta promotion lane does not acquire this
guard's helper or recovery behavior.

## Admission and operator actions

The deployment dispatch distinguishes three operations:

| Operation | Use | Important constraints |
| --- | --- | --- |
| `deploy` | Ordinary deployment, including an admitted schema transition | Uses the usual release checks and the schema admission decision. The rollback drill remains enabled by default for compatible ordinary promotions. For the first Timepad transition, explicitly set `run_rollback_drill=false`. |
| `bootstrap-guard` | Initialize the durable guard on a separately reviewed initial deployment root | Requires explicit protected bootstrap authority bound to the root, unique bootstrap ID, observed initial runtime/configuration, and reviewed initial schema/startup proof. It initializes guard metadata only; it does not start the backend, migrate, prepare credentials, or rewrite deployment configuration. |
| `forward-recover` | Resume one specifically authorized unresolved incident | Requires explicit protected operator authority and exact selectors for that incident and candidate. It is never dispatched automatically; rollback-drill input must be disabled and mixed operation fields are rejected. |

An absent guard is not permission for an ordinary deployment. It permits only
the separately authorized bootstrap operation. Repeating the same completed
bootstrap at epoch zero is read-only; a different authority or an established
noninitial state is refused. An existing origin with a missing or corrupt
current record is lost state, not a request to bootstrap again.

Before a transition-capable candidate can be created or executed, the
controller must durably acknowledge `CUTOVER_POSSIBLE`. Admission is based on
reviewed exact-image, schema-transition, guard, dependency, and retry evidence,
not on a release ordering or a healthy process. The unchanged-domain path is
available only when both target and predecessor are positively shown to remain
in that domain. Unknown or missing proof refuses admission and never falls
back to the legacy path.

## Evidence and durable state

The bounded release contract (`format` 1, controller `timepad-cutover-v1`)
binds the reviewed initial domain, transition, and relevant exact images. Each
applicable image binding covers the repository digest, platform image ID,
revision/version, migration inventory identities, before/after schema
contracts, guard implementation evidence, resolved dependency policy, and
recovery coverage for interrupted or unknown migration outcomes. Initial-only
facts may be marked not applicable; that does not grant post-barrier
compatibility. The contract is limited to 64 KiB and eight relevant image
bindings. It is an inactive template until evidence is reviewed; opaque hashes
and labels are bindings, not evidence by themselves.

The root-owned guard directory contains immutable `origin.json` (at most
4 KiB) and authoritative `current.json` (at most 16 KiB). The current record
binds:

- format/controller and origin;
- unsigned 64-bit operation epoch, original operation and run;
- incident ID, phase, fixed reason, and latest bounded recovery-attempt ID;
- exact target and predecessor image tuples, transition/evidence binding, and
  frozen predecessor disposition;
- owned run basename and tooling digest;
- container and configuration identity, plus owned-child identity while one
  is active;
- immutable controller commit-witness digest, immutable provider-finalization
  witness digest, finalization substep, and terminal receipt. The provider
  witness is durably written and hashed before `COMMITTING`; the state binds
  both digests before provider cleanup starts. The provider witness itself
  remains private in the owned run directory.

The epoch increments once for each newly prepared operation; retry, phase
advancement, and finalization keep the same epoch. Authorization is bound to
the incident's immutable origin/run/operation/epoch/image/evidence tuple, not
to a mutable phase label. An older selector is stale after a newer operation.
Only one active/latest incident and a bounded replacement are retained; no
age-based eviction may remove evidence still referenced by the fence,
rollback image, or incident.

State contains no environment values, credentials or credential metadata,
database URL, raw inspection/log/error output, or provider payload. Private
provider finalization evidence stays in its owned run; public state stores only
its binding digest. The guard is local root-owned state, not protection against
privileged deletion of all provenance or rollback of the entire filesystem.

## Phases and restart/recovery behavior

The normal transition phases are:

`READY` (or a terminal state) → `PREPARED` → `CUTOVER_POSSIBLE` →
`VERIFYING` → `COMMITTING` → `COMMITTED`.

An admitted rollback follows `ROLLING_BACK` → `ROLLED_BACK` and **does not
lower the fence**. Failures before commit retain `RECOVERY_REQUIRED`; a failure
during finalization retains `COMMITTING` and its witness/substep. Exact
authorized retry may record `FORWARD_RECOVERING` while retaining the original
incident epoch. Startup, failed health checks, timeouts, and missing migration
output never prove that no transition occurred.

| Persisted phase / observation | Permitted response |
| --- | --- |
| `READY`, no guard, or invalid state | Normal deployment/recovery refuses. Bootstrap is a separate operation; malformed or lost state is not reconstructed. |
| `PREPARED`, barrier positively not attempted | Existing validated cleanup/rollback may run if all owned inputs remain intact. |
| `CUTOVER_POSSIBLE`, `VERIFYING`, uncertain barrier, or unknown child | Reconcile and quiesce only positively owned activity. Never start an unproven predecessor. If quiescence cannot be confirmed, retain the incident and report it as unconfirmed. |
| `COMMITTING`, exact healthy bound runtime with valid witness | Revalidate runtime, public checks, and cleanup receipt; resume finalization without stop/start/recreate. |
| `COMMITTING`, stopped or unhealthy runtime | Exact-candidate retry only when authorized and supported by authenticated live/residual/receipt proof. No fresh provider prepare. |
| `RECOVERY_REQUIRED` or `FORWARD_RECOVERING` | Resume only the same incident with matching selectors, epoch, and evidence. A healthy runtime with a valid witness may take finalization-only recovery. |
| `ROLLING_BACK` | Exact-target retry only with intact target inputs; otherwise refuse and require separately authorized repair. |
| `COMMITTED` | Matching exact terminal runtime and receipt permit read-only already-completed replay. |
| `ROLLED_BACK` or newer epoch | Reject stale forward-recovery selectors. The fence remains advanced after an admitted rollback. |

The first transition must quiesce/suppress the predecessor and persist the
barrier before candidate creation/start. Guarded candidate start suppresses
automatic restart until the candidate is verified and commit finalization is
safe. Terminal restart policy is restored on the same container; a Compose
recreation is not a recovery shortcut. These ordering guarantees require the
planned Ubuntu runtime evidence and are not claims established by this
documentation alone.

## Recovery authorization and results

`forward-recover` must identify the original root/origin, run and operation,
epoch, incident, evidence binding, exact image/revision/version, and action
`retry-exact-candidate`. These selectors identify what may be resumed; they
are not secrets or authentication. Protected workflow/operator authority is
still required. Validate all selectors and phase proof before any stop, state
write, or configuration mutation. A different image, action, root, incident,
stale epoch, evidence drift, unknown controller, or unrelated provider/SMTP
transaction is a refusal. Recovery does not build, prepare, repair, recreate
credentials, or switch to another image.

The workflow's bounded, allowlisted `schema_guard=` result is separate from
provider JSON. Interpret its result categories as follows:

| Result category | Meaning |
| --- | --- |
| Disabled | Guarded schema operation was not admitted/enabled; not a successful transition. |
| Rejected | Admission or requested action was refused before unauthorized mutation. |
| Successful drill | The compatible rollback drill completed and the predecessor was verified. Exit status `86` is reserved for this completed drill rollback; it is not a general recovery status. |
| Deployment | The guarded deployment completed its required runtime, provider, public, and receipt checks. |
| Recovery required | The incident remains unresolved and the service may be unavailable. Do not retry as an ordinary deployment or run retention as though deployment succeeded. |
| Quiescence unconfirmed | The controller could not prove owned backend activity stopped within its bound. Do not claim the backend is stopped or start a predecessor. |
| Already completed | Exact terminal runtime and receipt matched; replay was read-only and did not recreate the backend. |

These are result categories, not invented numeric exit codes. Accept a workflow
outcome only when the bounded result record and remote process status agree.
Missing, duplicate, malformed, unknown, or mismatched records fail closed.
Keep summaries sanitized; do not copy private state or provider payloads into
workflow output or artifacts.

## Operator stop conditions

Stop and preserve evidence on any unknown classification, missing/corrupt
guard state, conflicting bootstrap identity, selector mismatch, evidence
drift, timeout, failed stop/inspection, unexpected container, provider
transaction conflict, or `RECOVERY_REQUIRED` / `QUIESCENCE_UNCONFIRMED`
result. Do not clear the guard, delete transaction evidence, restart an
unproven predecessor, dispatch recovery automatically, or use retention to
remove unresolved evidence. Escalate for separately authorized exact-incident
forward recovery. If the incident is already committed, use read-only
already-completed replay rather than starting another run.

Source tests and isolated synthetic fixtures can establish controller logic;
they cannot establish production migration facts or real Compose, filesystem,
signal, lock, and retry behavior on Ubuntu. Production activation and any live
recovery require their separately approved evidence and authorization.
