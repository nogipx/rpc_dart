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

Trap (corrected in round 842): on this macOS a peer's close reaches the
server about 2.1 s late (P-295), so a reading taken 500 ms after a client's
`destroy()` shows both ends ESTABLISHED. Round 839 took that for dart:io
holding the socket; it was the delay. Settle 2.5 s or more before reading a
close (L-25).
