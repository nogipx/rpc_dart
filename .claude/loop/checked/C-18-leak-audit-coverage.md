---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
scope: [the whole repository]
---

# C-18 — The full leak audit

One defect found, every other measurement clean. Recorded so the whole audit is
not re-run: take individual measurements out of it as needed.

## Control

The defect found in that same audit: the leak is visible on the same counters,
so they are able to show one.
