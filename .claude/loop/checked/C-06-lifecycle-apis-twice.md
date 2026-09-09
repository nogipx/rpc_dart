---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**, packages/core/rpc_dart/lib/**]
scope: [transports, the http2 server]
---

# C-06 — Sweep of the lifecycle APIs

The sweep is clean. This is shape U-15, which has no lens of its own in the set
yet — the round that takes lifecycles up again should create one and move this
status onto it.

## Control

A single call to each method: the state returns to where it started, so a defect
would have to come from the second call.
