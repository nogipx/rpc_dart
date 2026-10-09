---
file: packages/core/rpc_dart/.dart_tool/probe/b96_second_headers.dart
round: 487
commit: 7764b081
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
status: valid
---

# P-126 — what a second opening frame detaches

## Why it exists

Five things stop a running handler — `_abortActiveStreams`,
`closeResponderResources`, `_runDrain`, `_handleClientCancellation`,
`_onDeadlineExceeded` — and every one reads
`state.cachedContext?.cancellationToken`. The bench asks whether a peer can make
that field point somewhere else while the handler is running.

## The harness

A channel pair, a bidi handler that registers a disposer on `context.callScope`
and then awaits `context.cancellationToken.cancelled`. Open the call, send the
SAME metadata frame again, then `drain()` the responder.

Two counters, both incremented from inside the handler's own closure: did it
observe the cancel, and did its disposer run.

A second arm drives the ping path, which the lead also names.

## The numbers (round 487)

```
                        handler saw the cancel   disposer ran
second HEADERS  before            0                   0
second HEADERS  after             1                   1
nothing extra (control)           1                   1

ping, second HEADERS      frames on the stream id: 2 -> 4
ping, nothing extra                                2 -> 2
```

## Measures

Two booleans counted inside the handler, so they report what the HANDLER
observed rather than what the pipeline believes it sent. For the ping arm, the
number of frames the client transport receives for that stream id.

## Control

The same rig with the second frame not sent, which reads 1/1 — so the bench can
tell a cancelled handler from an un-cancellable one, and the zero is the frame's
doing.

**The ping arm needed its instrument corrected before it could see anything.**
Counting on `getMessagesForStream(id)` read `2 -> 2` in BOTH arms, including
with the fix ablated: that controller closes when the ping ends, so a second
answer lands on a closed sink. Counting on `incomingMessages` filtered by id
reads `2 -> 4`. A zero on the first instrument would have been reported as a
refuted claim.

## What it establishes, and what it does not

Establishes: one repeat opening frame detached the running handler from every
mechanism that can stop it, and the guard restores all of them.

Does NOT establish that the ping double-answer has the same cause — it does not.
By the time the second frame arrives the ping's stream state is already cleaned
up, so `hasMethod` is false and the frame opens what looks like a new call on a
reused id. The guard does not apply and the `2 -> 4` is unchanged by it.

## Reading

rpc_dart — counts two things from INSIDE the handler's own closure (did it
observe its cancel, did its disposer run), so the numbers say what the handler
saw rather than what the pipeline believes it sent. **Its second arm is a
worked example of an instrument that reads zero for the wrong reason**:
counted on `getMessagesForStream(id)` the repeat-ping arm reads `2 -> 2` in
both arms AND with the fix ablated, because that controller closes when the
ping ends; counted on `incomingMessages` filtered by id it reads `2 -> 4`
