---
round: 370
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-61 — new
commit: yes
---

# Round 370 — thirty-one megabytes of demand nobody asked for

## Target

B-49, filed by round 368 and left open for a bench. Of everything still open it
is the only item that clears the severity bar on its own — unbounded memory — and
it is finishable in one round because the fix already exists in the sibling.

The owner was asked where to point the remaining round and answered *decide from
the measurements*. Those pointed here: round 369 found client-stream's defect to
be a wire-format decision that is his to make, and server-stream came back clean
on five edge cases across two rounds.

Same lens as 368 and 369 — RPC-25, two siblings doing one job — and the same
pair, one axis over. 368 found the crash in it; this is the memory.

## Hypothesis

`BidirectionalStreamCaller.requestSink`'s listener never pauses, so `addStream`
never stops pulling and the caller drains the application's whole producer into
`_sendSequence` however slowly the peer consumes.

## Before

A handler that takes one message and stalls, a 1 MB window, 16 KiB messages,
2000 offered, sampled at 900 ms. Counted inside the producer's own generator:

```
                 pulled of 2000      MB
requestSink        2000            31.3
call(Stream)         66             1.0     <- control
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/request_sink_backpressure.dart`
(P-61).

The control is the sibling on the same rig, differing by exactly the pause. It
stops at **the window**, not merely at "fewer" — 66 x 16 KiB is 1.03 MB — so the
bench lands on the value the mechanism predicts rather than on a timing artefact.

2000 is the probe's ceiling, not a plateau: the producer was exhausted. The
upload the owner described has no such ceiling.

## Mechanism

The listener consumed each request in an `async` callback and never paused its
own subscription. A `StreamController` under `addStream` stops pulling from the
source only while its subscription is paused, so nothing ever applied
back-pressure: `_sendSequence` became an unbounded queue in front of the
transport, which is the exact defect `ClientStreamCaller.call()` documents having
fixed on its own side.

## After

Same probe, same run:

```
                 pulled of 2000      MB
requestSink          68             1.1     <- 2000 -> 68
call(Stream)         66             1.0     <- control, unchanged
```

68 against the sibling's 66: one message in flight and one in the controller,
which is the shape of the pause. The fix is the sibling's, copied deliberately —
pause before the send, resume on completion, guarded by a `finished` flag so a
resume cannot land on a cancelled subscription.

The round-368 guard survives the change of form: the callback is now synchronous
with `unawaited(... .catchError(...))`, so a send failure is still caught rather
than raised into the zone. `call_shapes_cannot_kill_the_process_test.dart` is
green.

## Canary

`sub.pause()` switched off in place:

    Expected: a value less than or equal to <300>
      Actual: <2000>
    the caller pulled 2000 of 2000 messages (31.3 MB) out of the producer
    while the handler was stalled

A number, not a timeout. The GUARD — `requestSink` still delivers all 40
messages in order — passed on both sides, so the witness isolates the bound and
not the feature.

Witness: `test/streams/request_sink_bounds_its_producer_test.dart`. It polls to
the threshold rather than counting after a fixed sleep, because the producer runs
in this process and a sleep would only say how long the test waited.

## Gate

`melos run analyze` clean (21 members + wasm). `format:check` and
`license:check` green (1422/1422). `fvm dart analyze lib` clean,
`fvm dart test -j 8` in the changed package **+1533 ~1**.

**`melos run test:unit` failed once and I could not name the test**, which is
what `config.md` demands before calling anything a flake. It was the third heavy
suite run back to back; two further runs were green and the third reported
SUCCESS, with the load average at 4-6. The likeliest candidate is this round's
own GUARD, whose delivery wait is 10 s — but that is a guess, not an
identification, and it is recorded as such rather than as a green gate. The
threshold was NOT loosened to make it go away.

`test:web` was not re-run: it is red on an arm unrelated to this change (B-48).

## Not fixed

**A direct `sink.add()` is still unbounded**, and that is the `StreamSink`
contract rather than a defect — `add` accepts unconditionally and returns void,
so there is nowhere to push back. The bound reaches producers driven through
`addStream`, which is what an upload uses. Said here because the fix's reach is
narrower than "requestSink is now bounded" would imply.

**`BidirectionalStreamResponder.responseSink` was not measured.** It is the
mirror API, its listener has the same shape, and the same argument applies to a
handler producing faster than the wire drains. Not swept here: this round's
class was the REQUEST side named by B-49, and widening it at the end of a round
is how a subset gets reported as the job (L-12). It is the obvious next target.

## Links

- RPC-25 — the lens; `applied:` gains 370
- B-49 — closed by this round
- P-61 — the bench; the control is the sibling and it lands on the window
- Round 368 — found the crash in this same pair and filed B-49
- `ClientStreamCaller.call()` — the sibling whose pause was copied
