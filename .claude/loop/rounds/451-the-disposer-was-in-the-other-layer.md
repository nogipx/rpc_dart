---
round: 451
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-25
bench: P-104 — new
commit: yes
---

# Round 451 — the disposer was in the other layer

## Target

B-73, next on the rank after B-77 was sized out of reach in round 450. Its own
body says the defect is unproven either way and names the question that decides
it, so this round is that question and nothing else.

## Hypothesis

The caller half's `_setupDeadlineMonitoring` has no counterpart on the responder
side, and its doc says why one is needed: a bare close is indistinguishable from
the server having finished, so a server-stream call ends *normally* on expiry and
hands the consumer a truncated stream. If the responder has no disposer, that is
what a handler outliving its deadline does to the peer.

## Before

```
arm                     items  outcome                        RESPONDER
                                                              deadline fired
cooperative, 300 ms         3  RpcDeadlineExceededException   true
stubborn,    300 ms         3  RpcDeadlineExceededException   true
CONTROL, no deadline      100  CLEAN END                      false
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/responder_deadline_is_bounded.dart`

The handler yields every 100 ms, so three items is the 300 ms deadline.

## Mechanism

The reasoning written on the caller half IS implemented on the responder half —
one layer up. `_ensureResponderContext` arms a timer from `context.deadline`
(`responder_pipeline.dart:2006`), and `_onDeadlineExceeded` (`:2042`) cancels the
handler's token and then arms a reclaim backstop for a handler that ignores it,
with a warning and a stream cleanup.

That is the better place for it: the pipeline owns the stream state and the
reclaim, which is what makes the backstop possible at all. The caller-side
`CallProcessor` has the disposer and NO backstop, so if anything the asymmetry
runs the other way from the lead's reading.

## After

n/a — no source change. Negative in `checked/C-50`; B-73 closes.

## Canary

n/a for a negative. What carries the evidence instead:

**The isolating observable is a responder-side LOG record.**
`RpcDeadlineExceededException` at the caller is equally consistent with the
responder doing nothing, because the caller has its own deadline timer and one
`grpc-timeout` header arms both. Only `_onDeadlineExceeded` emits *"exceeded its
deadline — cancelling handler"*, so a capturing `LogController` attributes the
teardown to the responder. The no-deadline arm shows the line ABSENT, so the
observable discriminates rather than always firing.

Two probe builds were spent before that: a hand-driven responder, no caller
endpoint at all, read `payloads=0` in the timeout row AND its control — L-15
again, the third time in this block of rounds. The handler never ran. Recorded in
C-50 rather than debugged, because the log observable made the arm unnecessary.

## Gate

No source changed, so the gate is the journal's: `loop.py lint` green.

## Not fixed

**The reclaim backstop is unmeasured.** `reclaimed=false` in every arm, because
the token cancellation did reach the handler — a `yield` on a cancelled scope
terminates the stream, so even the arm written to ignore the token stopped. A
handler that genuinely cannot be unwound is a different bench and nothing here
says the backstop works.

**Only the server-stream shape on the channel transport was driven.** The
enforcement site is shape-independent by construction, which is an argument and
not a measurement.

## Links

- RPC-25 — the sibling that answers the duty can be in another LAYER, not another
  class; B-73 compared two classes in one file and the answer was one level up
- P-104 — is a responder-side deadline bounded, and by what
- C-50 — the responder bounds its deadline, in the pipeline
- B-73 — closed by this round
- L-15 — a void arm reads like a clean one; two builds lost to it here
