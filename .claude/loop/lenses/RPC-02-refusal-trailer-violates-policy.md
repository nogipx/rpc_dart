---
refines: U-09
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: outbound metadata is validated by the same policy as inbound
breaks: "wrong result: the client gets the wrong status, and at worst the connection closes instead of one call being refused."
applied: [216]
status: swept here (round 216, 10ba2a93)
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

> **Only a trailer that passes through a validating hop is at risk.** Sort the
> sites by that first — it cut the surface here from 21 to 12 — and check the
> hand-built ones for which side emits them, not just for a cap.

Beware the knob itself: below about 40, `maxHeaderValueBytes` refuses rpc_dart's
own request headers and every call fails with INVALID_ARGUMENT, which reads like
a trailer defect and is not. See `../checked/C-21-header-cap-has-a-floor.md`.
