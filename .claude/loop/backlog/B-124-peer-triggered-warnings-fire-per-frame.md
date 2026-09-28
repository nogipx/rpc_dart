---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-124 — warnings a peer can trigger fire on every frame, and application errors log at error twice

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

CLAUDE.md: a warning a peer can repeat fires ONCE; these fire per frame: `Ignoring no-op frame for unknown stream`, `Refusing stream … concurrent-stream limit`, the pre-method refusal, the handler-limit refusal, `Message received but endpoint is not started`; `StreamProcessor.sendError` logs every status sent at error, and `UnaryCaller` logs every failed call at error twice.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart:685, 714, 776, 1049, 1256`;
`base_processor.dart:717`; `unary/caller.dart:337, 586`.

## Why it matters

Log flooding under a misbehaving peer, and an application NOT_FOUND reads as an
incident on both sides.

## Witness a round would build

Count records from 10k no-op frames on unknown ids (the logging test pattern in
`test/transports/flow_controller_logging_test.dart`).

## Fix sketch

One-shot bools for the peer-driven warnings; application statuses at debug.

## Owner decision

—
