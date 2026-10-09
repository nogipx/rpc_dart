---
file: packages/core/rpc_dart/.dart_tool/probe/r751_conn_test.dart
round: 751
commit: 4c32a82b
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
status: valid
---

# P-255 — a reconnect wait against the call's deadline and cancel

`RpcRetryInterceptor(maxAttempts: 3)`, 100 ms fixed backoff, every attempt
UNAVAILABLE. The transport is `connection.transport` of an
`RpcClientConnection` whose server went down and whose next attempt is 30 s
away. One arm sets a 1 s deadline, the other cancels at 300 ms. The helper
`r751_deadline_reconnect_test.dart` holds the same arms over a bare transport
whose `reconnect()` takes 3 s. Run in `packages/core/rpc_dart` with
`fvm dart test .dart_tool/probe/r751_conn_test.dart -r expanded`.

## Measures

The outcome type and the elapsed milliseconds of `interceptUnary`, the
library's own call.

## Control

The same arms over `client_connection.dart` from `ef95cff2^`, whose proxy
`reconnect()` answered at once: 206 and 203 ms.
