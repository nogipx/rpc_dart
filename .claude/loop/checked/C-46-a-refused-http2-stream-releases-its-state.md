---
round: 395
commit: 8e47a55b
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
scope: [rpc_dart_http2]
---

# C-46 — a refused HTTP/2 stream releases its transport state

> **Read the scope line before reusing this.** It covers ONE of the two refusal
> sites. Round 397 drove the other — `_answerFramingViolation`, reached when a
> DATA frame fails the parser — and it did NOT release: 200 answered streams
> holding 200 of every per-stream collection. This record's own "what this does
> NOT cover" named that site; the gap lasted two rounds.

RPC-22 asked of the http2 responder: a request refused in
`_handleIncomingHeaders` — before the pipeline ever sees it — does it leave
per-stream state behind?

It does not. 200 requests on ONE connection, read from the server's `health()`
**while the connection is still open**:

```
arm                      incomingStreams  streamSubscriptions  peer saw
open, never ended              200                200          -
half-closed, no body             0                  0          grpc-status 3
refused (:method GET)            0                  0          grpc-status 3
```

The reading that prompted it was wrong, and is worth recording so nobody
re-derives it: `_incomingStreams[streamId]` is set on line 336, the first
statement of `_handleIncomingStream`, before any validation; and both that map
and `_outgoingPumps` are pruned in one place only, `releaseStreamId`, which is
the PIPELINE's call. `_answerRejectedStream`'s doc says the pipeline gets no
state for a refused stream. All true — and the refusal still ENDS the stream,
and the teardown that follows reaches `releaseStreamId` whether or not there was
a responder to clean up.

## Control

`open, never ended` — 200 streams the peer never half-closes, which legitimately
stay live and read 200 / 200. Without it "0" and "the counters do not work" are
the same sentence.

And a `grpc-status` column on every arm, because the first attempt at a control
was a POST with no body, which the PIPELINE refuses for its own reason: both
arms came back `grpc-status 3` and there was no served arm at all. An arm that
never reached the path it names must not be able to read as a clean one.

## What this does NOT cover

- **`_outgoingPumps` has no observable.** `health()` counts `incomingStreams`,
  `streamSubscriptions` and `streamParsers`; the pump map is the one per-stream
  collection it does not report, so its fate here is inferred from
  `releaseStreamId` removing both on the same line, not measured. Worth a field
  the next time this file is open.
- Refusals from the OTHER rejection sites — `validateMetadata`, content-type,
  the policy-violation backstop at 256. Only `:method != POST` was driven.
  `_answerFramingViolation` was the fourth of these and is now covered by round
  397, which found it broken.
- A peer that refuses to READ its own refusal: the trailer goes out through the
  outgoing pump, which waits on the peer's window. Not measured here.
- Anything about the pipeline's own limits; `maxActiveStreams` and
  `halfOpenStreamTimeout` are its, and C-29 settles their scope.

Re-run when the responder changes how a stream ends, not on a schedule.
