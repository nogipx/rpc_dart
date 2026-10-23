---
file: packages/test/rpc_dart_conformance/.dart_tool/probe/r906_reconnect_tls_leak/probe.dart
round: 906
commit: 642329a8
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/core/rpc_dart/lib/src/integration/secure_socket_connect.dart]
status: valid
promoted: packages/transport/rpc_dart_websocket/test/a_silent_tls_peer_releases_the_wss_socket_test.dart
---

# P-356 — r906 wss reconnect against a silent tls peer

## Measures

`RpcClientConnection` over `RpcWebSocketCallerTransport.connect` reconnecting
against a listener that accepts TCP and never writes: connectTimeout 500 ms,
`RpcFixedBackoff` 100 ms, 15 s. This process's own TCP sockets to the
listener's port, by `lsof -p <own pid>` (L-21), every 5 s and 3 s after
`dispose()`. `ARMS=ws,wss`.

## Control

`ws`, the same loop with no TLS stage: about 25 attempts and at most one
socket open at any sample, 0 after dispose. It shows the counter sees the
loop's sockets and that a released one leaves the table.
