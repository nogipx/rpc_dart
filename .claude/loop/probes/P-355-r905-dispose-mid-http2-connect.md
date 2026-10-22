---
file: packages/test/rpc_dart_conformance/.dart_tool/probe/r905_dispose_mid_connect/probe.dart
round: 905
commit: b5e7f667
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport_dial.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
promoted: packages/transport/rpc_dart_http2/test/a_cancel_ends_an_http2_connect_test.dart
---

# P-355 — r905 dispose mid http2 connect

## Measures

`RpcClientConnection` over the http2 caller, `dispose()` 200 ms into the
first attempt against a listener that accepts TCP and never writes: time from
dispose to the listener seeing the client close, capped at 15 s. Arms: `h2`
(direct TLS, silent handshake), `proxy` (silent CONNECT), `h2c`. `PASS=1`
hands the factory's token to the connect; without it the probe compiles
against a caller that takes none.

## Control

`h2c`: its factory has already returned when dispose runs, so
`RpcClientConnection` closes the delivered transport itself (8 ms). It shows
the listener sees a client close; `h2` and `proxy` differ only in being still
inside the factory.
