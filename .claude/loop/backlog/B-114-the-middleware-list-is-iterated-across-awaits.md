---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-114 — middlewares are iterated across awaits while close() clears the list

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`for (final middleware in _middlewares) { current = await ... }` — `close()` does `_middlewares.clear()` and `addMiddleware` appends; either during an in-flight call throws ConcurrentModificationError into that call.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart:264-292` (and `_middlewares.reversed`),
`close()` at `:223-249` clears both lists.

## Why it matters

A call in flight during `endpoint.close()` fails with a ConcurrentModificationError
instead of its status.

## Witness a round would build

Middleware that awaits 100 ms; start a call; `endpoint.close()` at 50 ms.

## Fix sketch

Snapshot the list (`List.of`) at call start.

## Owner decision

—
