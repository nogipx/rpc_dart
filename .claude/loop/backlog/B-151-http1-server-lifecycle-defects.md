---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-151 — RpcHttpServer lifecycle: crash on order, racing starts, forced close before 503, polling drain

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`afterModulesStart` dereferences `_transport!` if `start()` did not run or `stop()` already did; two concurrent starts both pass the guard (set after an await) and the loser's catch closes the shared transport; after a drain timeout `close(force: true)` destroys connections before the promised 503; `stop()`'s two comments contradict each other; the drain reads `details['pendingRequests']` out of `health()` every 25 ms.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart:169, 241-248, 265-269 vs 287-290, 298-306`. Also: no
TLS and no `shared` option are passed to `shelf_io.serve`.

## Why it matters

Crash, total outage (everything 503) after a double start, resets instead of
UNAVAILABLE on shutdown, and the string-keyed metrics pattern `drain.dart`
itself criticises.

## Witness a round would build

Concurrent `start()` twice on a fixed port; then a call.

## Fix sketch

Guard before the await; typed pending count on the transport; send 503s before
forcing.

## Owner decision

—
