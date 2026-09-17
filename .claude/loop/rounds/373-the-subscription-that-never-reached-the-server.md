---
round: 373
verdict: FIXED
packages: [rpc_dart]
lens: RPC-20
bench: P-64 — new
commit: yes
---

# Round 373 — the subscription that never reached the server

## Target

The second half of the owner's bidi goal. Round 372 took the LEAK question and
came back clean; this round takes **correct handling** — whether the two
directions are genuinely independent, which is the one property bidi exists for.

RPC-20, *the window before the first listener*: its shape is a party that has
not started yet swallowing what the peer sent, and it fails OPEN, so the loss
reads as "the peer does not support this". Here the party is the call itself.

## Hypothesis

With one direction idle, the other does not work.

## Before

```
case                                  caller got   ending
server pushes, client never sends          0       HANG
CONTROL same, client closes at once        5       DONE
server ends first, client holds open       0       HANG
server outlives the half-close            10       DONE   (handler saw 3)
full duplex, 30 each way                  30       DONE   order PRESERVED
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/bidi_duplex_semantics.dart`
(P-64).

**The control is one line of the caller's own code** — the same handler driven
with `Stream.empty()` instead of a request stream that never closes. `5 DONE`
against `0 HANG`, differing by exactly whether the request stream CLOSES. That
is what named the trigger: the half-close, not the payload.

The natural shape of a bidirectional call is a SUBSCRIPTION — open the channel,
listen, maybe send something later. That call did not reach the server at all.

## Mechanism

**Two hops, and instrumenting both at once is what separated them (L-07).** The
probe samples the server while the call is in flight, because "the caller got
nothing" cannot distinguish *the responder never heard of this call* from *it
answered and the answer was lost*:

```
                openStreams  responders  metadataStreams
before                0           0             0
after hop 1           1           0             1
after hop 2       call completes
```

- **Hop 1, the caller.** Initial metadata is sent by the first request or by the
  half-close. A subscription does neither, so the call was never announced.
  `CallProcessor.finishSending` already carries a comment about exactly this
  failure — it was fixed for the zero-message call that DOES half-close, and the
  one that does not was left behind.
- **Hop 2, the pipeline.** The responder is dispatched from `_handleDataMessage`
  and `_handleEndOfStream`. A subscription reaches neither, so the handler never
  ran even once the server knew the stream existed.

Had only the caller's counters been read, hop 1 would have looked like the whole
defect and the round would have shipped a fix that still hangs.

## After

```
case                                  caller got   ending
server pushes, client never sends       0 -> 5      DONE
server ends first, client holds open    0 -> 1      DONE
CONTROL, outlivesHalfClose, duplex        unchanged
```

`BidirectionalStreamCaller` announces the call in its constructor; the pipeline
dispatches a bidirectional responder on the METADATA frame, last in
`_handleMetadataMessage` so a replayed frame dispatches first
(`_ensureResponder` is idempotent and reaches its assignment with no await).

Scoped to bidi deliberately: the other three shapes are guaranteed to send a
request frame or a half-close, so dispatching them on metadata would change a
path that is not broken.

**P-63 re-run after the fix**: all seven endings still zero on all eleven
counters. The earlier dispatch creates a responder sooner, and it does not leak.

## Canary

Two, because the fix has two halves (canary.md item 5), each switched off in
place. **Both produce the same three red witnesses**, which is the right result
for two hops in series — either one alone leaves the call unreachable:

    a caller that never sends still receives
      the call never reached the server: ... both the initial metadata and the
      responder dispatch were waiting for one of those
    the server may end the call first
      the caller never saw the end of a call the server finished
    the server hears the call before any request
      the handler never started for a caller that had not sent anything

The GUARD — zero messages WITH a half-close, the neighbouring case that already
worked — stayed green under both canaries, so the witnesses measure the new
defect and not the feature.

**These failures are timeout-shaped**, which `canary.md` item 2 names as the
weak form, and it is not avoidable here: the defect IS a call that never
happens, and "it did not happen" can only be observed by waiting. Each carries a
real diagnostic through `fail(...)` rather than a bare `Test timed out`. The
third witness asserts an EVENT at the peer (the handler completing a completer)
rather than polling a gauge (L-11).

Witness: `test/streams/bidi_subscription_opens_the_call_test.dart`, 4 cases.

## Gate

All four green: `melos run analyze`, `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check`. In the changed package
`fvm dart analyze lib` clean, `fvm dart test -j 8` **+1535 ~1** (the pipeline is
shared by all four shapes, so the whole suite is the regression check). Runs
paced.

## Not fixed

**A caller that sends after the server has finished** is not covered — that is
B-50's question, asked of client-stream, and the same answer will apply here.

**Ordering under latency.** Full duplex preserved order over 30 messages each
way on the in-process pair, which flattens anything made of a round trip
(P-58's lesson). The ordering claim is therefore about the pipeline, not about
the wire.

## Links

- RPC-20 — the lens; `applied:` gains 373, status `confirmed (round 373)`
- P-64 — the bench; the control is one line of the caller's own code
- P-63 — re-run after the fix, still zero on every ending
- Round 372 — the leak half of the same goal
- L-07 — instrument every hop at once; it is what found the second one
- `bidi_empty_request_stream_test.dart` — the neighbouring case, which is the GUARD
