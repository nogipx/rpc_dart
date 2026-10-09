---
file: packages/core/rpc_dart/.dart_tool/probe/b138_frames_after_a_unary_request.dart
round: 594
commit: 017f4c88
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
status: valid (round 594)
---

# P-212 — frames after a unary request

## Why it exists

The sweep in round 594: a unary state is never bound to a message stream, so a
data frame that arrives while its handler runs goes to the pre-bind list.

## The harness

A raw client transport with its windows off sends the metadata, one complete
request, waits for the handler to enter (it parks), then N frames of 16 KiB on
the same stream. Reads RSS, one arm per process; the argument is N.

## The numbers (round 594)

```
sent after the request   resident before   after the fix
    0                    -40 MiB
   78 MiB                +51 MiB
  156 MiB               +117 MiB
  312 MiB               +313 MiB           +57 MiB, refused
```

## Measures

Process RSS growth. Coarse, and enough here because the growth tracks the bytes
sent 1:1 at three scales. The regression test asserts the refusal on the wire
instead.

## Control

N = 0.

## Reading

rpc_dart — data frames sent on a unary stream while its handler runs: RSS
tracks the bytes 1:1 at three scales (`+51/+117/+313 MiB` for 78/156/312 MiB)
before the fix, `+57` and a RESOURCE_EXHAUSTED after
