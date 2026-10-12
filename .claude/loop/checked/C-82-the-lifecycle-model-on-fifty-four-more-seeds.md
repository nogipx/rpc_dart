---
round: 843
commit: ae112b3b
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**]
scope: lifecycle_model_test.dart, seeds 13-48 at 40 operations and seeds 13-30 at 120, on channel, http, http2, websocket and isolate; not wasm
---

# C-82 — the lifecycle model on fifty-four more seeds

The conformance lifecycle model found nothing on 54 seeds it never runs in
the gate (36 at 40 operations, 18 at 120), on five members: 274 cells green.
Its invariants are checked after every step: one ending per call within its
trigger plus 1 s, nothing reaching the zone, every handler, timer and gauge
released.

To run more seeds, edit `_seeds` and `_length` in place and restore them; a
seed is the whole sequence, so a new seed is a new sequence.

## Control

The pinned http2 cell (`--run-skipped`) still fails: "[ending] expected the
handler's ABORTED, got status 9" (B-283).
