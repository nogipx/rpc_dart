---
round: 663
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-15
bench: none — the witness test is the measurement; it reuses round 537's harness in the same file
commit: yes
release: none
severity: S3
---

# Round 663 — the drain close() could never run

## Target

B-141's remainder, marked `continuation: yes`: round 537 fixed the 408/413/400
drains and left `close()`'s, which the lead names in the same sentence. Scope:
every `_reject` call that can reach a request whose body reader has run -- the
three post-read paths (done in 537) and `close()`. The pre-read rejections still
drain, and must.

## Hypothesis

Every request `close()` answers is already past `read()`, so its drain throws
`StateError` every time.

## Before

```
close() with one complete gRPC request pending (nobody answers it)
  peer saw           HTTP/1.1 503
  drain warnings     1   (Rejection drain skipped: The 'read' method can only be called once)
```

Witness: `close() answers a pending request without draining it again` in
`packages/transport/rpc_dart_http/test/the_rejection_drain_is_not_attempted_twice_test.dart`.

## Mechanism

A request enters `_pending` and reaches its body reader's `read()` in one
synchronous stretch, so nothing -- `close()` included -- can see it pending
before `read()` has run. `close()` called `_reject` with the default
`drainBody: true`.

## After

```
  peer saw           HTTP/1.1 503
  drain warnings     0
```

`close()` passes `drainBody: false`. The 503 still arrives: as round 537
measured for the 408, the body is still attached when the response completes and
dart:io detaches it then.

## Canary

`drainBody` back to the default is the tree before the fix: the witness failed
with `Expected: <0> Actual: <1> -- close() rejected a request whose body had
already been read with a drain, and shelf refused the second read()`, with the
503 assertion above it passing. The file's CONTROL (a pre-read 415 still drains
and answers) green both ways.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart_http +216); `format:check` clean; `license:check` compliant.

## Not fixed

Nothing left on B-141.

## Links

Lead `../backlog/B-141-the-http1-body-timeout-and-reject-drain-are-dead.md` closed.
Bench reused in spirit: `../probes/P-170-does-the-rejection-drain-run-at-all.md`.
Lens `../lenses/RPC-15-remeasure-own-record.md` -- `applied: [..., 663]`.
