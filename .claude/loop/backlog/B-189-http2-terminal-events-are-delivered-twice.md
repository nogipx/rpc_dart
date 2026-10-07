---
status: closed (round 667) — by owner decision, 2026-10-07
round: 667 (measured, not fixed)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/b189_terminal_events.dart
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-189 — http2: terminal events delivered twice; self-cancellation logged at error; late RST after release

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Trailers emit end-of-stream and `onDone` emits another (caller `:1164, 1374`; responder `:376, 649`); after `onError`, `onDone` can add a synthesised UNAVAILABLE; `onError` logs ERROR before checking `_resetStreams`, so every own cancel is an error record; the responder does not clear `onTerminated` in `releaseStreamId`, so a late RST emits an `x-client-cancelled` frame for a released id.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1077, 1164, 1374, 1585`;
`rpc_http2_responder_transport.dart:354-418, 649`.

## Why it matters

Noise for broadcast consumers and logs; the late cancel frame reaches the
pipeline for an id it may have reused.

## Witness a round would build

Count events on the broadcast for one ordinary call.

## Fix sketch

Emit one terminal event; check `_resetStreams` before logging; clear
`onTerminated` on release.

## What round 667 measured

Real endpoints on both sides, both broadcasts tapped:

```
one unary call      end-of-stream events: caller 2, responder 2   claim 1 CONFIRMED
bidi, server ends   responder cancel frame for the released id 1  claim 4 CONFIRMED
own resetStream     caller ERROR records +0                       claim 3 REFUTED
```

Claim 3 is refuted because `resetStream` cancels the subscription before the
reset can surface as an error. Claim 2 is unmeasured. Neither confirmed claim
has shown a consequence yet: the per-stream router closes on the first end, and
the released id's cancel frame reached a pipeline that holds nothing for it (no
warning, every transport map at 0). The next round owes the consequence, not the
count.

While measuring this, round 667 found and fixed a different defect: an error
about one stream on the broadcast failed every call beside it.

## Owner decision

2026-10-07, after round 695: **close** -- two ends per call are confirmed, but
no consequence was found, so nothing is changed.
