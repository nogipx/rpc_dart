---
status: open (round 560 fixed item one in BOTH packages; four items remain)
round: 560
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

## Outcome (round 560) — item one CONFIRMED on the other method, and it spans two packages

`../rounds/560-the-guard-was-behind-the-await.md`. Bench
`../probes/P-184-a-start-guard-behind-its-own-await.md`.

```
rpc_dart_http   (afterModulesStart, fixed port)
  CONTROL one call          bound           isRunning=true   endpoints=1  call -> ok:x
  TWO concurrent            bound + threw   isRunning=true   endpoints=0  call -> status 14
  THREE concurrent start()  call -> ok:x

rpc_dart_http2  (start, fixed port)
  CONTROL one start()       started           isRunning=true   call -> ok:x   port free after stop()
  TWO concurrent start()    started + threw   isRunning=false  call -> ok:x   PORT STILL BOUND
```

**`start()` is REFUTED and `afterModulesStart` is confirmed.** Three concurrent `start()` calls answer
`ok:x`: its guard and assignment sit in one synchronous run with no await between, so nothing can
interleave. This lead read "set after an await" off the wrong method.

**And the sibling sweep found the same shape with the OPPOSITE symptom.** `RpcHttp2Server.start()`
sets `_isRunning` after its bind and the loser's catch sets it false over the winner's true — so http
ends up bound-and-answering-UNAVAILABLE behind a healthy flag, while http2 ends up
bound-and-serving behind a dead one, where `stop()` gives up on exactly that flag and the listener
leaks for the life of the process. One cause; no reading of either symptom finds the other.

Fixed by claiming the slot synchronously in both (`_binding`, `_starting`), released in the bind's
catch and in `stop()`. **The teardown release is not optional**: without it the first restart is
refused by the fix, which `server_lifecycle_cleanup_test` caught.

### The four items still open

1. `afterModulesStart` dereferences `_transport!` when `start()` has not run — a null-check crash
   where a StateError should name the misuse.
2. `close(force: true)` destroys connections before the promised 503.
3. `stop()`'s two comments contradict each other.
4. The drain polls `health().details['pendingRequests']` every 25 ms — the string-keyed metrics
   pattern `drain.dart` itself criticises.

None has a measured consequence yet. Also unmeasured: no TLS arm on http2 (the secure bind is a
different call behind the same claim), and `shelf_io.serve` is still passed no TLS and no `shared`.

## Owner decision

—
