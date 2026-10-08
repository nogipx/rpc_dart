---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/r750_retry_through_restart.dart
round: 750
commit: ef95cff2
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart]
status: valid
---

# P-254 — a retry through a server restart

The server stops; a unary call goes out at once through an endpoint with
`RpcRetryInterceptor(maxAttempts: 5)` (its default backoff, full jitter); the
server comes back on the same port after the given outage. Arms: `conn`
(behind `RpcClientConnection`, 50-400 ms backoff, no jitter) and `bare` (the
transport from `connect()`, which the interceptor reconnects itself). Run in
`packages/transport/rpc_dart_websocket` with
`fvm dart run .dart_tool/probe/r750_retry_through_restart.dart <arm> <outage ms>`.
Pass the two arguments separately: a zsh variable holding both is one argument.

## Measures

Whether the call succeeds and when. The retry backoff is random, so an arm
needs several runs; one run says nothing.

## Control

`bare` at the same outage: the interceptor's own reconnect() path, which
passed every run.
