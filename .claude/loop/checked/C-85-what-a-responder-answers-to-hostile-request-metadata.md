---
round: 850
commit: a7ce003a
paths: [packages/core/rpc_dart/lib/src/endpoint/**, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport_inbound.dart]
scope: a unary method over a raw server channel; fourteen request openings (paths, grpc-encoding, compressed flag, content-type, grpc-timeout, no metadata frame); not http or http2
---

# C-85 — what a responder answers to hostile request metadata

Every malformed opening is answered by the gRPC rule or by a documented
lenience, and no refused one runs the handler: unknown method or service 12,
a malformed path 3, an unknown encoding with the flag 12, the flag with no
encoding 13, `grpc-timeout: 0n` 4; a lenient content-type and an
unparseable timeout are served; DATA with no opening metadata is dropped.
Probe `packages/core/rpc_dart/.dart_tool/probe/r850_responder_metadata_oracle.dart`.

## Control

The valid row: status 0, the handler ran.
