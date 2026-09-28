---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-125 — request metadata is assembled in three places, and they have drifted

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`UnaryCaller.call`, `CallProcessor._sendInitialMetadata` and `ping()` each build the header map; with a null context CallProcessor adds `x-request-id` by constructing `RpcContext.empty()` just to read an id, the unary copy adds none.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart:395-436`, `base_processor.dart:1233-1298`,
`caller_pipeline.dart:317-347`.

## Why it matters

The next header rule lands in one copy; already true for the request id.

## Witness a round would build

Diff the three outputs for the same context, including null.

## Fix sketch

One `buildRequestMetadata(service, method, context)`.

## Owner decision

—
