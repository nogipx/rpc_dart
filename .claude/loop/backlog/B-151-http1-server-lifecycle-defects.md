---
status: open (rounds 560, 561 and 573 did four of five; item 4 remains and is not a defect)
round: 573
commit: fb7770cd
release: changelog
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: P-194
reason: "cost — what is left is item 4, the drain polling `health().details['pendingRequests']` every 25 ms. A typed pending count is a design change with no failure to measure, which is why three rounds have left it; plus the unmeasured TLS/`shared` remainder"
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

### Items 1 and 3 — done in round 561

`../rounds/561-two-comments-about-one-call-disagreed.md`.

**Item 3's contradiction is REAL and the two halves are 25 lines apart**, which is why reading the
method alone does not show it — a doc comment above `stop()` against an inline one inside, about the
same call:

```
/// `HttpServer.close(force: false)` is NOT a drain ... completes as
/// soon as the port is released
    // `close(force: false)` stops accepting AND waits for what is already running
```

`dart:io` settles it: `close()` completes when the port is released and only `force: true` touches
active connections, so the doc comment was right and the inline one false. **The false half is the
dangerous one because it offers a REASON** — "does double duty" — which makes the explicit
`_drainRequests` below look redundant, and the `stop()` doc three lines up spells out what deleting it
does: the endpoint closes under live handlers and the caller hangs with no answer coming.

**Item 1**: `_transport!` now a named local and a `StateError` naming both phases, thrown BEFORE the
bind claim is set so a corrected caller can just call them in order. Canary: restoring the bare
dereference gives `threw _TypeError:<Null check operator used on a null value>` where the witness wants
a StateError naming `start()`.

### Item 2 — CONFIRMED and fixed in round 573

`../rounds/573-the-503-written-to-a-dead-socket.md`. Bench `P-194`.

```
                                            before                    after
WITNESS  drain 200ms, handler 30s    ClientException: Connection    HTTP 503
                                     closed before full header
ARM      no drainTimeout             ClientException: ... same      HTTP 503
CONTROL  handler finishes in budget  HTTP 200                       HTTP 200
```

The ordering is `close()` / drain / **`close(force: true)`** / `endpoint.close() ->
transport.close()`, and that last step is where "Complete any pending responses with 503" lives — over
sockets the force close already destroyed. **Both branches had it**: the no-drain one reaches the same
step after its own force close.

**The yield is the part worth keeping.** Reordering alone still read `ClientException`: completing the
completer only hands the response to shelf, which still has to WRITE it, and there is nothing to await
for that, since round 561 established `HttpServer.close()` completes on port release. `Duration.zero`
reads `HTTP 503` — one event-loop turn, not a wall-clock sleep, which matters because `B-187` is a
lead about the sibling sleeping a fixed 50 ms.

Not covered: a large pending body, which may not fit the socket buffer in one turn. A 503 does, by
construction.

### The item still open, and it is not a defect

4. The drain polling `health().details['pendingRequests']` every 25 ms — a design change (a typed
   pending count on the transport) rather than a defect. No failure to measure; `drain.dart` already
   criticises the pattern.

Also unmeasured: no TLS arm on http2 (the secure bind is a different call behind the same claim), and
`shelf_io.serve` is still passed no TLS and no `shared`.

## Owner decision

—
