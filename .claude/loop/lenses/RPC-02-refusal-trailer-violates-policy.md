---
refines: U-09
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: outbound metadata is validated by the same policy as inbound
breaks: "wrong result: the client gets the wrong status, and at worst the connection closes instead of one call being refused."
applied: [216, 243, 320, 327, 349]
status: confirmed (round 349) — the 327 sweep was undone by round 340
---

# RPC-02 — A refusal trailer that violates the policy it enforced

## Shape

A synthetic trailer carrying the diagnosis goes out through `sendMetadata`,
which validates it against THE SAME policy that just refused the peer.

## Detector

Every place a trailer is assembled — `RpcMetadata.forTrailer`, `sendError`,
`_sendOkTrailerIfNeeded` — **in every package, not only in core**.

## Ask

Will the explanation fit under the limit that was just enforced? If the trailer
is emitted INBOUND, will validating it kill the connection?

## Evidence

`maxHeaderValueBytes: 64` turned `RpcStatusException(7, <70 chars>)` into
`status 13 "Responder dispatch failed"` — the length of the explanation decided
the status. A core sweep (5 places) read as complete; two more were in the
transports.

Round 216 swept it and it is clean. 16 assembly sites in `lib/`: 12 pass a
message and all 12 carry `maxMessageLength`, 4 pass none and always fit.
Measured on http2 at a cap of 64 — below every diagnosis these paths write,
above every header rpc_dart sends — the statuses are the same as at 8192, and
removing the cap from ONE trailer turns status 8 into a raw `ArgumentError`.

## Which sites the detector should actually look at

Grepping `forTrailer` is not the whole detector: five more sites build a
`grpc-message` header by hand, and a grep for the constructor name misses every
one of them. But they are all CALLER-side and all emitted locally through
`_emit` into the caller's own controller, never through `sendMetadata`.

**Round 243 re-swept it over ten moved files and it is still clean**: 12 sites
pass a message and all 12 carry `maxMessageLength`, 4 pass none. Both refusal
paths added since 216 — round 237's header-block refusal and round 240's
`_fcRefuseOverrun` — cap their own diagnosis and guard the send, without anyone
having consulted this lens. Note what that re-sweep is: a reading. Round 216's
ablation is what gave "every site passes the cap" its meaning, and 243 did not
repeat it.

**Round 320 re-swept it over 51 moved files — 19 of them behavioural — and the
count is unchanged: 16 sites, 12 with a message and all 12 carrying
`maxMessageLength`, 4 with none.** Not one new trailer site appeared across
rounds 244-319, which is the useful part of the result: the lens's surface is
stable even while the code around it moves, so the risk is a NEW refusal path
rather than an existing one rotting.

Same caveat as 243, stated again because it keeps being the thing that matters:
**this was a reading, not an ablation.** Round 216's cap-to-64 measurement is
what gives "every site passes the cap" its meaning; 243 did not repeat it and
neither did 320. A third consecutive reading is worth less than one re-ablation,
and the next round to touch this lens should ablate rather than re-read.

**Round 327 paid that debt.** `P-08` re-run whole, all four rows identical to
round 216's — including the ablated one, where removing `maxMessageLength` from
`_fcRefuseOverrun`'s trailer turns `status 8` into a raw `ArgumentError` at a cap
of 64 while the other rows do not move. The bench still isolates the trailer from
the request headers, 111 rounds and five doc-and-lint sweeps later, so "every
site passes the cap" still means what 216 measured rather than what three rounds
read.

> **The detector needs two corrections, both found by getting them wrong.**
> First, 4 of the 20 `RpcMetadata.forTrailer` grep hits are not assembly sites —
> one is the declaration, three are COMMENTS that name it. Second, do not look
> for the cap in a fixed window below the call: at
> `frame_multiplexed_channel.dart:261` it sits eleven lines down, behind the
> six-line comment explaining why an INBOUND trailer needs one. An 8-line window
> reports 11 of 12 and names the best-documented site as the broken one.

> **Only a trailer that passes through a validating hop is at risk.** Sort the
> sites by that first — it cut the surface here from 21 to 12 — and check the
> hand-built ones for which side emits them, not just for a cap.

Beware the knob itself: below about 40, `maxHeaderValueBytes` refuses rpc_dart's
own request headers and every call fails with INVALID_ARGUMENT, which reads like
a trailer defect and is not. See `../checked/C-21-header-cap-has-a-floor.md`.
