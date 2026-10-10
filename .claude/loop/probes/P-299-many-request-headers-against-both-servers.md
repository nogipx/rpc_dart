---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r813_many_headers.dart
round: 813
commit: 87b88587
paths: [packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
status: valid
promoted: — (a CLEAN measurement; the websocket byte bound is B-287)
---

# P-299 — many request headers against both servers

## Measures

One process, `r813_many_headers.dart <n>`: an `RpcHttpServer` and an
`RpcWebSocketServer` over `rpcWebSocketConnections`, defaults, inside
`runZonedGuarded`. A raw socket sends one request carrying `n` extra
`x-hN: v` headers to each (a websocket upgrade, an http POST) and prints the
first response line, the bytes sent and the time to the answer; then an honest
call goes to each server.

```
  n        wire bytes   websocket                http                 honest after
  0 (ctl)  140 / 87     101, 31 ms               200, 24 ms           ok / ok
  10000    119 030      101, 52 ms               400, 42 ms           ok / ok
  80000    1 029 030    101, 111 ms              closed, 22 ms        ok / ok
  100000   1 289 030    101, 123 ms              closed, 24 ms        ok / ok
  150000   1 989 030    closed, 116 ms           closed, 19 ms        ok / ok
  uncaught errors in the server zone: none at any n
```

## Control

n = 0: the same request with no extra headers is answered 101 / 200 at once.
The websocket side's ceiling is dart:io's `_headerTotalSizeLimit` (1 MiB,
counted over name and value bytes only, so about 1.4 MB on the wire); the
http side's is the policy's header count (400) and then round 811's byte cap.
