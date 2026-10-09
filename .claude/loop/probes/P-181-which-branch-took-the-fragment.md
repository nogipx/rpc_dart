---
file: packages/core/rpc_dart/.dart_tool/probe/b126_where_the_fragment_goes.dart
round: 553
commit: 67db727b
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-181 — which branch took the fragment?

## Why it exists

Attempt 3 reached a state where the first fragment was awaited and a mid-frame
half-close was answered, and a fragmented request STILL timed out. The arms said
"status 4" and nothing more. Five code paths could have taken the second fragment
and none of them logs a decision an outside observer can distinguish.

**A status is the end of a story, and the question was where the story went.**

## The harness

The fragmenting channel from the lead's witness, plus a `LogController` subclass
printing every record the pipeline decides to emit, filtered to the frame and
lifecycle lines so the output is readable. Each inbound frame is announced with its
size and end-of-stream flag before the pipeline sees it.

The subclass overrides `add` on the CONTROLLER, not `LogScope` — `child()` returns a
plain `LogScope`, so a scope subclass loses its override the moment the pipeline
derives one (the trap CLAUDE.md records and `b124_peer_warning_flood` paid for).

## What it printed (round 553)

```
  SPLIT stream 1: 74 bytes -> 37 + 37, eos on the second: true
  inbound [streamId: 1] method=/Svc/echo metadata=true payload=0 endOfStream=false
  Handling request for /Svc/echo [streamId: 1]
  Parsing request frame of 37 bytes [streamId: 1]
  Request frame incomplete, awaiting the rest [streamId: 1]
  inbound [streamId: 1] method=- metadata=false payload=37 endOfStream=true
  Handling request for /Svc/echo [streamId: 1]
  Parsing request frame of 37 bytes [streamId: 1]
  Clearing state for stream 1
  Skipping a stale cleanup for stream 1: the id now names another call
  RESULT status 4: Deadline exceeded
```

**The second fragment WAS delivered and WAS parsed, and no response followed.** That
is what the statuses could not say, and it moves the question from "where did the
fragment go" to "what silently dropped the answer after a successful parse".

The answer is in the two lines after the parse: the only silent exit in that method
is a CLOSED responder, and the stale-cleanup notice says something had already torn
the stream down. The pipeline's end-of-stream branch fired while the fragment was
still being processed, because it keyed on the pipeline's own "awaiting" flag — true
for the whole feed, including while the handler runs.

## Measures

Nothing numeric. It establishes ORDER and ATTRIBUTION: which frames arrived, in what
sequence, which branch logged about each, and where a path went quiet.

## Control

The whole-frame run through the same tracer, where the sequence is
`Handling -> Parsing -> Served`. The absence of `Served` is only informative against
a run that has it.

## What it establishes, and what it does not

Establishes that a delivered-and-parsed fragment produced no answer, and names the
window in which the responder was closed — which is what reduced the problem to one
predicate.

Does NOT prove the predicate was the cause; the canary does. It also cannot see a
decision nothing logs, which was the original difficulty: the two guard clauses that
return silently are invisible here and were found by elimination.

## Reading

rpc_dart — **a TRACER, not a measurement**: it prints every record the
pipeline decides to emit, in order, with each inbound frame announced before
the pipeline sees it. Built because three read statuses said `status 4` and
none said which of five paths took the second fragment of a split frame. What
it showed was the fragment delivered AND parsed with no answer after it —
which moved the question from routing to "what silently dropped the answer",
and the only silent exit there is a closed responder. The subclass overrides
`add` on the CONTROLLER, since `child()` returns a plain `LogScope` and a
scope subclass loses its override the moment the pipeline derives one. Cannot
see a decision nothing logs: the two silent guard clauses were found by
elimination, not here.
