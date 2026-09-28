---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-128 — on the client, `_activeStreams` drops a call at half-close, not at completion

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`finishSending` and `_markFinished` call `_releaseStream`, so `maxActiveStreams` on a client counts only calls that have not half-closed; a unary or server-stream call awaiting its response is not counted.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart:588, 819-822, 844-847`.

## Why it matters

The client ceiling bounds request-sending, not outstanding calls; B-75 measured a
ceiling holding for calls started synchronously, which does not cover calls that
already half-closed.

## Witness a round would build

Ceiling 4; start 4 unary calls against a parked handler, let them half-close,
start 4 more. Expected today: admitted.

## Fix sketch

Release the slot on the terminal inbound frame or `releaseStreamId`, not on
half-close — or document which count is meant.

## Owner decision

—
