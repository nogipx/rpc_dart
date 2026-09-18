---
round: 384
commit: 69d24a76
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
scope: [rpc_dart_websocket, rpc_dart]
---

# C-44 — bidi over a real websocket, on a direct link and over a round trip

C-41 and P-64 settled bidi's endings and its duplex semantics on
`RpcChannelTransport.pair()`, which flattens anything the size of a round trip
(P-58). Asked again over a real socket, and over the same socket through a
25 ms-each-way relay.

## Endings — P-74

Seven endings, three scales, one connection per arm, nine counters on both
sides, plus a unary call after every scale because an ending that WEDGES a
connection leaves every counter at zero:

```
arm                direct link            +50 ms round trip
unary (control)    0 everywhere, usable   0 everywhere, usable
normal             0 everywhere, usable   0 everywhere, usable
consumerCancel     0 everywhere, usable   0 everywhere, usable
tokenCancel        0 everywhere, usable   0 everywhere, usable
handlerThrows      0 everywhere, usable   0 everywhere, usable
deadline           5 / 14 / 14 held       5 / 7 / 7 held
neverFinish        0 everywhere, usable   0 everywhere, usable
```

**The deadline row is bounded retention by design, not a defect and not a
real-transport effect** — P-63 reads the same way on the pair today, and the
timeline shows it clearing at ~2.2 s, which is `_reclaimGrace`, the documented
backstop for a handler that ignores its cancellation token. A cooperative
handler clears at once. It also falsifies C-41's own `deadline: 0` — see the
note there.

## Duplex — P-74 and P-75

```
full duplex, 30 each way          30/30, ORDER PRESERVED, both links
8 concurrent calls, tagged        8 of 8 clean, no cross-talk, both links
both directions past the window   independent; a paused response direction
                                  throttles the mirror handler and recovers
                                  in full on resume (11/6/6/0 -> 400/400/400/400)
```

The two single-direction arms are what make that last row mean something:
`requestOnly` (400 produced, handler took 400, nothing answered) and
`responseOnly` (400 pushed, 400 received, nothing sent) each run flat out, so
the stall in the mirror arm is the application's coupling and not the library's.

## Control

Three, because most cells here are zero and a zero is suspicious.

**The unary arm**, through the same endpoints on the same connection in the same
run: a counter that climbs for bidi and not for unary belongs to the shape.

**The `deadline` row is the sensitivity proof.** It is the one arm that reads
NON-zero on these counters at these scales, so the instrument is demonstrably
able to report retention rather than only zero — the thing P-63 needed a whole
ablation for.

**The two single-direction arms** (P-75) are what make the duplex reading mean
something: `requestOnly` runs 400 through with nothing coming back and
`responseOnly` runs 400 back with nothing going out, so the stall in the mirror
arm is the handler's coupling and not the library's. The resume is a fourth
check on the same arm: back-pressure recovers, a deadlock would not.

## What this does NOT cover

Links slower than 50 ms, packet loss, coalescing, a connection that DROPS
mid-call, dart2js, `RpcWasm`, RSS, and anything no counter names. Flow control's
own three counters per side are absent because the shipped websocket wrappers do
not forward `flowControlStateSizes` — those live on the core copy (P-63).

Isolate and HTTP/2 got only the request-sink question this round (round 384's
witnesses), not this matrix.

Re-run when a bidi ending changes, or when the websocket transport changes how
it opens or tears down a stream.
