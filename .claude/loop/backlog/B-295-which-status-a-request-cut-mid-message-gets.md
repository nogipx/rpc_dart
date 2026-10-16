---
status: decided by owner (round 875)
release: changelog
round: 857
commit: 98ba93a5
paths: [packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport_inbound.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/r857_refused_upload_core.dart — P-325
reason: owner — a status every transport answers; changing it is a wire-visible change on all of them
rank: 4
---

# B-295 — which status a request cut mid-message gets

Since rounds 553-554 core answers a request stream that ends inside a gRPC
frame with INVALID_ARGUMENT ("Request stream closed mid-message"), on all
four shapes; round 857 aligned http2 to it. grpc-go answers the same
request INTERNAL. That was read in its source (master, 2026-10-16) and not
measured against a grpc-go server. `parser.recvMsg` turns an `io.EOF`
inside a body into `io.ErrUnexpectedEOF`. `serverStream.RecvMsg` maps that
to `codes.Internal`, and so does `toRPCErr`. INVALID_ARGUMENT tells a
client its argument was wrong, when in fact its bytes were cut in transit.

A second, smaller split inside the library: a unary request of one whole
message and the start of a second IN ONE CHUNK is answered INTERNAL ("More
than one request", round 847) on core and http, INVALID_ARGUMENT on http2,
because the http2 transport refuses before core sees two messages.

Neither status is retried by the default policy, so a caller branching on
the code is the one affected.

## Options

1. Keep INVALID_ARGUMENT everywhere; the unary one-chunk case on core and
   http moves to it too.
2. Move all of it to INTERNAL, as grpc-go does.

## Owner decision

2026-10-16: option 2, INTERNAL everywhere, as grpc-go does. This covers
all four shapes on every transport, and it also removes the unary
one-chunk split (http2 moves to INTERNAL too). This reverses the status
chosen in rounds 553-554 and 857.
