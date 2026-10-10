---
status: closed (round 814)
round: 812
commit: 1580403e
release: breaking
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/r812_fd_attack.dart
reason: "FIXED in round 814 as decided (breaking); the http2 sibling is B-289. Previously: risk — S3, a failure type; noticed in round 812, not measured on its own"
rank: 12
---

# B-288 — websocket connect throws a raw HttpException

P-298, incidentally: when the server closes the connection during the
upgrade, `RpcWebSocketCallerTransport.connect` throws dart:io's
`HttpException: Connection closed before full header was received`, not an
`RpcStatusException`. The http caller maps the same failure to UNAVAILABLE
(`_asRpcStatus`). A caller that branches on `RpcStatusException` or a gRPC
status -- the retry interceptor, `RpcClientConnection`'s factory errors --
sees a foreign type from one transport and a status from the other.

Not yet measured: the other ways connect fails (refused, a 403 from the
origin gate, a timeout, a redirect after round 807) and what each throws.

## Owner decision

Owner, 2026-10-10: fix it now, breaking. `connect` throws
`RpcStatusException`: a refused upgrade's HTTP status through
`grpcStatusFromHttpStatus`, every other I/O failure UNAVAILABLE, VM and web.
