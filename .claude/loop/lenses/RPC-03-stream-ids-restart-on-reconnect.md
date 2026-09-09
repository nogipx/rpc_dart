---
refines: U-18
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/**]
applies: identifiers are issued locally and outlive a reconnect
breaks: data loss on a live call.
applied: [217]
status: confirmed (round 217) — one door still open, see B-17
---

# RPC-03 — Stream ids that outlive a reconnect

## Shape

The id manager starts numbering from scratch while operations issued before the
break are still alive.

## Detector

`RpcStreamIdManager`, `resumeAfter`, `lastIssuedId`,
`RpcChannelTransport.resumeStreamIdsAfter`, `lastIssuedStreamId` — and then the
question those names do not ask: **at every swap site, can the capability be
ABSENT?** Both hops in `RpcClientConnection` guard with `is` and return
silently.

## Ask

Can tearing down a dead operation close a live one that holds the same id?

## Evidence

A dead call's teardown half-closed a LIVE one; both obvious fixes failed.

Round 217 swept the swap sites. Core's `RpcClientConnection`, the websocket
caller's own `reconnect()`, and the http2 and http callers all carry the
watermark; isolate and wasm have no in-place reconnect at all, so the shape
cannot arise there. What is NOT covered is the capability going missing:

    factory returns          id before   id after   handlers ended
    the transport itself         1           3          0 -> 0
    a plain decorator            1           1          0 -> 1

The last column is a live bidi call half-closed by a dead call's teardown.
Awaiting an owner decision as `../backlog/B-17-watermark-lost-through-a-decorator.md`;
bench `../probes/P-09-watermark-survives-a-decorator.md`.

> **A capability-guarded fix has the capability's failure modes.** Round 209
> found this for `IRpcFlowControlled` and round 217 for `IRpcStreamIdSequence`:
> whenever a fix reads `is ISomething`, ask what happens to the fix when the
> answer is no, and whether anything says so out loud.
