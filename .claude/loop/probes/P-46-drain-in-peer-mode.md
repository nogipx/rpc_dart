---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/drain_in_peer_mode.dart
round: 354
commit: 3a827426
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-46 — does a graceful drain see a peer-mode call

Starts an `RpcWebSocketServer` twice over the same contract, once with
`onEndpointCreated` and once with `onPeerEndpointCreated`, fires a 2 s call,
waits 300 ms and calls `stop(drainTimeout: 5s)`. Point it at another server by
swapping the three lines that build one.

## Measures

Three, all on the library's side: `activeResponders` read from the endpoint's
own `collectEndpointMetrics()` — the same map `_inFlightCalls()` polls, so the
column says what the DRAIN saw rather than what the probe thinks it should have
— how long `stop()` waited, and what the in-flight call returned.

## Control

One variable: which callback built the endpoint. Same contract, same handler
duration, same budget, same 300 ms head start.

```
arm         activeResponders  stop waited   the in-flight call
responder   1                 1746ms        returned "finished"
peer        null              1ms           status 14              <- before
peer        1                 1726ms        returned "finished"    <- after
```

The responder arm is what makes the peer arm readable: the same server, the same
drain, the same budget, differing only in the endpoint class. `null` rather than
`0` is the give-away — the key was absent, not zero.
