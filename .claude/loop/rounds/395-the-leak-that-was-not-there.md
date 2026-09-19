---
round: 395
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-84 — new
commit: yes
---

# Round 395 — the leak that was not there

## Target

The http2 responder past construction — the surface round 394 opened and the
owner named as uncovered. RPC-22: every guard on the accepted path has to be
asked of the REFUSAL path, because that is the one anyone reaches without
credentials.

## Hypothesis

Built from reading, and it was wrong — which is the round's result.

`_answerRejectedStream`'s own doc says a request refused in
`_handleIncomingHeaders` never reaches the pipeline: *"the responder pipeline
gets no state for the stream and never replies"*. And `_incomingStreams` and
`_outgoingPumps` are pruned in exactly one place — `releaseStreamId`, line 758-9
— which is the PIPELINE's call. Entries are created on line 336, the first
statement of `_handleIncomingStream`, before any validation.

So: a peer sending invalid requests should pin one entry per request, for the
life of the connection, with nothing to remove them.

## Before

200 requests on ONE connection, read from the server's own `health()` **while
the connection is still open**:

```
arm                      incomingStreams  streamSubscriptions  peer saw
open, never ended              200                200          -
half-closed, no body             0                  0          grpc-status 3
refused (:method GET)            0                  0          grpc-status 3
```

Probe:
`rpc_dart_http2/.dart_tool/probe/refused_streams_are_released.dart` (P-84).

**The refusal path releases its state.** The reading was wrong: `releaseStreamId`
is reached for a refused stream too, so the pump goes with it on the same line.

## Mechanism

n/a — nothing is broken.

What the reading missed is that "the pipeline has no state for this stream" does
not mean "the pipeline never calls back": the refusal ends the stream, and the
teardown that follows reaches `releaseStreamId` regardless of whether there was
a responder to clean up.

## After

n/a — no change made. `git diff --stat` empty before the verdict.

## Canary

n/a — no fix. The evidence is the bench's own sensitivity arm, and it took two
rebuilds to get there:

1. The first version read the counters **after** `conn.terminate()`. That runs
   the transport's `close()`, which clears every map, so both arms said 0 and
   the bench was measuring its own teardown. Moved the read before the tear-down.
2. The first "control" was a POST with no body — which the PIPELINE refuses for
   a different reason. Both arms came back `grpc-status 3`, so there was no
   served arm at all. The `grpc-status` column exists because of that: an arm
   that never reached the path it names cannot now read as a clean one.

The arm that makes the zeros mean something is `open, never ended`: 200 streams
the peer never half-closes, which legitimately stay live and read **200 / 200**.
Without it, "0" and "the counters do not work" are the same sentence
(measurement.md item 8).

## Gate

No library code moved, so round 394's gate stands.

## Not fixed

Nothing found. Two things this round leaves behind rather than fixing, both
recorded in C-46:

- **`_outgoingPumps` has no observable.** `health()` reports
  `incomingStreams`, `streamSubscriptions` and `streamParsers`, and the pump map
  is the one per-stream collection it does not count — so this round had to
  infer its fate from `releaseStreamId` removing both on the same line rather
  than measure it. C-37 counted 13 per-stream collections across four transports
  and this one is countable only by reading.
- The `open, never ended` arm shows 200 streams held with no transport-level
  ceiling in sight. That is by design — `maxActiveStreams` and
  `halfOpenStreamTimeout` are the pipeline's, and C-29 settled their scope — but
  it is the number an attacker-facing audit will keep arriving at.

## Links

- RPC-22 — the lens; `applied:` gains 395, status unchanged: a refusal path
  measured and found sound is the lens working, not the lens failing
- P-84 — the bench, and the two rebuilds it needed
- C-46 — the negative
- Round 394 — the construction-path defect on the same transport
- C-37 — the per-stream-collection audit this extends by one transport
- C-29 — why the open-stream ceiling is the pipeline's and not this layer's
