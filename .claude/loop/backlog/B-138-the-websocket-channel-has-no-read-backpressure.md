---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-138 — the websocket channel does not propagate pause to the socket

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_incoming` has no `onPause`/`onResume` wired to `_sub`, so a paused consumer never slows the socket; only rpc_dart's own flow control bounds a peer, which a foreign or legacy peer does not honour.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart:102, 107`.

## Why it matters

Unbounded buffering below the transport against a peer outside the protocol.

## Witness a round would build

Legacy peer (flow control off) flooding a paused consumer; RSS.

## Fix sketch

Forward pause/resume.

## Owner decision

—
