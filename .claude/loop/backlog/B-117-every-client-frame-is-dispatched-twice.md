---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-117 — the channel transport broadcasts every frame, including responses already routed per stream

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_incoming.add(message)` runs for every inbound message after it was routed to the stream's controller; a caller-only endpoint then needs a no-op subscription (`startCallerListening`) purely so the buffered broadcast does not fill — work added to compensate for work that should not happen; websocket adds a second broadcast on top.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart:956-958`; `caller_pipeline.dart:29-64`
("this subscription exists to keep the buffer drained"). `websocket_caller_transport.dart:334-346`
re-broadcasts into `_incomingCtl` with a set lookup per message.

## Why it matters

One or two extra broadcast dispatches per response message on every client; the
design makes a missing no-op listener a memory leak.

## Witness a round would build

Messages/s for a server stream of small messages, websocket client, before and
after skipping the broadcast for locally-initiated stream ids.

## Fix sketch

Broadcast only frames that open or advance a PEER-initiated stream (and errors);
route the rest per stream only.

## Owner decision

—
