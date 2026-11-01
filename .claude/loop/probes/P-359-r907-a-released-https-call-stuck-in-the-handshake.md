---
file: packages/transport/rpc_dart_http/test/a_silent_tls_peer_drops_the_https_socket_test.dart
round: 907
commit: 1e5b1c58
paths:
  - packages/transport/rpc_dart_http/lib/src/owned_http_client_io.dart
  - packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart
status: valid
promoted: packages/transport/rpc_dart_http/test/a_silent_tls_peer_drops_the_https_socket_test.dart
---

# P-359 — r907 a released https call stuck in the TLS handshake

## Measures

A listener that accepts TCP and never writes. One call, released at 1 s while
its connection is still in the handshake; whether the accepted socket sees the
client close, capped at connectTimeout + 4 s. Arms: https with the transport's
own client (connectionFactory through `RpcSecureSocket` + a 5 s
`connectTimeout`), http with the same (control — the bench must be able to see
a close), https through a caller-supplied `IOClient` that has the same
connectTimeout but no factory (canary — the timeout alone must NOT close the
socket).

## Control

The canary arm differs from the witness only in the connectionFactory, so its
staying open attributes the close to the factory. The http arm is the
positive control for the bench itself.
