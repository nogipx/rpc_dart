---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b139_1_close_order.dart
round: 535
commit: 5e2af858
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
status: valid
---

# P-168 — what does a clean websocket close cost?

## Why it exists

B-139's item 1 claims `close()` cancels the read subscription before `sink.close()`, so dart:io
cannot read the peer's close reply and falls back to a multi-second timer. The lead marks it
unverified, and the claim is entirely about what the SDK does with a socket nobody is reading — so it
cannot be settled by reading this class.

## The harness

A real dart:io peer that answers the close handshake, and three arms timed with a `Stopwatch`: the
shipped order, the order swapped from outside (close the socket first, then the channel), and the raw
dart:io `WebSocket.close()` with no channel at all.

The channel's `incoming` is SUBSCRIBED in every arm, as the frame channel above it always is — an
unlistened single-subscription controller changes what `close()` can do, and would have made the arms
incomparable.

## The numbers (round 535)

```
  arm                                   close() took (min of 5)   all
  as shipped: cancel, then sink.close    0ms                      [4, 0, 0, 0, 0]
  swapped:    sink.close, then cancel    0ms                      [0, 0, 0, 0, 12]
  CONTROL raw dart:io WebSocket.close    0ms                      [0, 0, 0, 0, 12]
```

Minima of five, because noise here only adds time.

## Measures

Wall time of one `close()`, five runs per arm, reported as the minimum with the full set beside it.

## Control

**The raw dart:io close, with no channel involved.** That is what says a number belongs to this class
rather than to the SDK's handshake. Here all three agree at zero, which is what refutes the claim.

## What it establishes, and what it does not

Establishes: the close order costs nothing against a peer that answers. Cancelling the subscription
does not prevent the SDK completing its handshake, because the ping/pong and close machinery sits
BELOW the subscription — in the transformer, not in the listener.

Does NOT test a peer that never answers the close. dart:io's fallback timer is real and would fire
there — but it would fire in either order, so it is not evidence about this line.

Does NOT cover the web implementation, where `close()` goes through a different channel class
entirely.
