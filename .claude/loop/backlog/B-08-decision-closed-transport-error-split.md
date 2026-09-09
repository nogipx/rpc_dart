---
status: closed (round 201)
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_wasm/lib/**]
probe: —
reason: the re-measurement in round 199 found a silent truncation on wasm, fixed by round 201
---

# B-08 — The error-type split on a closed transport

The policy half was settled earlier. Re-measuring in round 199 added a row the
table had never had — wasm — and found a silent stream truncation there; fixed
by round 201 (`../rounds/201-cancel-told-server-first.md`).

The value of this record is how it closed: **a deferral marked "it dissolved"
was re-measured and turned out to be a defect.** Three deferrals were
re-measured in that run, all three recorded wrongly.

## Owner decision

—
