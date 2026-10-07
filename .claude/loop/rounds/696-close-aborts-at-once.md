---
round: 696
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-14
bench: none — a new test timing close() with a call in flight, `packages/transport/rpc_dart_http2/test/close_does_not_wait_on_active_calls_test.dart`
commit: yes
release: changelog
---

# Round 696 — close aborts at once

## Target

B-187, decided by the owner: the http2 caller's `close()` slept 50 ms whenever
a stream was active, before aborting every stream. Remove the wait.

## Hypothesis

The sleep is the whole of the difference: with a call in flight, `close()`
takes about 50 ms more than its own work.

## Before

A unary call into a 5 s handler, `transport.close()` timed 200 ms in, three
runs:

```
close() took 69ms
close() took 68ms
close() took 67ms
```

## Mechanism

As hypothesised: `await Future<void>.delayed(Duration(milliseconds: 50))`
under "a short grace period for streams still finishing".

## Fix

The wait is gone; `close()` aborts every remaining stream at once. A caller
that wants its calls to finish awaits them before closing.

## After

```
close() took 13ms   (x3)
```

The aborted call fails with an `RpcException`, asserted.

## Canary

Before is the canary: the same test on the tree with the wait.

## The verdict questions

1. Yes: Before on the same tree.
2. Yes: the cost the lead named.
3. Yes: `close()`'s duration and the aborted call's outcome.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Yes; the owner chose removal over keeping the grace.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`, the `rpc_dart_http2` suite (296).

## Not fixed

The test's 50 ms bound is the only line between the two behaviours; under a
heavily loaded gate the 13 ms could approach it.

## Links

Lead `../backlog/B-187-http2-close-sleeps-fifty-ms.md` closed.
Lens `../lenses/RPC-14-timeout-abandons-work.md` -- `applied: [..., 696]`.
