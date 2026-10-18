---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r800_close_before_the_handshake.dart
round: 800
commit: 0f2fdd93
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: stale (526c8d52)
promoted: packages/transport/rpc_dart_websocket/test/close_before_the_handshake_test.dart
---

# P-291 — close() on a websocket transport whose upgrade the peer never answers

Three arms by argv[0]: `given` (a transport on `WebSocketChannel.connect` to
a peer that accepts TCP and stays silent), `reconnect` (a live transport whose
`reconnectFactory` returns such a channel; `reconnect()`, then `close()`) and
`answered` (the control). Prints the time `close()` took, or STILL PENDING at
the 20 s cap.

Promoted twice: the reconnect arm and the control to the test named in
`promoted:`, the given-channel arm to the matrix cell `websocket | close
after peer silent` in
`packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart`.

## Measures

The time `RpcWebSocketCallerTransport.close()` takes to return, on the
caller's side, against a peer whose only difference from the control is that
it never answers the HTTP upgrade.

## Control

The same transport against a server that answers the upgrade:

```
given      STILL PENDING at the 20 s cap
reconnect  STILL PENDING at the 20 s cap
answered   returned after 7 ms            <- control
```
