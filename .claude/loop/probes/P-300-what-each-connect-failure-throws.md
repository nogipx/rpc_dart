---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r814_connect_failures.dart
round: 814
commit: 9e0e3d85
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
status: valid
promoted: packages/transport/rpc_dart_websocket/test/a_failed_connect_is_a_status_test.dart
---

# P-300 — what each connect failure throws

## Measures

One process. For each way an open can fail, `RpcWebSocketCallerTransport.connect`
(`connectTimeout` 1 s), a unary call on `RpcHttpCallerTransport` (1 s deadline)
and `RpcHttp2CallerTransport.connect` against the same server, printing the
error's type, or `RpcStatusException(code)`. Servers: plain `HttpServer`s
answering a fixed status, `rpcWebSocketConnections` with
`allowUpgrade: (_) => false`, a socket that closes on the first byte, a socket
that never answers.

```
  failure                ws (at 9e0e3d85)       http
  refused                SocketException        UNAVAILABLE (14)
  403 from allowUpgrade  WebSocketException     PERMISSION_DENIED (7)
  HTTP 401               WebSocketException     UNAUTHENTICATED (16)
  HTTP 403 / 404 / 503   WebSocketException     7 / 12 / 14
  closed mid-upgrade     HttpException          UNAVAILABLE (14)
  silent (timeout)       TimeoutException       DEADLINE_EXCEEDED (4, the call's own deadline)
  http2, refused         OSError (raw)
```

The "refused" row is noisy on this host: port 1 has a local listener, and a
freed ephemeral port was once taken before the row ran. The row was confirmed
separately (`r814_refused_time.dart`: `Socket.connect` to a freed port, OSError
in 9 ms).

## Control

An honest `RpcWebSocketServer` and `RpcHttpServer`: connect succeeds, the call
returns. The ws column has no status to compare, so the bench's discriminating
signal is the type; a fix shows as codes in that column.
