# Leaf SPKI rollover

This is edge-specific operational tooling for `api.whysoezzy.online`. It is
additive Bash/docs/fixture/CI scope: backend code, Android APIs, TIMEPAD,
Compose/runtime, PostgreSQL/Flyway, and release metadata remain unchanged.
Release `368531227`, its tag, assets, GHCR objects, and attestations are a
permanent no-mutation boundary.

Before **every** live command, the operator must prove the reviewed actual
merge commit, approved merge tree, and hosted synthetic-merge checks. SHA-256
bytes and safe metadata of the fixed installed entry point and library must
equal the corresponding `git show <actual-merge>:<path>` bytes. A failed gate
means the command is not invoked; the CLI accepts no revision, path, hostname,
lineage, release, or mode arguments.

The closed interface is exactly:

```text
inspect
configure-primary
ensure-rollover
configure-rollover
verify-primary-renewal
verify-rollover-renewal
drill
restore --confirm-restore=RESTORE-PRIMARY
```

`restore` is lock-protected and deterministically selects active-only or
completed-only. Active-only retains the existing O/C/M_CERT/M_KEY restore.
Completed-only first validates the complete immutable manifest-bound package,
exact original Nginx source/topology `O`, and external primary
SPKI/hostname/normal chain. Its sole admitted effect is idempotent sync of the
fixed recovery parent, followed by completed reopen/full revalidation and
sanitized evidence persistence. It never writes/tests/reloads Nginx, invokes
Certbot, renames/edits/deletes packages, or mutates backend, Compose,
PostgreSQL, or the database.

Invalid package, namespace, source, or primary returns `20`, `65`, or `69`
with zero sync and completed retained. Sync, reopen, or evidence persistence
failure after primary proof returns `73` and is safely retryable with the same
externally gated confirmation. Exit `0` proves terminal primary, completed,
durability, evidence, and green invariants; exit `10` proves those properties
with advisory drill drift. Existing `64`, `65`, `69`, `70`, and `75` meanings
remain.

The primary lineage is `api.whysoezzy.online`; rollover is the explicitly
named `api.whysoezzy.online-rollover`, with distinct canonical Base64
SHA-256 leaf SPKI digests. Private keys, raw certificates, tokens, cookies,
credentials, and provider secrets never enter evidence.
