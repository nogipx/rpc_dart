---
status: open
round: (not re-measured) — filed from a READ sweep the owner handed in, re-verified against ff930001 before filing; no round took it
commit: ff930001
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart]
probe: none — READ, not measured
reason: cost — a two-line fix, but it changes what an unknown number of existing tests exercise, so the round that takes it has to re-read every suite built on `pair()` rather than just make the edit
---

# B-69 — `pair()` builds a client that production never builds

`RpcChannelTransport.fromChannel` chooses the oversized-frame policy by side,
and the choice is deliberate and documented (`channel_transport.dart:207-213`):

```dart
// A server closes on an oversized frame, a client refuses the call.
closeOnOversizedFrame: !isClient,
```

The reasoning is in `frame_multiplexed_channel.dart:60-68`: a server must close,
because dart:io has already buffered the whole message before this class sees a
byte and a surviving connection lets the peer repeat the peak; a client must
NOT, because killing the connection over one large response takes every other
in-flight call with it, and RESOURCE_EXHAUSTED on that one RPC is gRPC's answer.

`RpcChannelTransport.pair()` (`channel_transport.dart:243-253`) does not make
that choice. It delegates to `RpcFrameMultiplexedChannel.pair()`
(`frame_multiplexed_channel.dart:518-531`), which constructs both halves with
the plain constructor and therefore takes the default:

```dart
this.closeOnOversizedFrame = true,        // frame_multiplexed_channel.dart:78
```

**So the client returned by `pair()` has the SERVER's policy.** Its oversized
frame kills the connection; a real client's fails the stream and leaves the
others alone.

## Why this is worse than an ordinary copy

It is a defect in the witness, not in the product, which is the class the loop
has the least defence against. `pair()` is the frame-codec test harness — the
one path that exercises the real encoder and decoder in memory. Every suite
built on it believes it is testing a client, and on this axis it is testing a
server. A change that broke the client's "fail the stream, keep the connection"
behaviour would pass.

The blast radius is bounded by which behaviours the flag reaches, and there are
two: the refused-frame header path (`_refusedFrameHeader` returns `null`
immediately when the flag is set, `:197`) and malformed metadata
(`onMalformedMetadata: closeOnOversizedFrame ? null : _refuseMetadata`, `:409`).
Both are the "refuse the stream" half. Neither is reachable from a `pair()`
client today.

`memoryPair()` is not affected — `RpcDirectMultiplexedChannel` passes messages
by reference and has no frame path at all.

## What a round does

Pass `closeOnOversizedFrame` through `RpcFrameMultiplexedChannel.pair()` per
side, matching `fromChannel`. Then read the suites that use `pair()`: any test
that asserts a connection dies on an oversized frame from the client side was
asserting the wrong half, and is the thing this lead is for.

## Owner decision

—
