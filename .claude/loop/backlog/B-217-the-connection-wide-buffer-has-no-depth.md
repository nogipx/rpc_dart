---
status: open
round: 550
commit: 52ad63a0
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/core/buffered_broadcast.dart]
probe: P-178
reason: "found by the probe for B-106's own fix: there are TWO queues on the receive path, and round 550 bounded one. The connection-wide `BufferedBroadcastController` is sized by `bufferedBytes`, which is 0 for a directPayload, so it holds direct objects without limit — measured at 355 MiB where the per-stream path now stops at 71"
---

# B-217 — the connection-wide buffer has no depth either

Found while witnessing B-106's fix, and it is the same hole one layer out.

## Two queues, not one

A message arriving on the receive path goes to ONE of two places:

- `_streamControllers[streamId]`, the per-stream controller, when a consumer has bound to
  that stream. Charged against `RpcStreamBufferLedger`, which round 550 gave an EVENT
  dimension so a zero-copy payload is bounded by queue depth.
- `_incoming`, the connection-wide `BufferedBroadcastController`, otherwise — and that one is
  sized by `sizeOf: (m) => m.bufferedBytes`, which is **0 for a `directPayload`**.

So the fix for B-106 covers the path a bound consumer uses, and the connection-wide buffer
holds direct objects without limit.

## Measured, by accident

The first version of P-178's bounded arm subscribed to `incomingMessages` instead of
`getMessagesForStream`, which left `_streamControllers` empty so the per-stream ledger was
never charged at all:

```
  arm                               queue cost   (nominal 400 MiB)
  MINTING via incomingMessages, depth=64   355 MiB   <- this lead
  MINTING via getMessagesForStream          270 MiB   <- unbounded, before round 550
  MINTING via getMessagesForStream, d=64     71 MiB   <- bounded, after
```

`355 MiB` with a depth of 64 configured is the finding. The reading initially looked like a
ceiling that does not work, which is why it is worth recording how it was told apart.

## Why it is a separate question rather than part of B-106

The bound would be a **per-CONNECTION** depth, not a per-stream one, and that is a different
field with a different meaning. B-106's decision was explicit about a per-stream event
ceiling; inventing a second public field inside that round would repeat the B-209 / B-128
mistake of shipping a limit whose quantity nobody pinned.

It is also narrower in reach: `_incoming` is for NEW-STREAM routing and for a caller-only
endpoint that subscribes a no-op listener to keep the buffer drained. A direct object sitting
there means nobody has claimed the stream — which is either a peer opening streams nothing
answers, or the documented reorder window.

## Witness a round would build

P-178 with its `incomingMessages` variant restored as a deliberate arm rather than a mistake,
plus the question this lead cannot answer from the probe alone: **how long can a direct object
stay in `_incoming` in practice?** If the responder pipeline claims every inbound stream
promptly, the window is short and the severity is low; if a caller-only endpoint's no-op
drainer is what empties it, the depth is whatever the peer sends between drains.

`BufferedBroadcastController` takes `sizeOf` and has no count bound, so the fix is the same
shape as round 550's: a second dimension, charged and released together.

## Owner decision

—
