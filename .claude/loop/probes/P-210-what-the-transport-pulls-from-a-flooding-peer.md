---
file: packages/core/rpc_dart/.dart_tool/probe/b138_what_bounds_a_flood_without_flow_control.dart
round: 593
commit: abac9d61
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
status: broken (round 593) — the arm reads an absent consumer rather than a present bound: a peer-minted stream with no responder endpoint attached has nowhere to be dispatched, so `_admitToStreamBuffer` is not shown to have been reached
---

# P-210 — what the transport pulls from a flooding peer

## Why it exists

B-138's remaining subject: with flow control off, what bounds an inbound flood? The
answer has to be a count of what the transport DEMANDED, because residency alone
cannot tell a bound from a discard.

## The harness

An `IRpcChannel` whose `incoming` is an `async*` generator: it yields one opening
metadata frame per stream, then data frames, counting every yield. A generator
suspends at `yield` until the listener asks again, so `pulled` is the transport's own
demand.

The same instrument `P-167` used for this lead's first half, and the round had to
rediscover it — see the three rig failures below.

## The numbers (round 593)

```
                                      PULLED   delivered   errors   resident
CONTROL  flow control ON, 64 KiB      20001        0          0      +34 MiB
WITNESS  flow control OFF             20001        0          0      +40 MiB
```

320 MiB offered as 20000 frames of 16 KiB on one peer-minted stream, consumer paused.

## Measures

Frames the transport pulled from the channel, against frames offered; plus delivered,
refusals and residency.

## Control

**Flow control ON is the control and it does not differ.** That is itself the
reading: rpc_dart's flow control is a send-side credit protocol, so it never
throttles reading and a peer ignoring grants is outside it entirely.

## What it cannot see, which is why the status is `broken`

Residency of `+34 MiB` against 320 MiB offered, with nothing refused, means the
frames are DISCARDED rather than buffered — and the likeliest cause is the rig: a
peer-minted stream with no `RpcResponderEndpoint` attached has nowhere to be
dispatched. So the arm may be measuring an absent consumer rather than a present
bound, and `_admitToStreamBuffer` is not shown to have been reached at all.

Fix before reuse: attach a responder endpoint whose handler never returns.

## Three rig failures, each of which read as a result

1. **A `StreamController` source measures the BENCH.** Pushing the flood into a
   controller read `+316 MiB` with flow control ON and `+300` with it OFF — the
   controller queueing 320 MiB, with no peer waiting for credit for a window to act
   on. `measurement.md` item 6.
2. **A data frame for a stream nothing opened is silently dropped**, so an arm that
   feeds only data frames reads `delivered 0, errors 0` everywhere and looks like a
   bound. Send the opening metadata frame first.
3. **`health().details` carries no buffer depth.** `activeStreams` counts streams
   THIS side opened and `streamControllers` counts `getMessagesForStream` calls — on
   this rig, the probe's own subscriptions.
