---
status: closed (round 612)
round: 612
commit: 73590cfb
paths: [packages/core/rpc_dart/lib/src/core/drain.dart]
probe: P-152
reason: "CLEAN in round 612, closed as an accepted cost by the owner: at most 27 ms past the last call, once per shutdown, only with work in flight. Previously: cost — the responder drain is signalled now; `drainUntilIdle` still polls at 25 ms, so `two copies of one mechanism` is still two. Unifying them changes its signature and every caller"
---

# B-208 — the generic drain still polls, so there are still two of them

Split out of B-123, which round 514 closed after replacing the responder drain's 50 ms poll
with a signalled completer. Bench `../probes/P-152-how-long-does-a-drain-take.md`.

**`drainUntilIdle` still polls at 25 ms.** Its budget is a `Stopwatch` now rather than a
wall-clock deadline, but it is generic over a `pending()` callback and has nothing to be
signalled BY. Unifying the two means giving it something to wait on, which changes its
signature and every caller — worth doing, and its own change.

**One claim in B-123 was fixed without being measured.** Nothing stepped a clock: both
deadlines are monotonic on the argument `RpcCircuitBreakerInterceptor` already documents for
its own `Stopwatch`. That is reasoning, and the record said so. A round here could settle it
with an injectable clock, or record that none is available and leave the reasoning labelled.

**`activeResponderCount`'s O(n) `where` per tick** is untouched. The site that called it per
tick is gone with the responder drain's poll, so whatever else polls it is what remains to
check — and nobody has counted the callers.

## Why it matters

Two implementations of one mechanism, which is what B-123 was about; half of it is still
there.

## Witness a round would build

P-152's shape against `drainUntilIdle`'s own callers: latency of a drain that completes well
inside one tick, against the signalled responder drain as the control. The guard is the arm
where the work outruns the interval — a wait that ends too soon is worse than a slow one.

## Owner decision

2026-10-02: close as an accepted cost; no signal parameter.
