---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/**]
scope: [websocket, core]
---

# C-07 — Outbound backpressure on websocket

`send()` without an await does not matter: the credit window is what bounds it.
A paused consumer over websocket and over a bare core pair slows the producer
within the configured per-stream window — a 256 KiB window → 268 KiB in flight.

This record also retracts the false alarm from round 60 and writes down the
interval trap that caused it.

## Control

A consumer that never pauses: the producer does not stall, so the stop comes
from the window itself.
