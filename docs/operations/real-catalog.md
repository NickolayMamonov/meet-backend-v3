# Real catalog operations

The real beta catalog is a manually reviewed, packaged resource. This document
describes the technical gate; it is not approval of any event, community,
description, image, date, or permission.

## Resource and approvals

Resources are immutable UTF-8 JSON files under `src/main/resources/real-catalog/`
and are addressed by a bounded revision label. The application never fetches
manifest URLs, source pages, media, SQL, or client-provided paths. A test
resource must be clearly synthetic and must not be used as beta content.

Every retained field has a public source, check instant, rights basis,
operator-held evidence reference, attribution, and retained-display permission.
The evidence reference is opaque and private correspondence never enters the
manifest, API response, logs, recovery proof, or Git history.

The packaged bytes are hashed as lowercase SHA-256. Preview returns only the
digest, generation, bounded key/count changes, and effective cutoff. Apply
requires the exact digest plus detached content, target-mutation, and recovery
references. The endpoint is disabled by default and remains behind the existing
admin key and `ROLE_ADMIN` gate.

## Freshness and transitions

`INITIAL`, `REVIEW`, `NEW_WINDOW`, and `CORRECT` are distinct intents. The first
window is exactly 30 elapsed days from the approved invitation instant. Active
starts must be after that window. Review freshness is seven elapsed days and
cannot extend the fixed window.

`CORRECT` can repair or retire existing roots, including a previously retired
root or the final active root. It cannot add keys, reactivate a retired key,
renew review, change the window, or increase the prior cutoff. Omitted owned
keys are retired while their IDs, details, participation edges, and history
remain. A separately approved full review or new window is required for
reactivation.

Discovery and new participation use the stored cutoff before SQL ranking,
pagination, or embedded `meetingsInfo` limits. Details, historical mappings,
participant/subscriber views, and leave/unsubscribe remain available.

## Protected operation sequence

1. Preserve the exact-source V9/V10 v1 recovery point and prove an isolated
   restore using the v1 tooling from the pre-migration source revision.
2. Deploy V11 and v2-capable code with real-catalog mutation disabled.
3. Capture and isolate-restore a new V11 v2 recovery point, including the empty
   real-catalog state. Compare structural, hash, identity, edge, and privacy
   commitments.
4. Obtain target-specific content and mutation approval, preview the exact
   digest, apply once, replay once, and verify stable IDs, edges, cutoff, and
   public DTOs.
5. Disable mutation after the bounded maintenance window. Weekly review creates
   a new approved revision; it does not silently renew an expired window.

An unknown or mixed v1/v2 schema, proof mismatch, failed restore, ownership
drift, stale generation, source identity collision, or uncertain apply outcome
blocks progression. Routine rollback is a new approved compensating manifest;
full restore is separately authorized disaster recovery.

The repository admission contract intentionally has no target-bound V11 digest
until that authorized capture exists. It fails closed with
`pending-authorized-v11-capture`; the test-only `test-fixture` contract path
does not constitute recovery or deployment evidence.
