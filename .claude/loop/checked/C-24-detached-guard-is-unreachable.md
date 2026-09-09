---
round: 225
commit: 5a0b6948
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart]
scope: [core]
---

# C-24 — the detached guard has no witness because nothing reaches it

Round 222 deleted `_detached`'s `.catchError` and the core suite stayed green,
and read that as a coverage gap: "the most load-bearing guard in this lens has
no witness". B-20 was opened to write one. **The premise was wrong**, and this
is what a witness attempt measured instead.

## Measurement

`_detached` instrumented to print whenever the future it wraps rejects, then
three scenarios each run as its OWN process — the failure being guarded against
is the root zone killing the isolate, so it cannot be asserted from inside:

```
                              detached rejections   ablated: exit code
  handler throws mid-call            0                     0
  client hangs up mid-call           0                     0
  clean call                         0                     0   <- control
```

Ablated means `_detached` reduced to a bare `unawaited(work)`. **No arm dies,
because no arm ever hands it a rejected future.**

## Control

The `clean` arm runs the identical call and ends it normally. All three arms
agree, which is the weakness worth stating plainly: this control shows the
harness exits 0 on its own, it does NOT show the harness could see a process
death. Nothing available made a detached future reject, so that half is
unproven — see "What this does not establish".

## Why nothing reaches it

Every expression `_detached` wraps is already guarded from the inside. All 25
sites, by reading:

```
 15  _sendGrpcErrorAndCleanup(...)   try/catch around the send,
                                     finally -> _cleanupStream
  7  responder.done.whenComplete(
       () => _cleanupStream(id))     a handler throw is turned into a gRPC
                                     error upstream, so done completes NORMALLY
  3  _cleanupStream(id)              _closeResponder catches; RpcCallScope
                                     .close() catches per disposer, with a
                                     timeout; releaseStreamId catches
  1  _handleClientCancellation(...)  calls only the two above
  1  _respPingHandler.respond(...)   its own try/catch/finally
```

`_detached` is **defence in depth over paths that each catch their own user
code**, and each of those inner catches carries its own recorded incident in a
comment — `RpcCallScope.close()`'s is the most explicit ("the identical failing
disposer escaped 0 times when registered before close and 1 time after ... a
root-zone reproduction terminated the process outright").

So round 222's green suite was not a coverage gap. It was an unreachable branch.

## What this does not establish

- **Not "the guard is useless."** It is the backstop for a path that loses its
  inner guard, which is exactly the refactor round 222 worried about. Keep it.
- **Not "no path can ever reject."** Three scenarios were driven, chosen from
  the incident report and the call-site sweep. A sixteenth `_detached` site
  added tomorrow, wrapping something unguarded, would reject and be caught here
  silently — with still no test to notice.
- **The witness B-20 asked for cannot be written** without first removing one of
  the inner guards, which would be testing a codebase nobody ships.

## What would change it

A `_detached` call whose work is not internally guarded. The cheap check is the
site table above: if a new call site wraps something other than those five
expressions, re-run the probe.

Probe: `packages/core/rpc_dart/.dart_tool/probe/detached_guard_rejects_nothing.dart`.
Lead, now closed: `../backlog/B-20-detached-guard-has-no-witness.md`.
Lesson: `../lessons/L-04-a-guard-with-no-witness.md`, which this round amends.
