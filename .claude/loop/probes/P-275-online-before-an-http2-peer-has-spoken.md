---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r780_online_before_settings.dart
round: 780
commit: 40b51ef5
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-275 — online before an http2 peer has spoken

## Measures

`RpcClientConnection` (`maxAttempts: 1`) with a factory building an http2
caller transport, against a TCP server that accepts and never sends a
byte. Arms (argv[0]): `connect` (`RpcHttp2CallerTransport.connect`) and
`viasocket` (`viaSocket` over `Socket.connect`). Printed after 5 s: every
state with its time, and the transport's `health()` level.

## Control

Round 779's websocket arm (P-258) is the same question with a handshake
that already gates Online; an HTTP/2 server would send SETTINGS at once.
