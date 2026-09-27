---
status: open
round: 450
commit: db96aa72
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: —
reason: cost — three homes for one rule, no divergence shown to bite; the ASK has to be answered before any unification
---

# B-89 — the stream-id parity rule has three homes, not one

Split out of B-87 in round 450, which verified the `ff930001` sweep's nine
claimed negatives and found this one false as written. See `checked/C-49`.

The sweep said *"parity alignment in `RpcStreamIdManager`"* was already shared.
It is — round 360 gave the manager one home for it, and `_alignedStart`'s comment
records why: *"One home for the alignment, or the two routes into the same
concept drift — and they had."*

**http2 does not use `RpcStreamIdManager`.** It keeps its own counters:

```
core, RpcStreamIdManager._alignedStart
      resumeAfter.isOdd == isClient ? resumeAfter : resumeAfter + 1
      parameterised by side, used by the channel transports

http2 caller, resumeStreamIdsAfter (:50-55)
      streamId.isOdd ? streamId : streamId + 1
      client-odd hard-coded; `_nextStreamId = 1`, `+= 2`

http2 responder
      `_nextStreamId = 2`
```

## Why this is filed rather than fixed

Nothing has been shown to bite. The http2 caller's hard-coding is CORRECT for a
class whose `isClient` is a literal `true`, so the two rules agree on every input
that class can receive. This is the shape RPC-25 declines to unify on looks
alone.

What makes it worth a number anyway is the sweep: a reader who takes "already
shared" at its word believes there is one home and will not compare. That is
exactly the false-negative cost B-87 was filed for.

## The measurable questions

1. **Can the http2 responder's counter be handed a watermark at all?** The caller
   has `resumeStreamIdsAfter`; if the responder has no such entry point, its `2`
   is unreachable state and there is nothing to align.
2. **Does `RpcClientConnection` ever hand an http2 caller a watermark of the
   wrong parity?** Its `_idWatermark` comes from `lastIssuedStreamId`, which on
   http2 is `_nextStreamId - 2` — odd, so probably never. Establish it rather
   than assuming: that is the one path where the two rules meet.

If both come back clean this closes as a negative, which is a real result and the
honest end for a lead of this strength.

## The `## Ask`, to be answered before any unification

If the three were one, whose behaviour would the shared version have, and which
of the three would that CHANGE? http2 not using `RpcStreamIdManager` may be
deliberate — the manager also computes a max-assignable bound and tracks release,
and http2 delegates real id assignment to `package:http2`'s `makeRequest`. Read
that before proposing the manager as the single home.

## Owner decision

—
