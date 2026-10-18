---
file: packages/core/rpc_dart/.dart_tool/probe/r849_clock_jump.dart
round: 849
commit: 362a89a8
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/core/rpc_dart/lib/src/rpc/streams/**]
status: stale (526c8d52)
promoted: packages/core/rpc_dart/test/resilience/a_reconnect_waits_no_longer_than_the_call_test.dart
---

# P-318 — a wall-clock jump during a call

`fvm dart run <file> <unary|server|client|bidi> <jump seconds>` from the
repo root, over `RpcChannelTransport.pair()`: a handler that never answers,
a caller context whose clock (`withClock`) jumps by the given seconds 200 ms
into a call with a 1 s deadline. It prints when (monotonic) and how the call
ended. `r849_retry_clock_jump.dart` beside it does the same to
`RpcRetryInterceptor`'s reconnect wait behind an `RpcClientConnection`.

## Measures

Monotonic milliseconds to the end of a call whose wall clock jumped, and the
exception it ended with.

## Control

Jump 0. At validation:

```
shape    jump      ended after   with
unary    0 s       1025 ms       RpcDeadlineExceededException
unary    -3600 s   1020 ms       the same
server   -3600 s   1009 ms       the same
client   -3600 s   1012 ms       the same
bidi     -3600 s   1012 ms       the same
server   +3600 s   1012 ms       the same
retry wait, 0 s       1003 ms    RpcDeadlineExceededException
retry wait, -3600 s   5112 ms    RpcStatusException (UNAVAILABLE)   <- round 849
```
