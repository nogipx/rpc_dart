---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/bidi_subscription_over_socket.dart
round: 377
commit: c6349df9
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-67 — the subscription on real transports

## Why it exists

Rounds 372-376 measured bidi on `RpcChannelTransport.pair()` alone. Round 373's
fix lives in core, but each real transport builds its own metadata frame and
performs its own open, so whether the announcement reaches a peer over a wire is
a separate question from whether core makes it.

## The three files

One per package, the same shape in each:

- `rpc_dart_websocket/.dart_tool/probe/bidi_subscription_over_socket.dart`
- `rpc_dart_http2/.dart_tool/probe/bidi_subscription_over_http2.dart`
- `rpc_dart_isolate/.dart_tool/probe/bidi_subscription_over_isolate.dart`

Real servers on loopback, or a real spawned isolate. No fakes.

## Measures

Two arms per transport: `silent` — a caller that sends nothing and never
half-closes — and `control` — the same handler with a request stream that closes
at once. Each reports how many payloads arrived and whether the call ended or
hung at a 4 s bound.

## Control

Two layers.

**Per-arm**: the `control` column, which must stay green while `silent` moves,
or the arm is reporting a broken rig.

**Ablation**: every value is a good one, so removing round 373's metadata-frame
dispatch from CORE — which all three packages resolve from local source through
the pub workspace — is what shows the probes can report otherwise:

```
transport                  silent (fixed)   silent (ablated)   control
websocket (real socket)       3 DONE            0 HANG         3 DONE
http2     (real socket)       3 DONE            0 HANG         3 DONE
isolate   (real isolate)      3 DONE            0 HANG         3 DONE
```

Every `silent` collapses and every `control` survives on all three. That says
the defect was genuinely present on real transports and that one core fix
carries all of them.

## What it establishes, and what it does not

Establishes: a bidi subscription reaches the server over websocket, HTTP/2 and
an isolate, and it did not before round 373.

Does not establish anything about LATENCY — all three run on loopback. That is
adequate for this question, which is not flow-control shaped, and it is NOT
adequate for the flow-control results in rounds 370, 371 and 374 (P-58's
lesson). Nor does it cover dart2js.
