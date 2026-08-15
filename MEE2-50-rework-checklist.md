# MEE2-50 rework checklist

- [x] Correct owned synthetic-user notification state to `false` for insert and repair.
- [x] Preflight current and desired synthetic-email OTP history, phone OTP history, and EMAIL identity collisions.
- [x] Globally preflight canonicalized desired synthetic-email OTP history, including clean databases without owned users.
- [x] Enforce the singleton media host and exact approved media/landing URL sets.
- [x] Add focused evidence for contamination/rollback, PHONE identity non-collision, exact paths, all thirteen resources, and exact response shape.
- [x] Add injected-failure PostgreSQL rollback snapshots with a cleared persistence context across catalog roots, relationships, state, profile/auth fields, and auth storage.
- [x] Repair owned meeting hosts displaced by unowned real rows and report added/removed host relationships while preserving those rows.
- [x] Pin frozen catalog metadata, typed references, and all five root plus nine relationship counts in the manifest validator.
- [x] Seed owned scalar drift before injected failure and compare the complete PostgreSQL snapshot after clearing the persistence context.
- [x] Run the required focused, full, PostgreSQL, clean-build, diff, and idempotency/contamination/preservation/auth-storage checks.
- [x] Commit and push the rework and add the implementation-result task comment.
- [ ] Record the environment-gated disabled deployment/exact-host probe and MEE2-52 restore-proof status.
