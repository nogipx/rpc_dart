---
round: 426
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-96 — new
commit: yes
---

# Round 426 — the mirror nobody held up

## Target

**B-56's PUMP half**, the remainder round 425 stated. Finishing a started
thread rather than opening one, 14 rounds from the cap.

The scope was decided before the fix. Of the four pumps, two are SINK pumps and
genuine twins — `requestSink` and `responseSink`, each building a controller,
listening to it, pausing per send, half-closing on done, telling the peer on
error. The other two are not:

```
  1 ClientStreamCaller.call(Stream)   races a Completer against the response
                                      future; the race IS its stop clause
  3 the bidi bridge's request half    drives an ordered send SEQUENCE, and its
                                      teardown owns BOTH directions
```

This round takes 4 and 5. Sites 1 and 3 are declined with the lead's own
reason — see `## Not fixed`.

## Hypothesis

The twins disagree on a clause, the way every other pair in this lead has. The
candidate: **stop pulling once the call is over**, which round 390 gave
`requestSink` and which B-56's two tables describe two different ways —
the nine-site sweep marks `responseSink` "stop on done: y", the five-site table
"n/a, it IS the producer". Neither is measured, and they cannot both be right.

## Before

Both are wrong. `responseSink` watches nothing, and it needs to.

A handler producing at one message per 5 ms with a consumer reading everything,
counted inside the generator; the delta is over the 250 ms after the ending:

```
                                messages after the ending   responder.done
A  handler half-closes          +32                         true
A2 handler fails the call       +35                         true
B  the caller goes away         +34                         FALSE
C  the client transport dies    +33                         FALSE
D  CONTROL responder.close()    +1                          true
E  CONTROL caller side (390)    +1                          --
```

Probe:
`packages/core/rpc_dart/.dart_tool/probe/response_pump_outlives_its_call.dart`
(P-96).

A and A2 are the finding: the responder ENDED THE CALL ITSELF, `done` completed,
and the producer kept being drained. The signal was already there — round 390's
sentence, one class over.

## Mechanism

`StreamProcessor` — the responder's — has no `done`; only `CallProcessor` got
one, in 390. But `BidirectionalStreamResponder` has had its own `done` since
before this loop, completed by `finishReceiving`, `sendError` and `close`.
Nothing watched it.

Worse than the caller's version in one respect: a send on a finished processor
RETURNS rather than throwing, so where 390's defect was "an endless error log",
this one is silent.

## After

Same probe, same arms: `A +32 → +1`, `A2 +35 → +1`. Controls unchanged.

The fix is the extraction. `SinkPump` (`src/core/sink_pump.dart`, hidden from
the public barrel) owns pause-per-send, half-close-on-done, tell-the-peer-once,
stop-on-`ended`, and a teardown that cancels before closing and awaits neither.
Each site chooses only its signal — `_processor.done` for the caller, `done` for
the responder:

```
two files                        -207 / +69      plus 121 lines of helper
two flags (`finished`/`aborted`) collapsed into the pump's one
two fields per site              (_requestSink + _requestSub) -> one pump
```

## Canary

```
fix switched off in SinkPump   witnesses that failed
ended.then((_) => stop())      "the handler produced 33 more messages in the
                                250ms after it had half-closed the call
                                (27 -> 60)"
                               "the handler produced 31 more messages ... after
                                it had failed the call (29 -> 60)"
                               AND round 390's own caller-side witness:
                                "the producer kept running after the call ended
                                 (was 13, now 37)"
_subscription.pause()          "the responder pulled 2000 of 2000 messages
                                (31.3 MB) out of the handler while the consumer
                                was not reading"
                               "the caller pulled 2000 of 2000 messages
                                (31.3 MB) out of the producer while the handler
                                was stalled"
```

**One ablation, both sites red, twice over** — and the first ablation reaches a
witness written 36 rounds ago for the other class. Two halves, two canaries; the
GUARDs (both "still delivers everything, in order", plus the new "still delivers
a source that ends by itself") stayed green under both.

The new witnesses carry a second assertion that makes the first mean something:
`atEnd > 5`, or a producer that never got going would pass while proving
nothing.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1593/1593
melos run test:web       SUCCESS -- 12 dart2js suites, 0 failures
```

## Not fixed

**Arms B and C — the peer leaving — are unchanged, and deliberately.** No signal
reaches a hand-built responder when the client goes away: `responder.done` reads
FALSE in both, so there is nothing for the pump to watch, and inventing one is a
different round. In the library's own path the pipeline closes the responder,
which is arm D at +1. Stated because a +34 left in the table looks like an
oversight otherwise.

**Sites 1 and 3 are not converted, on the lead's own constraint.** B-56 requires
"a helper taking a subscription plus callbacks, NOT a base class", because a
base class forces the differences into flags. These two differ in CONTROL FLOW,
not in hooks: site 1's stop clause is a `Future.any` race it must own, and site
3's sends go through an ordered `enqueue` whose teardown handles both
directions. Folding them in needs the flags the lead forbids. The owner can
overrule; nothing measured says they are wrong today.

**`RpcCallScope.listen` (site 8) is neither bridge nor pump** and stays as it is
— unchanged from 425.

**The per-item trace lines changed wording.** `'Sending request in
bidirectional stream: $request'` and `'Response sent via responseSink [id: $id]'`
became one `'<what>: sending'`, logged before the send rather than after. The
payload is no longer interpolated, which is the one behavioural difference worth
naming: it was a trace-level leak of message content.

## Links

- B-56 — 8 of its 10 sites now have one owner; the two declined are declined on
  its own constraint, which is an answer rather than a remainder
- RPC-25 — the twins disagreed, and the one the tests did not reach is the one
  that was wrong (the 331 criterion, fourth time)
- P-96 — the bench; P-79 is the neighbouring bench for the same pair's OTHER
  clause
- round 390 — the same defect on the sibling, and the source of the fix's shape.
  Its witness is one of this round's canary casualties
- L-16 — the detached `_processor.done` handler used to `await sub.cancel()`;
  the pump does not
