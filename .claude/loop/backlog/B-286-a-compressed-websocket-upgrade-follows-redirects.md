---
status: open
round: 807
commit: b51c7ba7
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart]
probe: packages/transport/rpc_dart_websocket/.dart_tool/probe/r807_upgrade_redirect.dart
reason: cost — dart:io's WebSocket.connect has no setting for redirects; refusing them means doing the compressed handshake ourselves
release: changelog
rank: 10
---

# B-286 — a compressed websocket upgrade follows redirects

P-296: with `enableCompression: true`, `RpcWebSocketCallerTransport.connect`
opens through dart:io's `WebSocket.connect`, which follows a 301, 303 or 307
on the upgrade to another origin and sends every header the caller set,
`x-api-key` included. Round 807 fixed the default path (compression off,
`connectBounded`), where the request is ours.

The way out is the default path's: do the handshake ourselves, which for
this path means negotiating `permessage-deflate` too (`connectBounded`
offers none). Compression is off by default, so only callers who turned
it on are exposed, and only to a server that redirects.

## Owner decision

—
