---
file: packages/core/rpc_dart/.dart_tool/probe/r738_dropped_requests_hold_the_pool.dart
round: 738
commit: a94aca2c
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-244 — do requests a handler stopped reading starve the connection pool?

Channel pair, 64 KiB stream window, 128 KiB connection pool. The probe opens
N bidi calls whose handler stops reading, then makes one unary call. Run with
`melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/r738_dropped_requests_hold_the_pool.dart <N> [parked]`.

## Measures

KiB the client could send per call, and whether a unary on the same
connection completes.

## Control

`parked`: the handler pauses its subscription instead of dropping it, which
holds the credit:

```
  2 calls, dropped (case)     100000, 100000 KiB   unary pong in 12 ms
  2 calls, parked (control)       65, 64 KiB       unary HUNG
```
