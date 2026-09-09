---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
scope: [every transport]
---

# C-04 — Peer-chosen stream ids

## Control

Locally issued ids: they are processed, so the refusal is aimed precisely at
foreign ones.
