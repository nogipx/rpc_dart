---
status: decided by owner (round 540)
release: breaking
round: 498
commit: 3391d5ed
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: P-136
reason: "owner decision — every claim CONFIRMED and the abandonment half FIXED in round 498; whether an implicit bound should exist at all changes behaviour for every existing caller, which the lead itself frames as an either/or"
---

# B-107 — unary and client-stream calls hide a 60 s timeout, never tell the server, and the other shapes have none

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

With no deadline, `UnaryCaller` waits `timeout ?? remainingTime ?? 60s` and `ClientStreamCaller` `_noDeadlineFallback = 60s`; no `grpc-timeout` is sent and on expiry only the id is released — no reset, no cancel notice — so the server handler keeps running; server-stream, bidi and zero-copy unary have no bound at all.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart:91-92`:

```dart
final effectiveTimeout = timeout ?? remainingTime ?? const Duration(seconds: 60);
```

On timeout the `finally` (`:592-623`) cancels the subscription and releases the
id; `_notifyPeerOfCancellation` runs only from the token listener (`:166-193`).
`client/caller.dart` `_noDeadlineFallback = Duration(seconds: 60)` and
`unawaited(close())` on timeout. Zero-copy unary goes through
`_executeUnaryCall` (`caller_pipeline.dart:786-821`) with no timeout.

## Why it matters

A legitimate unary call longer than 60 s fails client-side with a
`TimeoutException` nobody configured, while the server finishes the work and
sends a response to nobody. Four call shapes, three different behaviours for the
same missing deadline.

## Witness a round would build

Unary handler taking 61 s with no deadline: client outcome, and whether the
server handler observes cancellation. Repeat for client-stream and the zero-copy
unary path.

## Fix sketch

Either no implicit timeout anywhere (the gRPC default), or one documented default
applied to every shape, sent as `grpc-timeout`, and followed by a cancel notice on
expiry.

## Round 498 — every claim confirmed, and the lead splits in two

```
no deadline
unary         grpc-timeout=[null]  gave up after 60.0s  TimeoutException  cancelled=0
clientStream  grpc-timeout=[null]  gave up after 60.0s  TimeoutException  cancelled=0
serverStream  grpc-timeout=[null]  gave up after 65.0s  <- the PROBE's budget, not a bound

with a 500 ms deadline, as the control
unary/clientStream/serverStream   grpc-timeout SENT, 0.5s,
                                  RpcDeadlineExceededException, cancelled=1
```

Four shapes, three behaviours, exactly as filed. The control matters: with a
deadline every piece of machinery works, so each no-deadline row is a comparison
rather than an assertion.

**FIXED in round 498 — the abandonment.** A caller that gave up told the server
nothing, so the handler ran on: `cancelled=0 -> 1` for unary and client-stream. No
policy decision was needed for that half, and the duty was already named in
`notifyPeerOfAbort`'s own doc comment. `serverStream` is unchanged because nothing
bounds it, so nothing is abandoned.

## What is left, and why it is the owner's

Whether a call with NO deadline should be bounded at all:

1. **No implicit timeout anywhere** (gRPC's own behaviour). Honest, and every
   caller relying on the current 60 s starts hanging instead.
2. **One documented default on every shape**, sent as `grpc-timeout` so the server
   shares it. Consistent, and it picks a number for everyone — and it would bound
   server-stream and bidi calls that are legitimately long-lived, which is what
   `halfOpenStreamTimeout`'s own doc says cannot be safe by default.

Either changes behaviour for existing callers. The measurement does not choose.

Two smaller things inside the same question:

- the exception TYPE differs by origin: `TimeoutException` from the implicit
  fallback and from an explicit `timeout:` argument, `RpcDeadlineExceededException`
  from a deadline. Deliberate (the 60 s is nobody's deadline) and pinned by a
  guard, but it means a caller catching the Rpc type misses the fallback.
- the zero-copy unary path through `_executeUnaryCall` has no bound and was NOT
  measured.

## Owner decision

**REMOVE the implicit barrier** — no deadline means no timeout, as the streaming shapes
already behave. Taken in the round-540 owner review.

The argument: a hidden limit the server never hears about is worse than no limit. It turns a
slow answer into a client-side error while the server still believes the call is live, and it
does that unevenly — unary and client-stream carry it, the other shapes do not.

**Verified still present at review time**: `_noDeadlineFallback = Duration(seconds: 60)` in
`client/caller.dart`, and `timeout ?? remainingTime ?? const Duration(seconds: 60)` in
`unary/caller.dart`.

**BREAKING, and the CHANGELOG line is the deliverable as much as the code.** A caller relying
on the implicit 60 s gets a hanging call where it used to get an error. The line has to say
that plainly and name the remedy — pass a deadline.

**What the round owes.** The witness is a call with no deadline against a server that never
answers: today it fails at 60 s, after the fix it waits. The canary is the same call WITH a
deadline, which must still fail at that deadline — otherwise the change removed more than the
implicit fallback.
