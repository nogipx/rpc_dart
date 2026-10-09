---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r754_online_before_settings.dart
round: 754
commit: 2daf1310
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-259 — a peer that never sends SETTINGS

An `RpcClientConnection` over `RpcHttp2CallerTransport.connect(...,
connectTimeout: 2 s)`, `maxAttempts: 4`, 100 ms backoff, no jitter. Run from
the repo root:
`fvm dart run packages/transport/rpc_dart_http2/.dart_tool/probe/r754_online_before_settings.dart <arm>`.

- `refuse`: nothing listens. On loopback this can self-connect once (RPC-21).
- `acceptclose`: a socket server that accepts and destroys at once.
- `silent`: a socket server that accepts and never writes.

A second file, `r754_close_early.dart`, run under `time`: a transport closed
before the peer's SETTINGS, and how long the process takes to exit.

## Measures

Every state with its time, Online events, factory calls, the outcome and
latency of one call made at the first Online (8 s Dart-side cap), the
transport's health right after, uncaught errors.

## Control

`acceptclose` and `silent` differ only in whether the peer closes. Before
the fix `acceptclose` reads 14 in 32 ms and `silent` still waits at 8 s, so
the bench separates a peer that ends the socket from one that holds it.
