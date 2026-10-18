---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r812_fd_attack.dart
round: 812
commit: 1580403e
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
status: stale (526c8d52)
promoted: — (needs a process with a lowered ulimit; not a unit test)
---

# P-298 — a server past its file descriptor limit

## Measures

Two processes. `r812_fd_server.dart`, compiled (`dart compile exe`) and
started as `sh -c "ulimit -n 128; exec r812_fd_server.exe"` (Bash sandbox
off), serves `Svc.echo` on an `RpcHttpServer` (47200) and on an
`RpcWebSocketServer` over `rpcWebSocketConnections` (47201), defaults, inside
`runZonedGuarded` printing any uncaught error. `r812_fd_attack.dart <http|ws>
<n>` opens n idle TCP connections, makes an honest call, releases them, and
polls an honest call every 500 ms until it succeeds.

```
  arm              honest call while held           served again after release
  http, 0 (ctl)    -                                at once
  ws, 0 (ctl)      -                                at once
  http, 300        14 "Connection closed before..."  2595 ms
  ws, 300          connect: HttpException (same)     2645 ms
  server process   no uncaught error
```

## Control

The same honest call with no idle connections (0) succeeds at once; the
~2.6 s matches macOS's delay in seeing a peer's close (P-295).
