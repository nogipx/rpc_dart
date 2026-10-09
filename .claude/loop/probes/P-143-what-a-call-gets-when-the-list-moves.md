---
file: packages/core/rpc_dart/.dart_tool/probe/b114_middleware_list_mutated.dart
round: 505
commit: 0e5d6c1b
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart]
status: valid
---

# P-143 — what does a call get when the middleware list moves under it?

## Why it exists

The defect is a Dart iteration rule, so it would be easy to check by reading. What
reading cannot give is the thing that matters: **which error the CALLER ends up
with.** `ConcurrentModificationError` is a `StateError`, so it is not an RPC status —
a call that should have reported "the endpoint is closing" reported a bug in the
library instead. The rig therefore measures the call's outcome, not the endpoint's
internals.

The arms vary what mutates the list while a call is parked inside the loop body:
`close()` clearing it, `addMiddleware` appending to it, and nothing.

## The harness

One middleware whose `processRequest` awaits 200 ms — that is what holds the call
inside the loop — and the disturbance runs at 100 ms, half way. A unary call over a
channel pair, with the outcome collapsed to either `OK <value>` or the error's
runtime type, so the rows are comparable at a glance.

Timing is the only delicate part and it is one-sided: the disturbance must land
while the call is inside the loop. 100 ms into a 200 ms park is a wide target, and
the CONTROL row (nothing disturbs it) reads `OK` regardless, so a mistimed run shows
up as an unexpected `OK` and not as a false positive.

## The numbers (round 505)

```
                                 before                            after
CONTROL nothing disturbs it      OK echo:x                         OK echo:x
close() while parked             ConcurrentModificationError        RpcCancelledException
                                 (length:0)                         'Endpoint closed'
addMiddleware while parked       ConcurrentModificationError        OK echo:x
                                 (length:2)
CONTROL close(), no middlewares  OK echo:x                         OK echo:x
```

**The `close()` row still fails after the fix, and must.** The endpoint is closing;
the call cannot succeed. What changed is that it fails with its own status instead of
with a `StateError`. A rig that only asked "did the call succeed" would score the fix
as no change at all.

## Measures

The runtime type of the error the caller receives, or its value on success. The type
IS the finding here — the before and after rows differ in nothing else.

## Control

**Two, and the second one localises the defect.**

*Nothing disturbs it* must read `OK echo:x`: without it, every row is equally
consistent with a middleware that never runs or a call that always fails.

*`close()` with ZERO middlewares* must also read `OK echo:x`. With an empty list the
loop never awaits, so `moveNext()` is never called a second time and the mutation
cannot be observed — which pins the defect to the iteration rather than to `close()`
being called during a call. Without this arm, "close() breaks an in-flight call" is
an equally good reading of the table and the fix would have been aimed at `close()`.

## What it establishes, and what it does not

Establishes: both mutators are ordinary API and both broke an in-flight call with a
`StateError`. One middleware suffices — the check happens on the second `moveNext()`.
After snapshotting the list, `close()` produces `RpcCancelledException: Endpoint
closed` and `addMiddleware` produces nothing at all, the late middleware simply not
applying to a call already in flight.

Does NOT cover the interceptor list, which `close()` also clears. Those loops build
the chain synchronously with no `await` in the body, so the list cannot change
between two `moveNext()` calls — checked by reading, not measured, and the distinction
is recorded because it is the reason the interceptor half needed no fix.

Nor does it cover the streaming middleware paths beyond what they inherit:
`_applyRequestMiddlewaresToStream` calls the same function per message, so each
message takes a fresh snapshot. That preserves the previous behaviour, where a
middleware added mid-stream applied to later messages, and was not varied here.

## Reading

rpc_dart — measures the error TYPE the caller receives, not whether the call
succeeded, because the defect and the fix agree that a call interrupted by
`close()` fails; only the type differs (`ConcurrentModificationError` versus
`RpcCancelledException`). Two controls, and the second localises the defect:
with the collection EMPTY the loop never awaits, so it never observes the
mutation — without that arm, "close() breaks an in-flight call" explains the
table equally well and the fix gets aimed at the wrong function. Timing is
one-sided by construction: a mistimed disturbance shows up as an unexpected
`OK`, never as a false positive.
