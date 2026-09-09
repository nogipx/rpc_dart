---
refines: U-18
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/**]
applies: identifiers are issued locally and outlive a reconnect
breaks: data loss on a live call.
applied: [217, 218, 224]
status: confirmed (round 224)
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
Bench `../probes/P-09-watermark-survives-a-decorator.md`.

**Round 224 closed that door**, by the only route the two failed attempts left:
stop the collision rather than detect it. A transport that does not implement
the capability is refused at attach, so the watermark is never silently absent.
The decorated arm went `handlers ended 1 -> 0`, the control unchanged.

> **A capability-guarded fix is only as good as what happens when the answer is
> no**, and "return quietly" is the wrong answer when the capability is
> load-bearing. Three outcomes are available — preserve it (round 209's
> `_preserveCapabilities`), work without it (round 218, measured impossible
> here), or refuse (round 224). Silence is not one of them.

> **A capability-guarded fix has the capability's failure modes.** Round 209
> found this for `IRpcFlowControlled` and round 217 for `IRpcStreamIdSequence`:
> whenever a fix reads `is ISomething`, ask what happens to the fix when the
> answer is no, and whether anything says so out loud.

Round 218 tried to replace the capability with a generation ledger inside the
proxy and measured that it CANNOT work: once the ids collide, the new call is
issued the same integer, so tagging by id cannot tell the dead caller's
`finishSending(1)` from the live one's, and refusing to overwrite the tag drops
the live call's own half-close instead.

> **Prevention and detection are not interchangeable here.** The watermark works
> by stopping the collision; nothing that runs AFTER the collision can undo it,
> because the id is the only thing the caller passes. The only capability-free
> alternative is to stop handing the caller the transport's id at all — a
> translation layer with its own id space, inbound direction included.
