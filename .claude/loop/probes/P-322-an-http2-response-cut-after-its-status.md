---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r855_status_then_cut_data.dart
round: 855
commit: f8523835
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport_inbound.dart]
status: valid
promoted: packages/transport/rpc_dart_http2/test/a_response_cut_mid_message_is_an_error_test.dart
---

# P-322 — an http2 response cut after its status

`fvm dart run <file>` from `packages/transport/rpc_dart_http2`. A raw h2
peer answers a server stream with HEADERS (optionally carrying
grpc-status 0, no END_STREAM), then DATA of two whole frames and `cut`
bytes of a third (0, 2, 7), with END_STREAM on that DATA or on an empty
DATA frame after it. Prints the items and how the stream ended.

## Measures

Whether a response that ends inside a frame, after its status is known,
ends OK with the cut message gone or with an error.

## Control

`cut = 0` on every arm: two items, CLEAN END.
