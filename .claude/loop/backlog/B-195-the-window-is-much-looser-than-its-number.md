---
status: closed (round 552)
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

**DOCUMENT what the number means** — the window is credit for what is UNCONSUMED, not a
ceiling on residency. Taken in the round-540 review.

So not the tightening: that reaches into rounds 208 and 214, which chose to refuse a stalled
call rather than throttle a producer, and it would cost throughput wherever clients rely on the
slack today.

**What the round owes, and it is more than a comment.** Count the multiplier and write it down
— `185 MiB retained at a 4 MiB window` is the reading, and the doc has to say what the ratio
depends on, not just quote one number. **And a canary that the field bounds anything at all**:
set the window tiny and show retention moves. A documentation round with no canary is the shape
this journal refuses, and here one is available cheaply — round 497's own table has the arm
(shrinking the window 64x moved the codec path 32x).

**Verified still present at review time**: `_window => _policy.flowControlWindowBytes` in
`flow_controller.dart`, unchanged.

No CHANGELOG line for behaviour, but the field's documentation is public API surface and the
wording is worth reading as such: an operator who set 4 MiB to bound memory is the person this
text has to reach.

## Outcome (round 552) — CLOSED, and this lead's premise was the artefact

`../rounds/552-the-window-was-off-not-loose.md`. Bench
`../probes/P-180-what-the-window-actually-charges.md`.

**The window is exact, and the overshoot was this lead's own probe.** It charges WIRE bytes:
`66 messages x 993 B = 65 538` against a 65 536-byte window, and the sweep reads 15 B/msg at
every window size from 16 KiB to 4 MiB. P-135's `_Blob.toJson` emits `{'n': 1024}`, so every
"1 KiB message" was 11 bytes on the wire and `185 MiB` is `count x a size that never crossed
it`. What varies is the CODEC's expansion factor, not the window's slack: 66 messages hold
66 KiB or 1.0 MiB behind one unchanged window, because the field cannot see what a message
decodes to.

**Two arms this lead lacked, each of which alone changes the conclusion.** Time: `4372` at 1 s
and at 2 s is a bound, where `251292 -> 487856` with the field off is a rate — one settle time
cannot tell those apart. And wire size held while decoded size varies, which is the only arm
that separates "loose" from "counting something else".

**And carrying the decision out found the field switched OFF in a legal configuration.** With
`initialSendWindowBytes: null` a server stream was unbounded for its whole life:
`sendCredit: 0`, no credit entry at all. An inbound end-of-stream was treated as the end of the
CALL and dropped the stream's flow-control state — but on a peer-opened stream it is the
peer's half-close, and a server stream half-closes its request immediately. `_advertised` is
the only record such a stream exists, so `_onGrant` then discarded every grant as one for an
ended call. `tryConsume`'s seed hid it completely at the defaults. FIXED; the doc the decision
asked for now describes measured behaviour in every configuration.

What is left is in `B-218-the-other-half-closes-are-unmeasured.md`: the client-stream
and bidi shapes, and what a decoded backlog actually costs — the quantity an operator reading
this field cares about, and the one nothing here measures.
