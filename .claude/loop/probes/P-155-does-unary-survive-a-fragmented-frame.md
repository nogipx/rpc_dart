---
file: packages/core/rpc_dart/.dart_tool/probe/b126_fragmented_frames.dart
round: 518
commit: 9c69500d
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-155 — does unary survive a fragmented frame?

## Why it exists

The lead's own note says every shipped transport delivers whole frames, so this
cannot be observed by using one. The fragmenting transport has to be built, and then
the interesting comparison is across CALL SHAPES against it — because the claim is
that unary alone is affected.

## The harness

A channel that re-frames every outbound DATA frame as two DATA frames on the same
stream, splitting the payload in half. That is what a third-party transport
forwarding raw chunks produces, and it leaves the gRPC framing intact end to end —
only the message boundaries move.

The second fragment carries whatever end-of-stream bit the original had; the first
must not, or the peer sees a call that ended early.

Three shapes — unary, server stream, client stream — each with a **fresh** context.
One shared context is a single deadline: the first arm to time out leaves the others
none, and all three then report TIMEOUT for one arm's failure. That happened, and the
table was unreadable until it was fixed.

## The numbers (round 518)

```
CONTROL whole frames
   unary         got:64
   server stream got:64
   client stream got:64

each frame split in two
   unary         status 13: Failed to extract message from payload
   server stream got:64
   client stream got:64
```

## Measures

What each call shape returns, against the same transport. Not timing, not bytes —
the claim is that one shape fails where the others do not, so the outcome IS the
measurement.

## Control

**The same rig with fragmentation OFF**, where all three shapes answer `got:64`.
Without it, the unary failure could be anything about the hand-built channel rather
than about fragmentation.

**And the two streaming shapes are the other control**, in the same run. They share
the transport, the channel, the codec and the payload with unary; the only thing that
differs is which responder handles them. That is what makes this a statement about
the unary path rather than about the rig.

## What it establishes, and what it does not

Establishes: unary alone fails when one transport message carries part of a gRPC
frame, with INTERNAL "Failed to extract message from payload", while server-stream
and client-stream complete normally.

Does NOT establish what a fix costs — see the round, which attempted one and reverted
it. Accumulating in the responder is not sufficient on its own: the pipeline hands
the unary responder only `preBindMessages.first`, and `_cleanupStream` runs
immediately after, so a later fragment has neither a route nor a live stream to
arrive on.

Does NOT cover bidirectional calls, direct/zero-copy payloads, or fragmentation of
metadata frames rather than data.
