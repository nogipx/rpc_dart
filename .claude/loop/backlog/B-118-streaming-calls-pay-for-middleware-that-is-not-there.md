---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-118 — streaming calls wrap every message in several async* layers even with no middleware

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_applyRequestMiddlewaresToStream`/`_applyResponseMiddlewaresToStream` are `async*` loops awaiting an async function per message even when `_middlewares` is empty; on top sit `handleServerStream` (async*), `_withHandlerSlotStream` (async*), `StreamBridge`, `_bridgeCallerResponses` and, for bidi, a controller plus `.transform`; StreamProcessor/CallProcessor also push every message into a controller only a no-op listener reads.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart:294-310`, `:482-587`;
`responder_pipeline.dart:206-218`; `caller_pipeline.dart:602-779`;
`base_processor.dart:196, 322-336, 693` (`_responseController`) and
`:914, 1047-1083, 1643` (`_requestController`).

## Why it matters

Several microtask hops and allocations per message per layer. These async*
layers are also the source of the dart2js cancel problems that the bridges were
later added to work around.

## Witness a round would build

Server-stream of 1M tiny messages over the in-memory pair, zero middleware; time
before and after a fast path.

## Fix sketch

Return the stream unchanged when there are no middlewares; replace the no-op
controllers with a direct call; collapse the bridge stack.

## Owner decision

—
