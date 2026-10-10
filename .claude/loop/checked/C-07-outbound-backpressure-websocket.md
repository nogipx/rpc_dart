---
round: 827
commit: c653b91e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/**]
scope: [websocket, core]
---

# C-07 — Outbound backpressure on websocket

`send()` without an await does not matter: the credit window is what bounds it.
A paused consumer over websocket and over a bare core pair slows the producer
within the configured per-stream window — a 256 KiB window → 268 KiB in flight.

This record also retracts the false alarm from round 60 and writes down the
interval trap that caused it.

**Round 827 re-measured it** on default policies (4 MiB stream window, 64 MiB
connection window), with a second stream on the same connection (network-audit
KV-WS-07): the paused stream's producer stopped at 66 messages of 64 KiB
(4 MiB, the window) while the other stream received 2770 in 2 s. Probe
`packages/transport/rpc_dart_websocket/.dart_tool/probe/r827_paused_stream.dart`.

## Control

A consumer that never pauses: the producer does not stall, so the stop comes
from the window itself (round 827: 1474 messages, 92 MiB, in 2 s).
