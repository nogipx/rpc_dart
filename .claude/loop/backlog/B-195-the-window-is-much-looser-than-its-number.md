---
status: open
round: 497
commit: 60e4d3f8
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: P-135
reason: "owner decision — the bound is real but an order of magnitude looser than the knob; whether that is a defect or the accepted cost of crediting on transport consumption is a decision, and round 208 already decided the neighbouring question"
---

# B-195 — the per-stream window bounds far more than its number says

Split out of B-106's measurement in round 497, where it was the CONTROL rather
than the subject.

`RpcSecurityPolicy.flowControlWindowBytes` is documented with this exact
scenario and this exact promise:

> *"Bounds how many bytes a peer may have unconsumed on one stream before it must
> wait. Without it a producer is throttled only by a consumer that never pauses:
> measured on a server stream, a handler produced 202,600 messages while the
> consumer had processed 483, queueing 527MB in 2s."*

Measured in round 497 on a channel pair, a paused consumer, 1 KiB messages, one
second, codec mode — so the window is exactly what should be holding:

```
window 4096 KiB (the default)   produced 189274   received 1    = 185 MiB
window   64 KiB                 produced   5960   received 1    =  5.8 MiB
```

The window DOES bite — 32x between those rows, which is what proves it is
engaged — and both rows are roughly 45-90x the window itself.

## Why it matters

An operator sets `flowControlWindowBytes: 4 MiB` and retains 185 MiB on one
stream. The number is not a bound on anything the doc names, so sizing a
deployment from it is sizing from a number that is wrong by nearly two orders of
magnitude.

## The likely mechanism, NOT verified

Credit is returned "as the receiving side actually consumes", and the pause is
ABOVE the transport: `caller_pipeline._bridgeCallerResponses` says in as many
words that pausing "collapses buffering back to the transport's per-stream
controller, which holds frames still undecoded". If the transport counts a frame
delivered into that controller as consumed, credit is returned on arrival and the
window only ever bounds what is in flight below it — which is RPC-01's shape
(*"credit is not returned for a frame nobody consumes"*, and round 352's
proxy returning credit on arrival).

## Witness a round would build

Reuse P-135. Add a counter for credit returned, or read the flow controller's own
state through `health()`, and answer one question: at the moment the producer is
190,000 messages ahead, how much credit does the sender believe it has? Then the
same with the consumer draining, as the control.

## Why this is the owner's

Two branches, both real, and a precedent pointing away from the obvious one:

1. **Tighten it** — credit only on application consumption, so the number means
   what the doc says. That makes a paused consumer stop the producer, which is
   the behaviour round 208 deliberately removed for uploads ("refuse the stalled
   call instead of pausing the read") and which round 214 declined again when it
   withdrew B-15. `checked/C-19` records that reasoning.
2. **Correct the doc** — the window bounds the undelivered portion, not the
   application's backlog, and say so with these numbers.

The measurement does not decide between them; the earlier decision suggests (2)
and the doc's own promise suggests (1).

## Owner decision

—
