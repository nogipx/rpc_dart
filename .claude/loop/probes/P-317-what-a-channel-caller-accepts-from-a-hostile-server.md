---
file: packages/core/rpc_dart/.dart_tool/probe/r848_channel_response_oracle.dart
round: 848
commit: bdb31b14
paths: [packages/core/rpc_dart/lib/src/contracts/caller_trailer.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport_inbound.dart]
status: valid
promoted: packages/core/rpc_dart/test/contracts/an_out_of_range_status_is_unknown_test.dart
---

# P-317 — what a channel caller accepts from a hostile server

`fvm dart run <file>` from the repo root. A caller `RpcChannelTransport`
over a fake channel; for each of fourteen scenarios the "server" sends a
fixed frame sequence on the call's stream (no message, two messages, status
99, x, -1, " 0", no status, two trailers, trailers-only OK, data after the
trailer, end on DATA, a message before the headers, OK with a message), and
the probe prints what a unary and a server-stream consumer end with.

## Measures

The outcome each consumer reaches: OK with what it got, or the error and its
status code.

## Control

`valid: one message, OK` on both shapes: `OK value=a`, `OK items=[a]`.
Before round 848, the rows that differed from the gRPC rule:

```
status 99   unary  ERROR 99 RpcStatusException(99): Unknown error
            stream ERROR 99 (the same)
status -1   unary  ERROR -1 RpcStatusException(-1): Unknown error
status x    unary  ERROR 2  (UNKNOWN, as gRPC says)
```
