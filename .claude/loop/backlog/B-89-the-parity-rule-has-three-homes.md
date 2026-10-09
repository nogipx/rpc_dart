---
status: closed (round 468)
round: 450
commit: db96aa72
paths: [packages/core/rpc_dart/lib/src/core/transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: —
reason: cost — three homes for one rule, no divergence shown to bite; the ASK has to be answered before any unification
---

# B-89 — the stream-id parity rule has three homes, not one

## CLOSED (round 468) — there are TWO homes, and they never meet

Both questions came back clean, so this closes as the negative the lead itself
named as the honest end. `checked/C-54`.

**Q1 — no.** `RpcHttp2ResponderTransport implements IRpcTransport,
IRpcSecurityPolicyAware, IRpcFlowControlled` — **not `IRpcStreamIdSequence`**. No
`resumeStreamIdsAfter`, no `lastIssuedStreamId`. There is no door, so `2` is an
initialiser with no rule attached rather than a third implementation.

**Q2 — not from inside this library.** Driven at its own boundary the caller's
rule is correct at every parity and never rewinds (`2 -> 5, 7`; `100 -> 103,
105`), and through `RpcClientConnection` across three swaps the ids are
`[1, 3, 5, … 19]`, no evens, strictly increasing.

Control — the alignment deleted — reports `PARITY BROKEN` on three rows, so the
bench can see it. **And the proxy arm stayed clean under that same ablation**:
the alignment is never exercised on that path, because `lastIssuedStreamId` is
`_nextStreamId - 2` and odd by construction. It is reachable only from the
PUBLIC transport surface.

**The `## Ask`, answered: not the manager.** `RpcStreamIdManager` also computes a
max-assignable bound and tracks release, and http2 delegates real id assignment
to `package:http2` — its `_nextStreamId` is rpc_dart's own handle. Adopting it
would put a bound and a release ledger on a transport needing neither, for a rule
four tokens long with no reachable disagreement.

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
