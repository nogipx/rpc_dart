---
status: open
round: 746
commit: f8dd6a88
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/r746_drop.dart
reason: unmeasured — seen once, in the control arm of round 746
---

# B-268 — a transport built on an unconnected channel reports online, then crashes

Round 746's `nofactory` arm built the transport with the constructor over
`IOWebSocketChannel.connect(uri)`, which returns before the handshake. With
the server down:

```
  state -> RpcClientOnline
  t=514 ms isClosed=false health=healthy conn=RpcClientOnline
  ...
  Unhandled exception:
  WebSocketChannelException: OS Error: Network is down, errno = 50
```

Two things to measure: `health()` and `RpcClientConnection` call such a
transport healthy before the channel is ready, and the channel's connect error
reached the root zone, which ends the isolate. The README documents the
constructor for a channel the user builds, so this is a supported path.

## Owner decision

—
