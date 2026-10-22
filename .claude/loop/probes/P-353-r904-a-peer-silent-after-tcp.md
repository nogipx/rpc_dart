---
file: packages/test/rpc_dart_conformance/.dart_tool/probe/r904_tls_silent/probe.dart
round: 904
commit: 66cabcb3
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport_dial.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: valid
promoted: packages/transport/rpc_dart_http2/test/a_silent_tls_peer_ends_the_connect_test.dart
---

# P-353 — r904 a peer silent after tcp

## Measures

A listener that accepts TCP and never writes. Per caller arm, with a 1 s
connectTimeout (or a 1 s deadline for http): when the connect returns (capped
at 8 s), and whether the accepted socket sees the client close (capped at
15 s). `ARMS=h2c,h2,ws,wss,http,https`. The h2 arm is the promoted test; the
wss and https arms are B-314.

## Control

Each TLS arm has a plaintext arm against the same silent listener: h2c for h2,
ws for wss, http for https. The plaintext arms return at ~1 s and their socket
closes at ~1 s, so the listener can see a close; the TLS arms differ only in
the handshake stage.
