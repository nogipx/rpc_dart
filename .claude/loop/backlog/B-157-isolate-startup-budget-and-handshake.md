---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-157 — isolate: startup can take twice startupTimeout, over a handshake with a spare port; the kill comment has the order backwards

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Two phases each get the full `startupTimeout` (`:424`, `:552`); the worker replies with a SendPort and the host then sends a second port in an `init` message where one would do; `killIsolate`'s comment says the close frame goes out first, but `RpcChannelTransport.close()` awaits `_channelSub.cancel()` before closing the channel, so the frame follows the kill.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:262, 312, 424, 443-451, 552, 569-577`.

## Why it matters

A 30 s default is really 60 s; an extra round trip and state to clean up; a
comment that describes an order that never happens (and an unawaited close).

## Witness a round would build

Worker that stalls in its entrypoint: time to failure.

## Fix sketch

One budget across both phases; single handshake; fix or reorder the comment.

## Owner decision

—
