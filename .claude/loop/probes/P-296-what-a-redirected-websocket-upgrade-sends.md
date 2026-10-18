---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r807_upgrade_redirect.dart
round: 807
commit: b51c7ba7
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_bounded_upgrade.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
status: stale (526c8d52)
promoted: packages/transport/rpc_dart_websocket/test/a_redirected_upgrade_is_not_followed_test.dart
---

# P-296 — what a redirected websocket upgrade sends

## Measures

`RpcWebSocketCallerTransport.connect` with `headers: {'x-api-key': ...}` to
a server that answers the upgrade with 301 / 303 / 307 and a Location on
another origin; that origin records what arrives. Arms: the default client
handshake (`connectBounded`, compression off) and `enableCompression: true`
(dart:io `WebSocket.connect`).

```
  before round 807          bounded                  compressed
  301 / 303 / 307           GET x-api-key=secret     GET x-api-key=secret
  after round 807
  301 / 303 / 307           nothing                  GET x-api-key=secret
```

## Control

The same arms with the redirect's target never reached: the redirecting
server answers, the caller fails with "not upgraded"; only the request at
the other origin differs.
