---
round: 871
commit: a0d0f3f0
paths: [packages/core/rpc_dart/lib/src/rpc/streams/**, packages/core/rpc_dart/lib/src/endpoint/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**]
scope: lifecycle_model_test.dart with seeds 13-200 (188 sequences of 40 operations) on channel, http, http2, websocket and isolate; wasm unsupported in the workspace
---

# C-96 — the lifecycle model is clean on 188 more seeds

The lifecycle model, whose gate runs seeds 1-12, run on seeds 13-60 and
61-200 after rounds 853-870: 940 cells, every one green (`+245 ~49` and
`+705 ~141`, the skips being the wasm member). Every call ended once and
within its trigger, nothing escaped to the zone, every handler was
disposed, the gauges returned, and every untouched call ended as its
handler and deadline say.

## Control

Round 870: the same model, with that round's fix switched off, fails its
pinned cell on http2 (status 9 for ABORTED).
