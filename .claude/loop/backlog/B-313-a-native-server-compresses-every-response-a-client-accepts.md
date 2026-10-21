---
status: open
round: (not re-measured)
commit: dbd45a03
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor_responder.dart]
probe: none
reason: risk — read from the code during the API review, not measured: a responder has no compression switch, and on native platforms gzip is registered by default
rank: 11
---

# B-313 — a native server compresses every response a client accepts

A caller declares compression only with `compressionEnabled`. A responder has
no such switch: it picks a response encoding from the peer's
`grpc-accept-encoding` and the process-wide registry
(`RpcGrpcCompression.selectResponseEncoding`), and on native platforms the
registry holds the dart:io gzip codec from startup. So by default a native
rpc_dart server compresses every response for a client that says it accepts
gzip -- a grpc-go client with the gzip compressor imported, for one. grpc-go's
own server compresses only when configured to. `compressIfSmaller` stops the
output growing; the CPU is spent either way.

rpc_dart's own caller without `compressionEnabled` sends `identity`, so it is
not affected.

The registry stays process-wide (owner, 862116ca, confirmed during the API
review): a fix here is a switch on the responder, not a per-endpoint
registry.

Unknown: the CPU cost per response size against a gzip-accepting peer, and
whether any test pins the current behaviour.

## Next step

Probe: a responder answering 1 KiB, 64 KiB and 1 MiB compressible and
incompressible payloads to a caller sending `grpc-accept-encoding: gzip`, CPU
time per call against the same caller sending `identity`.

## Owner decision

—
