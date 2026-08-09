# Backend release publishing and production gate

The backend has one independent SemVer authority in `version.json`. Gradle,
Spring Boot build metadata, OpenAPI metadata, the OCI version label, Release
Please, and the release manifest must agree on the same
`MAJOR.MINOR.PATCH` tuple. The source identity is the exact lowercase
40-character commit SHA.

## Release flow

Release Please runs only for pushes to `dev`, targets release PRs to `dev`, and
uses the dedicated `RELEASE_PLEASE_TOKEN`. This is a fine-grained,
repository-restricted token owned by the release operator. It must have only
the contents and pull-request permissions required to open/update the Release
Please PR and create its draft release. Record its owner, repository
restriction, expiration, and rotation date in the operator's credential audit;
never put the value in this repository or in logs.

Merging the release PR causes the same `release-please.yml` run to receive
`release_created=true`. That output is the only normal publication authority.
The publication job reruns CI, validates the exact tag/source SHA/version
tuple, builds only `linux/amd64`, and publishes exactly:

* `vMAJOR.MINOR.PATCH`
* `MAJOR.MINOR.PATCH`
* `sha-<full-source-sha>`

There is no `latest` alias. The image digest is deployment authority. The
release manifest and `SHA256SUMS` are attached before the draft is made public;
the release publish operation is the final mutation.

GHCR does not provide a compare-and-swap primitive in this publication flow.
The accepted admission mechanism is therefore explicit and two-layered:

1. The job uses one package-scoped GitHub Actions concurrency group and, before
   its first GHCR write, creates the non-forced Git ref
   `refs/tags/release-lease-v<version>-<source-sha>` with
   `scripts/acquire-release-lease.sh`. Git ref creation is create-only, so
   cooperating writers cannot both acquire the same lease. The lease is never
   deleted and is an audit/quarantine marker. A complete pre-existing release
   is reused without acquiring a new lease.
2. The build publishes the exact three aliases in one BuildKit promotion
   operation, after a fresh read-only empty-state check taken immediately
   after lease acquisition. An identity-aware post-publish inventory is
   mandatory. If an external writer that is outside the lease policy races
   either check or the operation, the resulting partial, divergent, or
   identity-mismatched state is quarantined: the draft stays unpublished, the
   local quarantine evidence is attached, and no GHCR repair, retag, copy,
   overwrite, or delete is attempted.

The zero-write guarantee applies to `release-registry-state.sh` and recovery:
they never mutate GHCR, including when status 42 is returned. It does not
pretend that an unauthorized package writer can be prevented by a registry CAS
that does not exist. GHCR package write access must remain restricted to the
approved publication path. The authorized recovery is a new Conventional
Commit on `dev`, which creates a distinct patch tuple and source SHA through
Release Please; an old lease is not reused.

The publication workflow captures the registry inspection exit status under
`set +e`. A status 42 is therefore handled as evidence: its quarantine JSON is
checked, attached to the still-draft release, and only then is the job failed.
It is never allowed to terminate the shell before the draft receives the
quarantine note.

BuildKit provenance and SBOM publication is accepted only when the OCI index
contains subject-bound attestation descriptors and their child manifests carry
the expected in-toto predicate types (`slsa.dev/provenance` and SPDX or
CycloneDX). `scripts/verify-oci-evidence.sh` derives the `provenance` and
`sbom` fields in the release manifest from those descriptors; the workflow does
not treat a handwritten boolean as evidence.

## Production access prerequisites

`NickolayMamonov` is the current master-promotion authority. Before promoting
`dev` to `master`, an operator must record a distinct real GitHub login or team
as `PRODUCTION_APPROVER`. The identity must be an actual collaborator/team,
must review the promotion, and must be the required reviewer for the
`production` Environment. The dispatch initiator and reviewer must be
different people. No placeholder identity is committed or used.

Configure and audit enforceable protections on both `dev` and `master`:

* pull requests are required, with at least one approval;
* stale approvals are dismissed and approval is required after the latest
  push;
* required CI checks are strict and conversations must be resolved;
* force-push and branch deletion are blocked;
* administrators and other bypass actors are not exempt.

The `production` Environment must have required reviewers, prevent self-review,
administrator bypass disabled where available, and a selected deployment
branch policy allowing only exact `master` (no tags). Run
`scripts/audit-default-branch-bootstrap.sh`,
`scripts/audit-github-policies.sh` with a real `PRODUCTION_APPROVER`, and
`scripts/audit-production-environment.sh` after the operator configures the
Environment. These scripts print names and policy evidence only, never values.
The bootstrap audit requires the dispatch/recovery workflow and helper blobs on
the actual default `master` ref and proves no master/dev drift. Until a
reviewed dev-to-master promotion supplies those blobs and the required
protections, dispatch and production readiness remain externally blocked.
Until that identity and those protections exist, production and master
promotion remain externally blocked.

## Protected-empty Environment proof

The first external rollout phase creates `production` with its protection rules
but **without** variables or secrets. Run:

```sh
GITHUB_REPOSITORY=NickolayMamonov/meet-backend-v3 \
GH_TOKEN="$GH_TOKEN" \
scripts/audit-production-environment.sh --expect-unconfigured
```

After a real designated reviewer approves a dispatch from `master`, the first
inline shell step in `deploy-production.yml` receives empty values and exits.
That step runs before checkout, DNS, GitHub API, registry, `ssh-keyscan`, or
SSH. This is the approved missing-configuration proof; no sentinel host,
password, private key, or fake fingerprint is allowed.

Only after operators possess the real VPS host, port, user, absolute path,
SSH host fingerprint, and private key may they store the five Environment
variables and one secret. Then run the configured-name audit:

```sh
GITHUB_REPOSITORY=NickolayMamonov/meet-backend-v3 \
GH_TOKEN="$GH_TOKEN" \
scripts/audit-production-environment.sh --expect-configured
```

Name evidence does not reveal values and does not certify a live deployment.
The deployment requires a healthy predecessor, host-local `.backup.env` with
`AGE_RECIPIENT`, strict native OpenSSH host-key verification, an encrypted
backup, digest pull, host `docker`, Compose, `flock`, `age`, and `curl`
commands, and the existing prepare/update/deploy/rollback scripts.
Before any of those scripts run, the workflow archives the reviewed Compose and
helper files, transfers them over the already fingerprint-validated connection,
verifies their SHA-256 manifest on the VPS, and invokes only that staged copy.
The staged scripts use the live production root for `.env.production`, state,
volumes, and locks while keeping their reviewed code root separate.
First install, database downgrade, infrastructure provisioning, and production
certification are out of scope.
