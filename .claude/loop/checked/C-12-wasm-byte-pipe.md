---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**]
scope: [wasm, both platforms]
---

# C-12 — wasm: the byte pipe

## Control

Sending deliberately malformed bytes: they are rejected, so the pipe does
distinguish content.
