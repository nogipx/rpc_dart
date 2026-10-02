---
status: closed (round 636)
round: 636
commit: 2e03e681
paths: [packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_frame.dart, packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
probe: none — audit probe `packages/core/rpc_dart/.dart_tool/probe/audit_limits_pinned_chunk.dart`, not yet registered
reason: "FIXED in round 636: a payload that waits is copied out of its chunk; 300 packed chunks now hold nothing (221 -> 198 MiB, was +274). Previously: bench — a queued request is a view into its inbound chunk and is charged its payload length; a peer that packs a tiny frame for a held stream with a large frame for a closed one pins the chunk at a few bytes' charge"
---

# B-229 — a tiny message pins its whole chunk

Found by the independent audit of 2026-10-02 (limits), reproduced before filing.

## The shape

On the multiplexer's fast path each decoded payload is a `sublistView` into the
inbound chunk, and the parser's `fromChunk` adds another view. A queued
`RpcTransportMessage` (client-stream sink, pre-bind lists) keeps the chunk's
backing buffer alive. Every limit charges `bufferedBytes`, the payload length.
A large frame on an already-closed stream id in the same chunk is dropped
silently, so it costs the peer nothing to include.

## Measured

`fvm dart run <probe> combined 300 1024`, one held client-stream, each chunk = a
1-byte frame for it + a 1 MiB frame on a closed id, default policy:

```
combined   charged ~3000 B   RSS 231 -> 505 MiB   no refusal
split      charged ~3000 B   RSS 230 -> 234 MiB   (same bytes, one frame per chunk)
```

Freed once the handler consumes. Bounded only by the per-stream event cap (1024)
times the stream count, against a 64 MiB connection total that reads ~KiB.
Reachable over websocket: one binary message is one chunk.

## Fix directions, unmeasured

1. Copy a payload out of its chunk when it is QUEUED (not when delivered at
   once), so only buffered messages pay a copy.
2. Charge the backing buffer's length instead of the payload's when the
   payload is a view of a larger buffer.
3. Copy when the view is much smaller than its buffer (a ratio threshold).

B-116 and round 507 mention that a retained message pins its chunk, for benign
batching only; round 614's fast path is not the root cause (views pointed into
`_buf` before it too).

## Owner decision

2026-10-02: direction 1 — copy a payload out of its chunk when it is queued;
messages delivered at once keep the view.
