---
status: closed (round 574)
round: 574
commit: 3fadccbc
release: changelog
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart]
probe: P-195
reason: "bench — CONFIRMED exactly as filed: `pair()` with one event-loop turn between the two ends read `server credit null` against `67108864`, so the side built second had flow control off in that direction. Fixed with `BufferedBroadcastController`, the sketch's own answer"
---

# B-173 — RpcDirectMultiplexedChannel is a sync broadcast that starts pumping in its constructor

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_incomingCtl` is `StreamController.broadcast(sync: true)` fed from the constructor; frames arriving before the transport subscribes are dropped — including the connection-window grant; `memoryPair` is safe only because both transports are built in one expression, the public `pair()` with an await in between is not.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart:16-28`.

## Why it matters

The defect fixed in isolate and wasm, still present in the public in-memory
channel.

## Witness a round would build

`pair()`, build the client transport, `await Future.delayed(0)`, build the server
transport; read the client's `flowControlConnectionCredit`.

## Fix sketch

Use `BufferedBroadcastController` like `RpcFrameMultiplexedChannel`.

## Outcome (round 574) — confirmed as filed, down to the mechanism

`../rounds/574-the-grant-nobody-was-listening-for.md`. Bench `P-195`.

```
                                             before            after
WITNESS  pair(), one turn between the ends   server null       67108864
ARM      pair(), no gap                      server 67108864   unchanged
CONTROL  memoryPair()                        server 67108864   unchanged
```

**One event-loop turn is the whole difference**, and the side built SECOND is the one that loses:
`RpcChannelTransport` advertises its window from its constructor, into a broadcast with no listener
yet. `server credit null` is flow control off in that direction for the life of the connection.

**Both other arms are the lead's own point**: `memoryPair` is safe only because it builds the two ends
in one expression, and nothing about `pair()` promises that to anyone else.

Fixed with `BufferedBroadcastController`, the sketch's answer and what
`RpcFrameMultiplexedChannel` already uses. **The swap drops `sync: true`**, so delivery here is now
asynchronous — a real behaviour change, and 15 green packages including every `memoryPair` test are
what establish nothing depended on it.

**`sizeOf` cannot bind on this channel**: a `directPayload` weighs 0 by definition, so only the 4096
count bound applies. `B-217`'s subject on a third queue, stated rather than worked around. No arm
drives either bound.

**Canary A is recorded for being the WRONG arm**: `maxPendingEvents: 0` ablates so much that even the
client loses its own inbound grant, failing on a different assertion. The faithful switch-off is the
original controller in place.

## Owner decision

—
