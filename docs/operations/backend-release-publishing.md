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

The three aliases are immutable by this enforced publication policy, not by an
assumed GHCR compare-and-swap primitive. `scripts/release-registry-state.sh`
is deliberately read-only for complete, partial, divergent, and externally
raced states. A one- or two-alias state is quarantined and the old draft stays
unpublished. Do not push, retag, copy, overwrite, or delete an alias during
recovery. The authorized recovery is a new Conventional Commit on `dev`, which
creates a distinct patch tuple and source SHA through Release Please.

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
`scripts/audit-github-policies.sh` with a real `PRODUCTION_APPROVER` and
`scripts/audit-production-environment.sh` after the operator configures the
Environment. These scripts print names and policy evidence only, never values.
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
backup, digest pull, and the existing prepare/update/deploy/rollback scripts.
First install, database downgrade, infrastructure provisioning, and production
certification are out of scope.
