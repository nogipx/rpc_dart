---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: none — static read, nothing run
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

## Owner decision

—
