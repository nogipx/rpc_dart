---
status: open
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
