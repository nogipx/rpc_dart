---
file: packages/core/rpc_dart/.dart_tool/probe/r846_truncated_response.dart
round: 846
commit: 513ef2a6
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_caller.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport_inbound.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: stale (526c8d52)
promoted: packages/core/rpc_dart/test/streams/a_response_cut_mid_message_is_an_error_test.dart
---

# P-315 — a response cut mid-message

`fvm dart run <file> <cut>` from the repo root. A caller `RpcChannelTransport`
over a fake channel opens a server stream; the "server" sends two whole gRPC
frames, then the first `cut` bytes of a third (none for 0), then an OK
trailer. It prints the items and the error the consumer saw. The http path
is driven by `rpc_dart_http/.dart_tool/probe/fuzz_http_client.dart` (a lying
`content-length` or a lying frame prefix under an OK status).

## Measures

Whether a consumer can tell a stream that ended mid-message from a complete
one: items delivered and the error, if any.

## Control

`cut 0`, the same stream ending between frames. Before the fix:

```
cut    items   error
0      2       none
2      2       none
5      2       none
7      2       none
```
