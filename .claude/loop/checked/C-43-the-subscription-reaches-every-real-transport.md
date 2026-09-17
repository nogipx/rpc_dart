---
round: 377
commit: c6349df9
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**]
scope: [rpc_dart_websocket, rpc_dart_http2, rpc_dart_isolate]
---

# C-43 — a bidi subscription reaches every real transport

Round 373 fixed a bidirectional subscription — a caller that opens the channel,
listens, and sends nothing — in core, and rounds 372-376 measured it only on an
in-process pair. Asked of the three real transports, with real servers on
loopback and a real spawned isolate:

```
transport                  silent      control
websocket (real socket)    3 DONE      3 DONE
http2     (real socket)    3 DONE      3 DONE
isolate   (real isolate)   3 DONE      3 DONE
```

Pinned by one test per package.

## Control

**Every value is a good one, so this rests on the ablation.** Removing round
373's dispatch from core — which all three resolve from local source through the
pub workspace:

```
transport                  silent      control
websocket (real socket)    0 HANG      3 DONE
http2     (real socket)    0 HANG      3 DONE
isolate   (real isolate)   0 HANG      3 DONE
```

Every `silent` collapses and every `control` survives, so the defect was
genuinely present on all three real transports and one core fix carries them
all. The reason it is transport-independent: the open is announced by the
CALLER and dispatched by the shared PIPELINE, so a transport only has to carry a
metadata frame it already carries.

## What it does NOT cover

- **Latency** — all three run on loopback. Adequate for this question, which is
  not flow-control shaped; NOT adequate for the flow-control results of rounds
  370, 371 and 374 (P-58's lesson).
- dart2js/web, `abort()`, a deadline mid-duplex, and the request direction of
  `_pipelineFedRequestStream`.

Re-run when a transport changes how it opens a stream.
