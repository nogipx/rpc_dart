---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r858_http2_response_oracle.dart
round: 858
commit: 6c31366f
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport_inbound.dart, packages/core/rpc_dart/lib/src/contracts/caller_trailer.dart]
status: valid
promoted: no — a CLEAN comparison against P-317
---

# P-326 — what an http2 caller accepts from a hostile server

`fvm dart run <file>` from `packages/transport/rpc_dart_http2`. P-317's
oracle on the http2 caller: a raw h2 server answers each call with one of
thirteen hostile sequences (no message, two messages, a cut message, status
99, x, -1, " 0", no status, two statuses, Trailers-Only OK, end on DATA, OK
with a grpc-message), and the probe prints what a unary, server-stream,
client-stream and bidi consumer end with. Read beside P-317's output.

## Measures

The outcome per shape per sequence, compared row by row with the channel
caller.

## Control

`valid: one message, OK`: OK on all four shapes.
