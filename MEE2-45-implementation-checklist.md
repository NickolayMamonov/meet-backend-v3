# MEE2-45 remediation checklist

- [ ] Inspect current rollover implementation and map each approved finding to a concrete gap.
- [ ] Harden SPKI, Certbot lineage/configuration/hooks, Nginx directive rendering/publication, recovery namespace, and state/evidence boundaries.
- [ ] Add or update fixture coverage for each remediated failure mode.
- [ ] Update the runbook with exact merge gating, reconciliation/status semantics, and invariant evidence.
- [ ] Run syntax, diff, fixture, ShellCheck/Gradle checks where available; record blockers explicitly.
- [ ] Commit, push, add the required implementation-result task comment, and complete the task with exact metadata.
