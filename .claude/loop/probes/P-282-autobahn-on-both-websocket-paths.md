---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/autobahn_echo_server.dart
round: 788
commit: 6bf688cd
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
status: valid
---

# P-282 — autobahn on both websocket paths

## Measures

Autobahn TestSuite (`crossbario/autobahn-testsuite`, wstest 25.10.1), 247
cases: everything except 9.* (performance), 12.* and 13.* (permessage-deflate,
off by default). Four agents, each an echo at the channel level:

- server, `autobahn_echo_server.dart`: `rpcWebSocketConnections` with its
  defaults, so the bounded upgrade and its frame guard sit in front of dart:io;
  `wstest -m fuzzingclient`.
- server control, `autobahn_echo_control.dart`: bare `WebSocketTransformer`,
  compression off.
- client, `autobahn_client.dart <url> <agent> 16777216`: `openWebSocket` with
  `maxMessageBytes`, so `connectBounded`; `wstest -m fuzzingserver`.
- client control: the same file with no third argument, plain
  `WebSocket.connect`.

```
  agent               OK    NON-STRICT  FAILED  close not OK
  server (rpc_dart)   233   4           7       2
  server (bare io)    233   4           7       2
  client (rpc_dart)   226   11          7       3
  client (bare io)    224   13          7       2
```

FAILED is the same seven cases in all four: 3.4, 5.6, 5.7, 5.8, 5.19, 5.20,
7.1.5 (dart:io: a pong held behind an unfinished fragmented message; RSV
in octet-wise chops; a close between fragments answered 1007). The rpc_dart
client is stricter than bare io on 4.1.5 and 4.2.5 (OK against NON-STRICT)
and differs on one: 2.5, a 126-byte ping, fails the connection without a
1002 Close frame (`closeFailed`, "failed by the wrong endpoint").

## Control

The bare-io agents: the same suite, the same echo, with rpc_dart's accept
and connect paths removed. The two server columns are identical case by
case.
