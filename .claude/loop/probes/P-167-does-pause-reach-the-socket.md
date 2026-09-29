---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b138_pause_propagation.dart
round: 534
commit: cbca6a2b
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
status: valid
---

# P-167 — does pausing a channel's `incoming` stop the source being read?

## Why it exists

The thing being asked about is buffering, and the obvious reading of buffering is memory — which
P-128 established is noise across arms here. So the question is reframed as demand: a paused
consumer either stops the source being PULLED or it does not, and that is a count.

## The harness

The source is an `async*` generator that increments a counter before each yield. A generator
suspends at its yield while its subscription is paused, so the counter is exactly "how many chunks
were taken from the wire". The source stops at a cap, so `pulled == cap` reads as unbounded rather
than as a number to interpret.

`delivered` is counted at the consumer, which is what separates "nothing was read" from "nothing
was handed over".

## The numbers (round 534)

```
  arm                          chunks pulled from source   delivered
  consumer PAUSED              5000                        0
  CONTROL not paused           5000                        5000
  GUARD paused then resumed    5000                        5000
```

After the fix the paused arm reads `1` — the chunk already in flight when the pause landed.

## Measures

Chunks pulled from the source during a 300 ms pause, and chunks delivered to the consumer. Both,
because the defect is precisely that the two disagree.

## Control

**An unpaused consumer, and a resumed one.** A channel that had simply stopped reading would pass
the witness; a pause that never lifted would too. The first says the source produces, the second
says the pause is not a hang.

## What it establishes, and what it does not

Establishes: pausing `RpcWebSocketChannel.incoming` bounded delivery and nothing else — every
chunk was still read and held in a `StreamController` bounded by nothing.

Does NOT show a failure in rpc_dart's own stack. Nothing in this library pauses a channel's
`incoming`: neither `RpcFrameMultiplexedChannel` nor `RpcChannelTransport` ever calls `pause`. What
the gap exposes is a caller holding the channel directly, and the `IRpcChannel` contract that
`incoming` is an ordinary Stream.

Does NOT use a real socket, so the claim that the pause reaches the wire rests on reading dart:io:
`_WebSocketImpl` wires its own controller's `onPause`/`onResume` to the socket subscription.

Does NOT measure the cost of a long pause. dart:io answers pings inside the subscription this
suspends, so a consumer that stays paused stops answering them — named in the code, not measured.
