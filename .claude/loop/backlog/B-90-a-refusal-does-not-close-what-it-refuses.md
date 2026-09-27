---
status: open
round: 454
commit: ea802346
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/drain_refusal_ordering.dart
reason: cost — measured on both sides of round 454's change, so it is pre-existing and its own mechanism; the fix has to decide what a refused id's state should be
---

# B-90 — a refusal does not close the stream it refuses

Found by round 454's GUARD arm, which exists to prove the drain refusal still
refuses a NEW stream. It does — twice:

```
GUARD draining, NEW stream   answers=[status=14, status=14]
```

A call opened with metadata AND payload while the endpoint is draining is refused
once per frame. **Two terminal statuses on one stream**, which is the same damage
class round 454 just fixed for the closed-stream case and a protocol violation on
any transport with real stream state.

**Measured on both sides of round 454's reordering** — the canary run shows the
same double answer with the old ordering — so it is pre-existing, untouched, and
not a regression from that round.

## Why it is its own lead

Round 454 fixed an ORDERING. This is a different mechanism: the refusal path does
not record the id it just refused, so the next frame on that id finds no stream,
falls through the same checks, and is refused again.

## The measurable questions

1. **Which refusals?** The drain refusal is confirmed. The ceiling refusal
   (`resourceExhausted`) sits beside it with the same shape and was not driven —
   a two-frame open at the ceiling should answer twice as well. Count the refusal
   sites before fixing any of them (L-12).
2. **Does `_sendGrpcErrorAndCleanup` leave the id anywhere?** If it added to
   `_respClosedStreams`, the closed-stream guard above would swallow the second
   frame, and the fix is one line. The double answer says it does not, but what it
   DOES do was not read.
3. **What does a peer do with the second status?** On a channel transport the
   caller may have released the id already, so the second refusal could land on a
   reused stream — which is RPC-03's territory and would make this worse than
   noise.

## The trap

Do not "fix" it by suppressing the second answer at the send site. The id state is
the thing that is wrong; a filter on the way out would leave the refusal path
still treating a refused stream as unknown, and the next frame type would find the
same hole.

## Owner decision

—
