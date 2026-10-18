---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r847_http_body_oracle.dart
round: 847
commit: 42f23cce
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: stale (526c8d52)
promoted: packages/core/rpc_dart/test/streams/a_unary_request_with_trailing_bytes_is_refused_test.dart
---

# P-316 — a malformed gRPC body on each shape

`fvm dart run <file>` from the repo root. A real `RpcHttpServer` with one
method per shape (unary `echo`, server stream `items`, client stream
`collect`, bidi `chat`); each gets ten request bodies over a well-formed
HTTP request: valid, two messages, a prefix promising more or less than
follows, the compressed flag with no encoding, a non-CBOR payload, a bare
prefix, an empty body, a zero-length message, and a whole message followed
by one byte. It prints the HTTP status, grpc-status and grpc-message, and
which handler ran.

## Measures

What the server answers to each malformed request, and whether the handler
ran for it. A `grpc=0` on any row but `valid` (and `empty body` on the
streaming-request shapes, where zero messages is legal) is a malformed
request accepted.

## Control

`valid` on every shape: `grpc=0`, the handler ran. Before round 847:

```
trailing junk byte   echo     200 grpc=0    handler: [echo(x)]
                     items    200 grpc=0    handler: [items(x)]
                     collect  200 grpc=3    handler: []
two messages         echo     200 grpc=13   handler: []
                     items    200 grpc=13   handler: [items(x)]
```
