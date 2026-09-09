---
refines: U-09
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: outbound metadata is validated by the same policy as inbound
breaks: "wrong result: the client gets the wrong status, and at worst the connection closes instead of one call being refused."
applied: []
status: confirmed (round 153, off-journal)
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
