---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-126 — the unary responder assumes one transport message holds one whole gRPC frame

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`handleMessage` sets `requestHandled = true` and parses ONE chunk; an empty parse is INTERNAL "Failed to extract message from payload"; the pipeline hands it only the first pre-bind message — the streaming shapes tolerate fragmentation, unary does not, and nothing states the invariant.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart` `handleMessage` (`_parserFor(state)(payload)`,
`if (messages.isEmpty) throw`), `responder_pipeline.dart:1418-1428`.

## Why it matters

Every shipped transport delivers whole frames, so nothing fails today; a
third-party transport that forwards raw chunks breaks unary only.

## Witness a round would build

A test transport that splits each frame in two: unary vs server-stream outcome.

## Fix sketch

Accumulate until a message is complete, or document the invariant on
`IRpcTransport`.

## Owner decision

—
