---
status: decided by owner (round 415)
round: 391
commit: e60dfdbf
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/sink_close_during_add_stream.dart
reason: cost — a refactor across five call shapes, proposed by the owner at the end of a session already past the round cap. Every instance is currently correct, so this buys future rounds rather than fixing anything today
---

# B-56 — five copies of one subscription discipline

The owner's closing point after auditing rounds 384-390, and the right read of
seven consecutive RPC-25 applications: the same mechanic — *drive a
user-supplied stream into a call* — exists five times, and every round finds a
different copy missing a different clause of it.

```
implementation                       pause   cancel     close      stop
                                     on send unawaited  after      on done
ClientStreamCaller.call(Stream)        yes     yes        n/a        yes
ServerStreamResponder                  yes     yes        yes        n/a
caller_pipeline's bidi bridge          yes     yes        yes        yes
BidirectionalStreamCaller.requestSink  yes     yes*       yes*       yes*
BidirectionalStreamResponder.responseSink yes  yes*       yes        n/a
```

`*` added in rounds 384, 386, 390 and 391 — one clause per round, each found
only because something broke.

What a shared helper would own: pause the subscription for the duration of each
send; cancel it WITHOUT awaiting (L-16); close the sink only after that cancel;
stop pulling once the call's `done` completes; and route every failure somewhere
that cannot reach the zone.

## Owner decision

**Proposed by the owner** (after auditing rounds 384-391) and not yet scheduled.
What is wanted is a yes/no on doing it as its own round: it is a refactor with
no defect behind it, so it competes with finding new ones, and B-10's standing
rule keeps refactor work inside core and transport — which this is.

## Why it is filed rather than done

It touches five call shapes and the round that would do it is already past the
cap. Every instance is correct as of round 391, so this buys future rounds
rather than fixing anything today — which also means it should be done while
that is still true, not after the next divergence.

## Where to start

The witnesses already exist and would carry over unchanged:
`request_sink_close_during_add_stream_test.dart` (four arms),
`response_sink_error_reaches_the_client_test.dart` (four arms),
`request_sink_bounds_its_producer_test.dart`, and P-79.

The awkward part is that the five differ in what they own: two have a sink and
three take a `Stream`, the responder has no "stop on done" (it IS the producer),
and the bridge owns both directions. A helper that takes a subscription plus
callbacks is likely closer than a base class.

## The full sweep — round 415, and it is NINE, not five

Asked for by the owner after the decision: find every site of this shape so they
are fixed together. **READ, not measured** — every row below is from reading the
code, and none of the three defects named has a witness yet.

### The criterion that decides membership

**Does the library OWN the stream it subscribes to?** A `StreamController` it
built, or a transport's own byte stream, cannot park on cancel. A stream handed
in by a user — or one built from a user's `async*` middleware chain — can, and
that is the whole reason L-16 exists. Only the second kind is in the class.

This is what keeps the sweep from swallowing the codebase: `.listen(` appears
everywhere, and most of it is the library reading its own plumbing.

### The nine

```
                                              pause/   cancel     stop on
  site                                        resume   unawaited  done
  1 ClientStreamCaller.call(Stream)             -         y        y
    client/caller.dart:314
  2 ServerStreamResponder                       y         y        n/a (it IS
    server/responder.dart:46                                       the producer)
  3 caller_pipeline bidi bridge                 y         y        y
    caller_pipeline.dart:626-627
  4 requestSink                                 -         y        y
    bidirectional/caller.dart:148
  5 responseSink                                y         y        y
    bidirectional/responder.dart:99
  6 _bridgeCallerResponses                      y         y        y
    caller_pipeline.dart:250
  7 CallScope.track                             NO        y        y
    contracts/call_scope.dart:133
  8 CallScope.listen                            NO        NO       n/a
    contracts/call_scope.dart:168
  9 _wrapStream                                 y         NO       y
    resilience/circuit_breaker_interceptor.dart:203
```

### 6 is the one to extract FROM

`_bridgeCallerResponses` is the most complete of the nine and nothing named it:
`onPause`/`onResume` forwarding, `unawaited(inner?.cancel().catchError((_) {}))`,
and the clause the others do not have at all — **fire the cancellation token
ONLY when the stream did not already finish**, because firing it on a natural
completion poisons a REUSED `RpcContext` and the NEXT call on that context throws
`RpcCancelledException`.

Its own doc says both rules "cost a round". Extracting the helper from anywhere
else re-loses them.

### Three defects the sweep found

**8 — `CallScope.listen` awaits a cancel, thirty lines under the comment saying
not to.** `onDispose(sub.cancel)` (`:181`), and disposers ARE awaited:
`await Future<void>.value(_disposers[i]()).timeout(disposerTimeout)` (`:224`),
`disposerTimeout = 5 seconds`. So closing a scope with a parked generator costs
up to 5 s per subscription. `track`, immediately above, already states the rule
and the evidence: *"cancelling a suspended generator can block indefinitely and
the scope has to finish closing."*

**9 — the abandon timer drops a cancel Future bare.**
`circuit_breaker_interceptor.dart:282` is `sub.cancel();` with the result
discarded, and `:252` awaits one. `track`'s comment names this exact shape as
measured: *"Both this and the onCancel above dropped the returned future
outright, so a rejected cancel became TWO unhandled async errors — measured, and
enough to kill the isolate."*

**7 and 8 — no `onPause`/`onResume` at all**, so a slow consumer of a tracked
stream never pauses the source. 1 and 4 forward pause by other means; these two
forward nothing.

### Adjacent, and deliberately NOT in the list

`GrpcHealthServiceImpl._watch` (`integration/grpc_health.dart:211`) has the same
code shape — awaited cancel, no pause forwarding — but its source is
`_status.changes`, an internal broadcast the library owns. It cannot park on a
user's generator, so the clause that matters does not apply. Recorded so the
next sweep does not re-derive it.

### NOT swept, and why

**The transports.** 17 awaited-cancel sites across `rpc_dart_http2`,
`rpc_dart_websocket` and `rpc_notify` — but the overwhelming majority subscribe
to streams the library itself built, where the criterion above excludes them.
Separating the exceptions needs per-site reading, and it is a different job from
this lead's, which is the call machinery. **This sweep does not cover them and
should not be read as saying they are clean.**

## Owner decision

**Taken: extract it.**

The timing argument in this record is the reason: every one of the five is
correct as of round 391, so the witnesses all carry over unchanged and the
refactor is measurable against a green suite rather than against a moving one.
Four consecutive rounds each found a DIFFERENT copy missing a DIFFERENT clause —
tell the peer (384), close without throwing (386), stop on `done` (390), do not
await the cancel (391) — which is the whole case for one owner instead of five.

Two constraints on the carrying round, both from this record:

- **A helper taking a subscription plus callbacks, not a base class.** The five
  genuinely differ in what they own — two have a sink and three take a `Stream`,
  the responder IS the producer so it has no "stop on done", and the bridge owns
  both directions. A base class would force the differences into flags.
- **Convert one call site at a time, with its existing witness green after
  each.** Five at once and a regression has five candidate causes.

The clauses the helper owns: pause per send; cancel UNAWAITED (L-16); close only
after that cancel; stop pulling on the call's `done`; route every failure away
from the zone.
