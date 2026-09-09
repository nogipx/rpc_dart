---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**]
scope: [core, websocket]
---

# C-02 — The frame codec against hostile frames

A battery of nine malformed frames. The codec is clean.

## Control

Valid frames through the same battery: accepted, so the refusal comes from the
content rather than from the codec itself.
