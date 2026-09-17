---
round: 371
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-62 — new
commit: yes
---

# Round 371 — the mirror of the same missing pause

## Target

Named by round 370 under `## Not fixed`, and taken immediately rather than left
to age: `BidirectionalStreamResponder.responseSink` has the same listener shape
as the `requestSink` 370 fixed, and the same argument applies to a handler
producing faster than the wire drains. 370 declined to widen its class at the
end of the round (L-12); this round is that widening, done as its own round with
its own bench and canary.

The owner raised the cap to 390 during round 370, so the constraint that made
368 and 367 decline multi-round work no longer applies.

Same lens as 368, 369 and 370 — RPC-25, siblings doing one job.

## Hypothesis

`responseSink`'s listener never pauses, so `addStream` never stops pulling and a
handler runs to exhaustion inside the server whenever the consumer stops
reading.

## Before

A caller that opens the stream and pauses, a 1 MB window, 16 KiB messages, 2000
offered, sampled at 900 ms, counted inside the handler's own producer:

```
                 produced of 2000     MB
responseSink       2000            31.3
serverStream         68             1.1     <- control
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/response_sink_backpressure.dart`
(P-62).

The control is `ServerStreamResponder` through the ordinary endpoint API, which
already forwards pause to the handler via `relay.onPause`, and differs by
exactly that. It lands on the window.

## Mechanism

Identical to 370's, on the other side of the call. A `StreamController` under
`addStream` stops pulling only while its subscription is paused; this listener
consumed each response in an `async` callback and never paused, so nothing
applied back-pressure. The damage is on the SERVER: one consumer that stops
reading makes the handler materialise its whole output in memory.

## After

Same probe, same run:

```
                 produced of 2000     MB
responseSink         68             1.1     <- 2000 -> 68
serverStream         68             1.1     <- control, unchanged
```

The fixed arm lands **exactly** on the control, as 370's did on its own sibling.
The fix is the same shape: pause before the send, resume on completion, behind a
`finished` flag so a resume cannot land on a cancelled subscription. Round 368's
guard is preserved — the send's failure is caught in `.catchError` rather than
raised out of a listen callback.

## Canary

`sub.pause()` switched off in place:

    Expected: a value less than or equal to <300>
      Actual: <2000>
    the responder pulled 2000 of 2000 messages (31.3 MB) out of the handler
    while the consumer was not reading

A number, not a timeout. The GUARD — `responseSink` still delivers all 40
messages in order — passed on both sides.

Witness: `test/streams/response_sink_bounds_its_handler_test.dart`, polling to
the threshold rather than counting after a sleep.

## Gate

All four green, and this time including the one round 370 could not claim:
`melos run analyze`, `melos run test:unit --no-select`, `melos run format:check`,
`melos run license:check`. In the changed package `fvm dart analyze lib` clean
and `fvm dart test -j 8` **+1535 ~1**.

The runs were paced 20 s apart, which is the difference from round 370 — where a
third back-to-back suite failed once and could not be named.

## Not fixed

**A direct `responseSink.add()` is still unbounded**, exactly as 370 said of the
request side: `StreamSink.add` accepts unconditionally and returns void, so
there is nowhere to push back. The bound reaches producers driven through
`addStream`.

**The endpoint's own bidi pump was not measured.** It does not use
`responseSink` — `_pumpBidirectionalResponses` drives its own loop — so it is a
third implementation of this job, not a fourth copy of this one. Whether it
applies back-pressure is a separate question with a separate bench, and naming
it here is cheaper than discovering it later.

## Links

- RPC-25 — the lens; `applied:` gains 371
- P-62 — the bench; the control is the sibling and it lands on the window
- Round 370 — the request-side half, which named this one
- P-61 — the request-side bench this mirrors
