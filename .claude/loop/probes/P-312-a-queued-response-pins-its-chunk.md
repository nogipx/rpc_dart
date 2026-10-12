---
file: packages/core/rpc_dart/.dart_tool/probe/r841_caller_pinned_chunks.dart
round: 841
commit: 9f66ad37
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport_inbound.dart, packages/core/rpc_dart/lib/src/core/stream_router.dart, packages/core/rpc_dart/lib/src/core/owned_payload.dart]
status: valid
promoted: packages/core/rpc_dart/test/transports/a_queued_response_does_not_pin_its_chunk_test.dart
---

# P-312 — a queued response pins its chunk

`fvm dart run <file> <packed|split> [count]` from the repo root. A caller
`RpcChannelTransport` over a fake channel opens a server-stream call and
pauses its consumer; a hostile server sends `count` chunks, each a one-byte
response on the live stream plus 1 MiB on an id nobody opened. Then the
consumer resumes and the trailer arrives.

## Measures

RSS growth of the caller process while the responses wait, and how many
responses are delivered after the resume (all must be: L-15).

## Control

`split`: the same frames, one per chunk, so no response shares a chunk with
the filler. Before the fix:

```
arm          RSS after   peak    delivered
split  x300  +8 MiB      +100    300
packed x300  +302 MiB    +302    300
```
