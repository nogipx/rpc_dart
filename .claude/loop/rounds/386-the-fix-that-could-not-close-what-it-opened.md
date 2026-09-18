---
round: 386
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-79 — new
commit: yes
---

# Round 386 — the fix that could not close what it opened

## Target

**The owner audited round 384's own fix, hours after it landed, and found what
it missed.** Read from the source plus the SDK's `stream_controller.dart`, with
no Dart available to run it. This round measures each claim and fixes what it
can.

The class, counted before fixing (L-12): **six sites, all in the two convenience
SINKS**, which are the third copy of plumbing `ClientStreamCaller.call(Stream)`
and the endpoint bridge already have.

```
#  site                                    state after this round
1  BidirectionalStreamCaller.close()       FIXED — measured, witnessed
2  requestSink.onError (round 384's fix)   FIXED — measured, witnessed
3  requestSink, producer after the call     NOT FIXED — B-54, two candidates
                                            refuted by measurement
4  responseSink.onError (responder side)    NOT FIXED — B-55, reading only,
                                            the bench could not reach it
5  payloadResponses' dead status branch     NOT FIXED — B-55, cosmetic
6  the test that swallowed #1               FIXED — it is now a witness
```

RPC-25 again, and the same sibling: the responder's own `close()` already does
the right thing three files away.

## Hypothesis

`StreamController.close()` throws while an `addStream` is running, so
`BidirectionalStreamCaller.close()` never reaches `_processor.close()` — and
round 384's `abort(...).whenComplete(close)` turns that throw into an unhandled
zone error, which this very file's comment calls "exit 255 in a server process".

## Before

```
close() while an addStream is active
  close threw: StateError

round 384's onError path, by whether the source survives it
  source keeps going: zone errors: 1 (Bad state: Cannot add event while
                                      adding a stream)
  source ends (384's witness): zone errors: 0

the producer after the call has ended
  produced 11 when the call ended, 32 a quarter-second on
```

Probe: `rpc_dart/.dart_tool/probe/sink_close_during_add_stream.dart` (P-79),
everything inside `runZonedGuarded` so a zone error is COUNTED rather than
killing the probe.

**The second row is the whole reason round 384 shipped this.** Its witness used
an `async*` source that throws — and an `async*` ENDS at its throw, so the
`addStream` was already finished by the time `close()` ran. A source that
survives its own error, which is any controller-backed producer, keeps the
controller in `_STATE_ADDSTREAM`. Zero and one, same code, same path, different
producer.

And the owner found the standing evidence before this round measured anything:
`request_sink_bounds_its_producer_test.dart:111` read
`await caller.close().catchError((_) {})` — closing while a deliberately stalled
`addStream` was still pulling, with the error swallowed. Not a guard. A symptom
taped over.

## Mechanism

`close()` did `unawaited(_requestSink!.close())`. The throw is SYNCHRONOUS, so
it escapes before `unawaited` can wrap it, and `await _processor.close()` on the
next line never runs: the call's scope stays open. On the `onError` path the
same throw lands in a future nobody awaits, and so in the zone.

`BidirectionalStreamResponder.close()` has had the right order all along —
`await _responseSubscription?.cancel()` first, then close. Cancelling ends the
`addStream` and its source with it, which clears the state that makes `close()`
throw. The caller was the copy that did not keep its subscription anywhere it
could reach.

## After

```
close() while an addStream is active
  close threw: -

round 384's onError path, by whether the source survives it
  source keeps going: zone errors: 0
  source ends (384's witness): zone errors: 0
```

## Canary

Two halves, two canaries.

**Cancel-before-close removed** — and it fails in TWO tests, the new one and the
one whose `.catchError` this round deleted:

```
WITNESS: close() during an active addStream does not throw
  Bad state: Cannot add event while adding a stream
  package:rpc_dart/.../bidirectional/caller.dart 251:31  BidirectionalStreamCaller.close

WITNESS: requestSink does not drain its producer
  Bad state: Cannot add event while adding a stream
  package:rpc_dart/.../bidirectional/caller.dart 251:31  BidirectionalStreamCaller.close
```

**Both halves removed** — the zone witness fails with the error the owner
predicted from reading alone:

```
WITNESS: a request stream that errors and lives on reaches no zone
  Expected: empty
    Actual: [StateError:Bad state: Cannot add event while adding a stream]
```

The GUARD — `close()` with no `addStream` running — stayed green throughout.

The `.catchError` on the abort chain has no canary of its OWN: with the cancel
in place nothing throws there any more. It is kept for the reason C-26 keeps the
swallowed grant failure — the chain is unawaited, so any future throw in it is
exit 255, and the cost is one line.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` 1481/1481. Workspace suite at concurrency 4: **SUCCESS in all 15
packages**, rpc_dart **+1558 ~1** (was +1555; +3 from the new witness file).

## Not fixed

**B-54 — the producer is not stopped when the call ends.** Measured: 11 messages
produced at the moment the server ended the call, 32 a quarter-second later.
Two candidate fixes were written and **refuted by measurement**, which is the
round's other product:

- *stop on the first send failure* — never fires; C-35 already measured that
  `caller.send()` does not throw, because `CallProcessor.send` records
  `_requestSendFailure` instead of propagating;
- *gate the sink on `_processor.isActive`* — never fires either; `isActive`
  stays TRUE after the server ends the call normally.

Both were reverted rather than shipped. The real signal is the response stream
completing, which the consumer owns, so closing this is a design change and not
a small fix.

**B-55 — the responder's `responseSink` swallows a source error**, so a handler
using `responseSink.addStream(s)` where `s` errors and then ends tells the
client a clean OK. Round 384's defect, mirrored. Established by READING —
`onError` logs and returns, `onDone` runs `finishReceiving()`, which is a
half-close — and **not measured**: the probe built for it hangs before its first
arm reports, so per `measurement.md` item 10 this is a lead with reason "bench",
not a finding. `payloadResponses`' unreachable grpc-status branch rides along
there.

## Links

- RPC-25 — the lens; `applied:` gains 386. Third application in three rounds,
  and the sibling was the model every time
- P-79 — the bench; its two-arm split by producer shape is the point
- B-54, B-55 — what this round measured and did not fix
- C-35 — why the send-failure candidate is dead code
- C-26 — the precedent for keeping an unreachable-today guard
- Round 384 — the fix this audits; L-15's lesson, one level up: an arm can be
  void for the FIX as well as for the defect
