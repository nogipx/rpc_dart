---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r759_grant_after_upgrade.dart
round: 759
commit: 58bd82df
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
status: valid
---

# P-262 — a grant after the bounded upgrade

A real `RpcWebSocketServer`, whose endpoint advertises its connection window
the moment the upgrade completes. The client opens as
`RpcWebSocketCallerTransport._attach` does: `openWebSocket`, then
`RpcChannelTransport.fromChannel` over `RpcWebSocketChannel`. Five connections
per arm; after 300 ms, `flowControlConnectionCredit`, which is `null` when the
peer's grant never arrived (P-195). Run from the repo root:
`fvm dart run packages/transport/rpc_dart_websocket/.dart_tool/probe/r759_grant_after_upgrade.dart <arm>`.

- `bounded`: `maxMessageBytes` set, so `connectBounded` (round 756).
- `plain`: no ceiling, dart:io `WebSocket.connect`.
- `gap`: `bounded` with 200 ms between the open and the transport's listener.
- `nogrant`: the server's policy advertises no connection window.

## Measures

The client's connection credit on each of five connections.

## Control

`nogrant` reads `null` on all five, so the bench sees a grant that did not
arrive; the other arms differ from it only in the server sending one.
