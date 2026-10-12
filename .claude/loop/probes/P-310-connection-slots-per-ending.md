---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r839_connection_slots.dart
round: 839
commit: af781a0c
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_http_server.dart, packages/transport/rpc_dart_http/lib/src/peer_watch.dart]
status: valid
promoted: packages/transport/rpc_dart_websocket/test/a_closed_connection_returns_its_slot_test.dart
---

# P-310 — connection slots per ending

`fvm dart run <file>` from the repo root. Per arm a fresh
`bindRpcWebSocketHttpServer(maxConnections: 2, headerTimeout: 300 ms)` with
`pingInterval: 300 ms`, the arm's way of ending a connection repeated 4
times, then one honest call. It also prints the server's sockets on the port
(`lsof -p` of its own pid). The http sibling is
`packages/transport/rpc_dart_http/.dart_tool/probe/r839_connection_slots.dart`
(`RpcHttpServer(maxConnections: 1)`, plus kernel TCP states via `netstat`).

## Measures

Whether a fresh client is served after N connections have ended, at a cap of
N or less: a slot that outlives its connection reads as REFUSED. Server side.

## Control

The same arms with `maxConnections: null`, and the same arms with the fix
switched off. Without the fix, with no server socket left on the port:

```
arm                            cap 2      no cap
ws call, client closes         REFUSED    served   held=[]
ws upgraded, client silent     REFUSED    served   held=[]
ws upgraded, server closes     served     served
plain GET, server refuses      served     served
connect, client destroys       served     served
header timeout cut             served     served
byte cap cut                   served     served
```

Trap: a dart:io client `Socket` that has written bytes is still ESTABLISHED
in the kernel 500 ms after `destroy()` or `close()` (`r839_client_close.dart`
beside the http probe). An arm that "drops" such a client is really a silent
client, ended by the server. Kill a process to drop a peer for real.
