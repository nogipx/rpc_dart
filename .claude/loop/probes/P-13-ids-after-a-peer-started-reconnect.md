---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/ids_after_a_peer_started_reconnect.dart
round: 234 — the validating round
commit: c327a2ce
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/core/rpc_dart/lib/src/resilience/**]
status: valid
---

# P-13 — does the id sequence survive a reconnect the PEER started?

A real `HttpServer` + `WebSocketTransformer` behind `RpcWebSocketServer`, one
`RpcWebSocketCallerTransport` with a reconnect factory, and a bidi contract whose
handler ends only when the client half-closes. Two arms differing by ONE event:
who dropped the socket. Run it with `melos exec --scope=rpc_dart_websocket --
fvm dart run .dart_tool/probe/ids_after_a_peer_started_reconnect.dart`.

To point it at another reconnect path, swap `killPeer()` for that path's trigger
and keep both arms: the control is what makes it a bench.

## Measures

Two numbers, both on the library's side. **The stream id** `createStream()`
hands out before and after the reconnect — read off the transport's own id
manager, not inferred. And **how many server handlers have ENDED**, counted in
the responder contract's handler when its request stream completes, which is the
damage: a live call finished because a dead one half-closed it.

## Control

Same rig, same calls, same reconnect — the peer simply does not kill the socket
first, so the wrapper closes the inner transport itself and reads its id cursor
before it goes:

```
  reconnect on a LIVE socket      idA=1 idB=3  disjoint
  reconnect after the peer died   idA=1 idB=1  COLLIDE
  late finishSending(idA)         handlers ended 1 -> 2   (B ENDED)

  after the fix
  reconnect on a LIVE socket      idA=1 idB=3  disjoint    <- unchanged
  reconnect after the peer died   idA=1 idB=3  disjoint
  late finishSending(idA)         handlers ended 1 -> 1   (B alive)
```

The control arm is the path every existing test in
`stream_ids_survive_reconnect_test.dart` and
`client_connection_stream_ids_test.dart` drives, and it was already green — which
is exactly why the defect survived seven rounds. `handlers ended` is a BASELINE
of 1, not 0: losing the first connection ends A's own handler, correctly.

Lens: `../lenses/RPC-03-stream-ids-restart-on-reconnect.md`.
