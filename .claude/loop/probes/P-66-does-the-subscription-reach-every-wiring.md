---
file: packages/core/rpc_dart/.dart_tool/probe/bidi_subscription_everywhere.dart
round: 376
commit: 34aeff10
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/peer_endpoint.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**]
status: valid
---

# P-66 — does a bidi subscription reach every wiring?

## Why it exists

Round 373 fixed a bidi subscription — a caller that sends nothing and never
half-closes — and proved it on `RpcChannelTransport.pair()` with a plain
caller/responder pair. That is one wiring. This asks the same question of the
routes that reach the dispatch differently.

## Measures

Per wiring, two arms: `silent` (a request stream that never produces and never
closes) and `control` (the same handler with a stream that closes at once — the
case that worked before 373). Each reports how many payloads arrived and whether
the call ended or hung at a 3 s bound.

Wirings: the **peer endpoint**, which filters inbound messages by stream-id
parity; the **zero-copy branch** of `_ensureBidirectionalResponder`; and **eight
concurrent calls** on one connection.

## Control

Two layers, and the second is what the round rests on.

**Per-arm**: the `control` column. It must stay green while `silent` moves,
otherwise the arm is reporting a broken rig rather than a defect.

**Ablation**: every value here is a good one, so removing round 373's
metadata-frame dispatch is what shows the probe can report otherwise:

```
wiring              silent (fixed)   silent (ablated)   control
peer endpoint          3 DONE            0 HANG         3 DONE
zero-copy              3 DONE            0 HANG         3 DONE
8 concurrent           8 of 8            0 of 8          n/a
```

Every `silent` collapses, every `control` survives. Two facts at once: the probe
sees the defect on all three wirings, and the defect was really present on all
three.

## Trap

The zero-copy arm first reported `ArgumentError` in **both** columns.
Measurement.md item 4: when the control shows the same symptom as the case under
test, the bench is wrong, not the library. `RpcChannelTransport.pair()` does not
support direct objects and `RpcInMemoryTransport.pair()` does. One rebuild.

## What it establishes, and what it does not

Establishes: 373's fix is load-bearing on three wirings its own round never ran.

Does not touch real transports — http2, websocket and isolate each build their
own metadata frame, and none of them is exercised here. That is the largest
remaining gap in the bidi work and needs a transport-level bench.
