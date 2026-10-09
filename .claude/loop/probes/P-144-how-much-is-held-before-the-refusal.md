---
file: packages/core/rpc_dart/.dart_tool/probe/b115_oversized_metadata_buffered.dart
round: 506
commit: acefa601
paths: [packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart]
status: valid
---

# P-144 — how much is held before the refusal?

## Why it exists

The limit fires either way, so "is the frame refused" is the wrong question and a
test asking it passes against the defect. The question is **how many bytes the peer
got the channel to hold first** — the peak, not the outcome.

The arms therefore vary one bit: the frame's METADATA flag, at a declared size
chosen to sit between the two ceilings (10 MiB — over `maxMetadataBytes`' 64 KiB,
under `maxFramedMessageBytes`' 16 MiB). Same size, same delivery, one flag, and the
whole difference in behaviour follows from it.

## The harness

A hand-written `IRpcChannel` whose inbound byte stream the probe writes to, wrapped
in `RpcFrameMultiplexedChannel` with the default `closeOnOversizedFrame: true`. That
default is not incidental: it is the SERVER's setting and the one under which
`_refusedFrameHeader`'s early header check deliberately returns null, so the server
is the side that buffers.

Nine bytes of hand-built header declaring 10 MiB, then 64 KiB chunks.

**The loop yields a microtask turn between chunks, and that is what makes the count
mean anything.** Without it the writer outruns the decoder and the figure measures
how fast the probe can call `add`, not how much the channel accumulated. A chunk is
only written if the previous one did not produce the refusal.

## The numbers (round 506)

```
declared payload 10.00 MiB; maxMetadataBytes 64 KiB, maxFramedMessageBytes 16 MiB

                                 before                  after
METADATA flag set                10485769 bytes          9 bytes
CONTROL data frame, same size    10485769 bytes          10485769 bytes
```

9 bytes is the header — the refusal now lands before a single payload byte is
accepted. 10485769 is 160x the ceiling the frame was subject to.

## Measures

Bytes written into the channel before its stream reported an error. A proxy for the
reassembly buffer's high-water mark, and an honest one because of the yield between
chunks: the channel has had a turn to refuse each chunk before the next is offered.

Not RSS. The allocation is the point, but RSS across arms is the trap P-128 paid
for; the byte count is exact where RSS would be noise.

## Control

**A data frame of the same declared size, which is legal.** It must be accepted in
full, in both tables. Without it, a small "accepted" figure is equally consistent
with a rig that cannot feed 10 MiB at all — and after the fix that reading would
have been indistinguishable from success.

The control is also what identifies the flag as the cause rather than the size:
10 MiB with the flag is refused, 10 MiB without it is not, and nothing else differs.

## What it establishes, and what it does not

Establishes: a metadata frame declaring 10 MiB was buffered in full, 160x its own
ceiling, before the metadata limit fired — because that limit was checked below the
completeness check, so an incomplete frame returned null and the caller kept
buffering. After moving the check above it, the same frame is refused from the header
alone, at 9 bytes.

Does NOT establish anything about a peer that sends the whole frame in ONE chunk. On
`dart:io`'s WebSocket, which delivers a message as a single chunk, the peak is
resident before this class sees a byte — that is what the existing
`_maxBufferedFrameBytes` overflow check bounds, and it is untouched here. This probe
is about the incremental-delivery case, which is where the metadata ceiling was
doing nothing.

Nor does it cover the client half (`closeOnOversizedFrame: false`). That path already
applied the metadata ceiling from the header in `_refusedFrameHeader`, with a comment
saying why; the fix brings the server path level with it.

## Reading

rpc_dart — measures the PEAK, not the outcome: the limit fires either way, so
"is the frame refused" is the wrong question and a test asking it passes
against the defect. Counts bytes accepted before the error, **yielding a
microtask turn between chunks** — without that the writer outruns the decoder
and the figure measures how fast the probe can call `add`. One bit varies (the
metadata flag) at a size chosen to sit between the two ceilings, and the
control is that same size without the flag: legal, accepted in full in both
tables, which pins the cause to the classification and keeps a small
after-figure from reading as a broken rig.
