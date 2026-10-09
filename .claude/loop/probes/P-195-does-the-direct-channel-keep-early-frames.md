---
file: packages/core/rpc_dart/.dart_tool/probe/b173_direct_channel_drops.dart
round: 574
commit: 3fadccbc
paths: [packages/core/rpc_dart/lib/src/rpc/transports/direct_multiplexed_channel.dart]
status: valid
---

# P-195 — does the direct channel keep what arrives before a listener?

## Why it exists

B-173 named its own witness: `pair()`, build the client transport, await a turn, build the server
transport, read the client's `flowControlConnectionCredit`. That is what this is, plus the two arms
that make the reading mean something.

**The observable already exists** — `RpcChannelTransport.flowControlConnectionCredit` — so nothing is
instrumented. A side that never received the peer's grant reads `null`, which is flow control off in
that direction rather than a small number.

## The harness

Three arms, each a fresh pair:

- **WITNESS** — `pair()` with ONE event-loop turn awaited between constructing the two transports;
- **ARM** — the same with no gap;
- **CONTROL** — the shipped `memoryPair()`, which builds both ends in one expression.

## The numbers (round 574)

Before:

```
WITNESS  client 67108864   server null
ARM      client 67108864   server 67108864
CONTROL  client 67108864   server 67108864
```

After:

```
WITNESS  client 67108864   server 67108864
ARM, CONTROL  unchanged
```

## Measures

The connection credit each side holds after every constructor-time advertisement has had 200 ms to
land. Both sides, because which one loses is the finding: the side built SECOND never receives what
the first sent.

## Control

**Two, and they say the same thing from different directions.** The no-gap arm reads correctly before
the fix, so the witness is about the ORDER rather than about a grant that is never sent. `memoryPair`
reads correctly too, which is exactly the lead's claim — it is safe by accident, because both ends are
built in one expression.

Neither moves after the fix, so the change is confined to the window.

## What it establishes, and what it does not

Establishes that one event-loop turn between constructing the two ends of a public `pair()` lost the
connection-window grant entirely, and that a buffered controller keeps it.

Does NOT drive the buffer's bounds. 4096 events and 16 MiB are
`BufferedBroadcastController`'s defaults, and no arm here holds a listener off long enough to reach
either.

Does NOT measure the byte bound at all, because it cannot: a `directPayload` weighs 0 by definition,
so only the count binds on this channel — `B-217`'s subject on a third queue.

Does NOT cover what else may arrive in that window. The grant is the frame the lead names and the one
with an observable; a request frame landing there would be lost the same way and is not read here.

## Reading

rpc_dart — `pair()` with ONE event-loop turn between constructing the two
transports, read through an observable that already exists:
`flowControlConnectionCredit`, which answers `null` for a side that never got
the peer's grant. `WITNESS server null -> 67108864`, with a no-gap arm and
`memoryPair()` both reading `67108864` throughout — the two controls are the
lead's own point, that `memoryPair` is safe only by building both ends in one
expression. Reads BOTH sides, because which one loses is the finding. Drives
neither of the buffer's bounds, and cannot drive the byte one at all: a
`directPayload` weighs 0
