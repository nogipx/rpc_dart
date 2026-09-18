---
round: 391
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-79 — reused
commit: yes
---

# Round 391 — the order without the rule

## Target

**The owner audited round 386's fix and found that it traded a throw for a
hang.** Owner-directed, past the round cap of 390 — see the note in `config.md`.

Their reading, from the SDK's `async_patch.dart`: `subscription.cancel()` on a
controller with an active `addStream` returns the cancellation future of the
SOURCE, and for an `async*` source that completes only when the generator body
finishes. *"Cancellation does not affect an async generator that is suspended at
an await."* So `await _requestSub?.cancel()` never returns for the commonest
bidi shape there is — a chat pumping an idle input stream.

Two instances, counted before fixing:

```
site                                        awaited a user stream's cancel
BidirectionalStreamCaller.close()           yes  -> fixed here
BidirectionalStreamResponder.close()        yes  -> fixed here
ClientStreamCaller.call(Stream)             no, and says why
ServerStreamResponder.close()               no, and says why
caller_pipeline's bidi bridge               no, and says why
```

Three of the five carry a comment explaining the rule. Round 386 copied the
responder's ORDER — cancel, then close — and not the rule the other three state:
**do not await it.**

## Hypothesis

`close()` hangs when the request sink's source is an `async*` parked on an
`await`, and dropping the await fixes it without bringing back the throw.

## Before

```
WITNESS: close() returns with the producer parked on an await
  TimeoutException after 0:00:05.000000: Future not completed
```

Probe: P-79's file, a fourth arm. Source:
`() async* { yield 'a'.rpc; await Completer<void>().future; }()`.

**Why round 386's three witnesses were all green.** `_endless()` parks on a
YIELD, which cancel wakes; `_errorsAndContinues()` is a plain
`StreamController`, whose cancel is immediate. Neither can express a generator
suspended at an `await`, which is the only shape that hangs — the same failure
as L-15, one turn further out: the bench could not say the word.

## Mechanism

`cancel()` returns the SOURCE's cancellation future. A `StreamController`'s is
immediate; an `async*` generator's completes only when its body does, and a body
parked on `await` never resumes. Awaiting it inside `close()` therefore blocks
`close()` for ever — and `_processor.close()` below it, exactly as before round
386, only hanging instead of throwing.

Dropping the await is safe for the reason the throw existed at all:
`_recordCancel` clears the add-stream state **synchronously**, before returning
its future. The subsequent `sink.close()` sees a controller that is no longer
mid-`addStream`.

That is not an argument, it is the measurement: round 386's witness — `close()`
during an active addStream does not throw — **still passes** with the await
gone.

## After

The quantity here is a count of arms, and it is the honest one: the failure is
a hang, so what changed is which witnesses return.

```
file                        arms   before   after
request_sink_close_...       5      4 / 5    5 / 5
response_sink_error_...      4      3 / 4    4 / 4
core suite                   —      +1562    +1564 ~1
```

```
WITNESS: close() returns with the producer parked on an await   5s timeout -> passes
WITNESS: close() during an active addStream does not throw      still passes
WITNESS: an erroring request stream reaches no zone             still passes
WITNESS: the producer stops once the call has ended             still passes
```

The second line is the load-bearing one: it is the measurement that dropping
the await does not bring the `StateError` back.

And the responder's mirror, new: `close()` returns with a handler's
`responseSink` source parked on an `await`.

## Canary

The `await` restored in both files, one run:

```
request sink  WITNESS: close() returns with the producer parked on an await
              TimeoutException after 0:00:05.000000: Future not completed
responseSink  WITNESS: close() returns with the handler parked on an await
              TimeoutException after 0:00:05.000000: Future not completed
```

Both hang; every other test in both files stays green, so the two new witnesses
isolate the two new defects.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 15 packages**,
rpc_dart **+1564 ~1**.

## Not fixed

**B-56 — the five copies want one helper**, which is the owner's own closing
point and the right read of six rounds of RPC-25. Filed rather than done: it is
a refactor across five call shapes and this round is already past the cap.

**B-53's narrow half**, unchanged.

## Links

- RPC-25 — the lens; `applied:` gains 391. Seventh round running
- L-16 — new: copy what a sibling AVOIDS, not only what it does
- L-15 — the same failure one turn out: a bench that cannot express the answer
- P-79 — reused, two arms added
- B-56 — the extraction the owner proposed
- Round 386 — the fix this corrects
