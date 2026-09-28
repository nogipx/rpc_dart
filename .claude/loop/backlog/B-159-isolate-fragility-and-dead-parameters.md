---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart, packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-159 — isolate: a spawned closure in a large scope, implicit startup ordering, dead parameters and branches

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`entrypointWrapper` is a local closure inside `spawn()` (any capture of an outer variable makes spawn fail or copy host state); the worker's startup relies on the VM draining microtasks between port messages; an extra async-broadcast hop per message; `isolateId` unused, `workerUri` ignored on the VM, `runRpcIsolateManagerWorker` a no-op; the `finish` message type is unreachable; `close()` unawaited in handlers.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:69, 99-101, 189-195, 231, 240-283, 320, 453-479, 602-605`;
`web_bridge.dart:163, 248, 254`.

## Why it matters

Refactor hazards and dead surface.

## Witness a round would build

None.

## Fix sketch

Top-level entrypoint, remove the hop and dead code, document or implement the
ignored parameters.

## Owner decision

—
