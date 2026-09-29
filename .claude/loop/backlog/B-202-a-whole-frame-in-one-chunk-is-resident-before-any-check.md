---
status: open
round: 506 (measured as part of B-115; split out in the round-540 bookkeeping pass)
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: P-144
reason: "cost — the metadata limit now refuses from the header, and this is the case that bypasses it entirely: a peer whose whole frame arrives as ONE chunk is resident before the decoder sees a byte"
---

# B-202 — a frame delivered in one chunk is resident before any limit can refuse it

Split out of B-115, which round 506 closed by moving the metadata-size check ABOVE the
"do I have the whole payload" return, so an oversized metadata frame is refused from its
header rather than after it is buffered. Bench
`../probes/P-144-when-is-an-oversized-metadata-frame-refused.md`.

**The case that fix cannot reach.** On `dart:io`'s WebSocket a message arrives as a
SINGLE chunk, so the peak is resident before `RpcFrameMultiplexedChannel` sees a byte —
the header check happens after the allocation it was meant to prevent. B-115's own
parenthesis said as much ("not dart:io websocket").

What bounds it there is `_maxBufferedFrameBytes` at 16 MiB, which round 506 left
untouched, and which is a different quantity from `maxMetadataBytes`.

**Also unresolved: two places still implement one rule.** With `_decodeAt` refusing from
the header, the client's own copy of the metadata bound is redundant for metadata frames.
Not merged, because a refactor with no measured failure behind it is how a working bound
gets removed.

## Why it matters

The limit reads as a residency bound and is one only where delivery is chunked. On the
priority transport it is not.

## Witness a round would build

An oversized metadata frame delivered as one chunk over a real `dart:io` WebSocket,
reading peak residency against the chunked path P-144 already drives — and the same run
with `_maxBufferedFrameBytes` lowered, to establish which limit is actually holding.

## Owner decision

—
