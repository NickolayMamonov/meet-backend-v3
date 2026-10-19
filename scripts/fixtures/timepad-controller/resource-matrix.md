# Resource evidence matrix

`resource-matrix.py` is called by the isolated controller suite. It executes
the shared driver's exact `RealTransport.observe` method, then the real
provider `_resource_admission` validator. Only external tooling identity and CLI output are
synthetic. The fixture does not create guard state, a lease, a completion receipt,
or a binding. In particular, successful post-create resource admission is **not**
successful initial/replacement create or binding acceptance.

The fixture stages the unchanged create module beside a fixture-only tooling
contract and injects identity/CLI facts through a private `RealTransport` subclass.
The actual tooling and resource comparators remain unchanged. Its CLI boundary
admits only exact read-only list/inspect and frozen Compose inventory vectors.
Every Linux case checks the bounded command inventory, no Docker socket,
no configuration/client-state writes and unchanged observation/contract bytes.
Unknown commands fail closed, including create/start and resource writes. This
is evidence-collection coverage, not a subprocess or daemon integration test.

The 46 executable rows cover prepared, pre-release, post-create, completion and
recovery resource projections; project/Compose disagreement, duplicate/extra/
missing/overbound/truncated identities; wrong token or already-started backend;
postgres policy/restart/start-identity/model drift; network identity, driver,
options, IPAM and flags; missing/foreign/replaced volumes, options and driver;
running/stopped foreign consumers; duplicate resources; and absent/empty/equal/
divergent network and volume hashes. Three pinned fixed-resource hash vectors
are checked independently. Admitted rows retain the complete postgres/resource
baseline. All rows assert input immutability and sanitized output canaries.

For Windows-only verification:

```bash
python -B scripts/fixtures/timepad-controller/resource-matrix.py --portable
```

This mode runs the actual pure validator only. It does **not** execute the
controller observer, Docker adapter, Linux filesystem or supervisor. Output
identifies `mode=portable-validator` per row to avoid treating it as Linux proof.

The controller suite's final `CONTROLLER_MATRIX_BLOCKED` / exit 77 remains
intentional. Still required: actual normal initial and one-replacement
create/receipt/bind/start success; full A1–A5 boundary fault/signal matrix;
PREPARED continuation and provider finalization permutations; runtime deadline/
FD9/drain proof; replay and crash interlocks; full lock/retention/workflow races;
the real 600-second stall; exact-head Ubuntu suite/CI; and separately authorized
real Docker evidence. This resource-only matrix cannot clear those gates.
