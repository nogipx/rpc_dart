---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**]
scope: [websocket]
---

# C-08 — Cancellation reaches the handler on websocket

Probe: `.dart_tool/probe/cancel_reaches_handler.dart`

An infinite server stream counting its own yields: the client took 3 items and
cancelled, the handler's `finally` ran, the counter stopped within a tick and
stayed flat for 2 s. The `x-client-cancelled` notification does its job.

## Control

A call with no cancellation: the handler's counter keeps rising, so the stop
comes from the cancellation.
