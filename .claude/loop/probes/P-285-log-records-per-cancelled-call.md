---
file: packages/core/rpc_dart/.dart_tool/probe/warnings_per_cancel.dart
round: 791
commit: 1273c1b9
paths: [packages/core/rpc_dart/lib/src/rpc/streams/client/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/**]
status: valid
---

# P-285 — log records per cancelled call

## Measures

A responder over `RpcChannelTransport.fromChannel` with its own
`LogController` (min level warning). Per shape (`u`, `s`, `c`, `b`), 100
calls on one connection; each handler ignores its token and keeps producing
(30 ms for unary and client-stream, 20 items 2 ms apart for the streams).
The peer sends the request, waits for the first frame back plus 5 ms, then
`x-client-cancelled` (arm `cancel`), or half-closes and lets it finish (arm
`control`). Counts records at warning or above, digits masked.

Round 791, before:

```
  shape   cancel                                                    control
  u       0                                                         0
  s       0                                                         0
  c       100  "Attempted to send response on inactive processor"   0
  b       0                                                         0
```

After: 0 in every cell.

## Control

Arm `control`: the same calls on the same connection and logger, never
cancelled; 0 records on every shape. And unary, server-stream and bidi under
the same cancel: 0.
