---
round: 391
class: process
cost: one shipped defect, caught by the owner within hours. Round 386 fixed a StateError by copying BidirectionalStreamResponder's ORDER — cancel the subscription, then close the sink — and did not copy the rule the other three implementations state in comments: do not AWAIT that cancel. The result traded a throw for a hang on the commonest bidi shape there is, and all three of the round's witnesses were green because neither of its two sources could express a generator suspended at an await
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart]
commit: e60dfdbf
status: active
---

# L-16 — copy what the sibling AVOIDS, not only what it does

## The rule

When a lens says *the sibling holds the answer*, the answer is not only the
sequence of calls. It is also everything the sibling deliberately does NOT do —
and that half is invisible in the diff, because it is an absence.

So when taking a fix from a neighbouring implementation, read its comments for
the word "not": `Not awaited`, `Deliberately NOT`, `must not`. Those sentences
are the part that was paid for.

## The price

Round 386 fixed `BidirectionalStreamCaller.close()`, which threw a `StateError`
while an `addStream` was running. The model was
`BidirectionalStreamResponder.close()`, and the fix copied its shape exactly:

```dart
await _requestSub?.cancel();
if (_requestSink != null) unawaited(_requestSink!.close());
```

Three other implementations of the same mechanic each carry a comment saying why
the await must not be there:

- `ServerStreamResponder.close()` — *"Not awaited: a handler stuck in cancel
  must not block teardown of the rest of the call"*
- `ClientStreamCaller.call(Stream)` — *"cancelling a stalled producer can block
  indefinitely"*
- `caller_pipeline`'s bidi bridge — *"Awaiting it deadlocked cancel()"*

The model the round chose was the fourth, which awaited — and it was the one
copy that had never been driven with a user-supplied generator.

`subscription.cancel()` returns the SOURCE's cancellation future. For an
`async*` that is the VM's, which completes only when the generator body does,
and a body suspended at an `await` never resumes. So round 386 turned a throw
into a permanent hang on the canonical bidi shape:

```dart
caller.requestSink.addStream(() async* {
  await for (final m in userInput) yield m;
}());
```

**And the round's three witnesses were all green**, because its two sources were
an `async*` parked on a YIELD (cancel wakes it) and a plain `StreamController`
(cancel is immediate). Neither can express the failing shape — L-15 one turn
further out: the earlier lesson was about an arm whose subject never reached the
code, this is about an arm whose subject reached it in the one state that works.

The owner found it by reading, within hours of the commit.

## How to apply it

Two steps, both cheap:

1. Before copying a sibling, `grep` the family for the same mechanic and read
   EVERY copy, not the nearest one. Five implementations disagreeing 4-to-1 is a
   fact the majority is telling you.
2. When the fix is about a call that takes a USER-SUPPLIED stream, the witness
   needs a user-supplied stream in its worst state — for Dart, an `async*`
   suspended at an `await`. A controller-backed source and a generator parked on
   a yield both cancel promptly and prove nothing.
