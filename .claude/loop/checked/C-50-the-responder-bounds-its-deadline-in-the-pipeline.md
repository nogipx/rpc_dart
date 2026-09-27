---
round: 451
commit: c60943e2
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/responder_deadline_is_bounded.dart
scope: [rpc_dart]
---

# C-50 — the responder bounds its deadline, in the pipeline

> **Scope**: the channel-transport path, server-stream shape, cooperative and
> uncooperative handlers. Other call shapes were not driven, though the
> enforcement site is shape-independent.

## The claim that was checked

B-73: `_setupDeadlineMonitoring` exists once, on the caller-side `CallProcessor`;
the responder-side `StreamProcessor` has none. The lead is explicit that this is
NOT established as a defect and that `responder_pipeline` may bound the deadline
by another route.

**It does.** The absence in `StreamProcessor` is not a gap.

## Measured

```
arm                     items  outcome                        RESPONDER
                                                              deadline fired
cooperative, 300 ms         3  RpcDeadlineExceededException   true
stubborn,    300 ms         3  RpcDeadlineExceededException   true
CONTROL, no deadline      100  CLEAN END                      false
```

The handler yields every 100 ms, so three items is the 300 ms deadline.

B-73's three questions, in its own order:

1. **Is a responder-side call with a deadline torn down on expiry?** Yes.
2. **By what?** `responder_pipeline._ensureResponderContext` arms a timer from
   `context.deadline` (`:2006-2012`), and `_onDeadlineExceeded` (`:2042`) cancels
   the handler's cancellation token and then arms a RECLAIM backstop for a
   handler that ignores it, with a warning and a stream cleanup. That is more
   than the caller half has.
3. **Does the consumer see an error or a clean end?** An error —
   `RpcDeadlineExceededException`. This was the gate, and it is the answer that
   makes the lead not round-worthy.

## Control

**The isolating observable is a responder-side LOG record**, and it is what makes
this a measurement rather than a guess. `RpcDeadlineExceededException` at the
caller is equally consistent with the responder doing nothing at all, because the
caller has a deadline timer of its own and one header arms both. Only
`_onDeadlineExceeded` emits *"exceeded its deadline — cancelling handler"*, so a
capturing `LogController` on the responder attributes the teardown to the
responder's own timer.

The no-deadline arm is the second control: 100 items, clean end, and the log line
ABSENT — so the observable discriminates rather than always firing.

## A void arm, recorded so it is not rebuilt

Two attempts at a hand-driven responder — no caller endpoint at all, a request
sent straight down the raw client transport with a `grpc-timeout` header — read
`payloads=0` in BOTH the timeout row and its control, which is L-15's shape
exactly: the handler never ran, and a void arm reads like a clean one. Adding
`endStream: true` to the request message did not fix it.

The log observable made the arm unnecessary, so it was abandoned rather than
debugged. If a later round needs a hand-driven responder, the dispatch shape is
the thing to work out first, and `payloads=0` is the tell that it has not been.

## What this does not say

Nothing about whether the RECLAIM backstop works: `reclaimed=false` in every arm,
because the token cancellation did reach the handler — a `yield` on a cancelled
scope terminates the stream, so even the arm written to ignore the token stopped.
Driving a handler that truly cannot be unwound is a different bench.
