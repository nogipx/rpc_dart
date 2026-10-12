---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/r855_http2_request_cut.dart
round: 855
commit: f8523835
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport_inbound.dart]
status: valid
promoted: packages/transport/rpc_dart_http2/test/a_request_cut_mid_message_is_refused_test.dart
---

# P-323 — an http2 request cut mid-message, per shape and ending

`fvm dart run <file>` from `packages/transport/rpc_dart_http2`. A raw h2
client sends `RpcHttp2Server` four bodies (one whole frame; whole + 3
bytes; whole + a prefix promising 9 and one byte; the frame cut at 7) to
each of four methods (unary, server, client, bidi), ending the request on
the DATA, on an empty DATA frame, or on trailers. Prints the grpc-status,
its message and what each handler received. Round 847's P-316 is the
same question asked of `RpcHttpServer`.

## Measures

Whether a request that ends inside a gRPC frame is refused, or answered OK
with its cut message gone.

## Control

The `whole` body: grpc=0 and the handler got `x`, on every shape and ending.
