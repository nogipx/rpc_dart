---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**]
scope: [websocket, http2, isolate]
---

# C-01 — Ordinary sustained load retains nothing

The boring case every deployment runs all day. All three transports churn and
retain nothing.

## Control

A run with no load on the same counters: the same growth, so what is being
counted is churn rather than retention.
