---
status: open (round 580 answered four of eight claims; three unexamined, one documented not removed)
round: 580
commit: 2275b2ab
release: none
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart, packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart]
probe: none — the witness line reads "None"; these are dead-surface claims a sweep settles
reason: "cost — what remains is three claims needing their own arm (microtask-draining startup, the extra async-broadcast hop, `close()` unawaited in handlers), the closure-to-top-level refactor, and the whole web half, which round 580 did not read"
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

## Outcome (round 580) — four of eight, one per claim

`../rounds/580-eight-claims-and-what-each-was-worth.md`. No bench: the witness line above reads "None",
and these are dead-surface claims a sweep settles.

```
1 entrypointWrapper is a local closure, capture hazard   TRUE, latent -> documented
2 startup relies on the VM draining microtasks           not examined
3 an extra async-broadcast hop per message               not examined
4 isolateId unused                                        HALF TRUE   -> arg removed
5 workerUri ignored on the VM                             TRUE        -> documented
6 runRpcIsolateManagerWorker a no-op                      ALREADY DOCUMENTED
7 the finish message type is unreachable                   TRUE        -> documented
8 close() unawaited in handlers                            not examined
```

**Claim 4's one-word summary could not say what was wrong.** `isolateId` is NOT unused — it builds
`debugName`. What was dead is the COPY of it crossing the isolate boundary in the spawn args, which no
reader on the worker side ever touched. The arg is gone and the wrapper's indices moved down with it; since
the layout is positional and read by index, the suite passing (`+93`) is what says nothing depended on the
removed slot.

**Claim 6 is refuted as a defect**: that function already carries "No-op on the VM ... Exists so the
signature matches `isolate_transport_web.dart`". Dead surface that says why is documented.

**Claim 7 is documented rather than deleted, deliberately**: the branch below it DROPS whatever falls
through, so removing an unreachable branch would turn a bare end-of-stream message — if anything ever
sends one — from a frame into a silent loss. A reading is enough to call it unreachable, not enough to make
deletion safe.

### What remains

Claims 2, 3 and 8 each need their own arm and were not examined. Claim 1 is documented rather than
structurally fixed: a top-level wrapper would make the capture hazard impossible, but it is a refactor of
the one function that knows the arg layout, with no failing arm, in a round that had already changed that
layout. **The web half (`web_bridge.dart:163, 248, 254`) was not read at all.**

## Owner decision

—
