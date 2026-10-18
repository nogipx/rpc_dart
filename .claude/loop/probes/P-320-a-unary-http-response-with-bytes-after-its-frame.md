---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r853_unary_trailing_bytes.dart
round: 853
commit: e01302e8
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
status: stale (526c8d52)
promoted: packages/transport/rpc_dart_http/test/a_unary_response_with_trailing_bytes_is_an_error_test.dart
---

# P-320 — a unary http response with bytes after its frame

`fvm dart run <file>` from `packages/transport/rpc_dart_http`. Captures a
real `RpcHttpServer` unary response, then a raw HTTP/1.1 peer replays it
with extra bytes appended to the body (content-length adjusted) to an
`RpcHttpCallerTransport` unary call: none, three zero bytes, and a 5-byte
prefix promising 9 bytes plus one.

## Measures

What the unary call ends with: OK with the value, or the error and its
status code.

## Control

The unmodified body (`none`) reads `OK value=x` on every tree. Before round
853 the two appended rows read the same, `OK value=x`; after, INTERNAL
"Response stream ended mid-message".
