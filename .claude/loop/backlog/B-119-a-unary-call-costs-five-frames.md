---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-119 — a unary call is five frames, three of them JSON-encoded metadata

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The responder sends initial headers BEFORE running the handler, then data, then a trailer; the caller sends metadata then data; on channel transports each metadata frame is `json.encode` + `utf8` + an extra copy.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart` `handleMessage`: `sendMetadata(initial)`
before `_handler(request)`; `channel_frame.dart:247-259` JSON metadata encoding.

## Why it matters

Latency and CPU per unary call; initial headers also go out for calls that then
fail (no Trailers-Only), which is the case the HTTP transports distinguish.

## Witness a round would build

Unary round trips/s over the frame pair; frames per call counted at the channel.

## Fix sketch

Send initial headers with the first response (or fold them into the trailer for
unary); a binary header encoding is a wire change for the owner.

## Owner decision

—
