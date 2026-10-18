---
file: packages/transport/rpc_dart_isolate/.dart_tool/probe/r801_paused_caller_producer.dart
round: 801
commit: 3400b5f3
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/**, packages/transport/rpc_dart_isolate/lib/**]
status: stale (526c8d52)
promoted: packages/core/rpc_dart/test/endpoint/a_zero_copy_transport_offers_no_unasked_compression_test.dart
---

# P-292 — a codec server stream over isolate: the producer past a paused caller, and the time to read it

A worker produces 4000 messages of 16 KiB under one policy (512 KiB window).
Arms by argv[0]: `tight` and `turn` (a paused caller; produced at 600 ms,
without and with an event-loop turn per message), `random` (the same, with
incompressible payloads), `read` and `read-identity` (a consumer that reads
all; the second asks for `identity` explicitly). Also promoted as the matrix
cell `isolate | server stream, caller paused` in
`packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart`.

## Measures

How many messages the handler got past a paused caller (worker side), and
the wall time for the caller to read all 4000.

## Control

`random` removes the mechanism (a payload gzip cannot shrink much) and
`read-identity` removes the offer:

```
tight          4000 produced     random    40 produced   (13.5 KB on the wire each)
read            630 ms           read-identity   460 ms
```
