---
status: closed (round 508)
round: 508
commit: 5fa2b280
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-146
reason: "closed — CONFIRMED on both halves, with the lead's two claims the wrong way round: the dispatch cost is ~6%, the retention is 1001 already-consumed responses held for a listener that may never arrive. Skipped for locally-initiated routed streams; the websocket half is untouched"
---

# B-117 — the channel transport broadcasts every frame, including responses already routed per stream

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_incoming.add(message)` runs for every inbound message after it was routed to the stream's controller; a caller-only endpoint then needs a no-op subscription (`startCallerListening`) purely so the buffered broadcast does not fill — work added to compensate for work that should not happen; websocket adds a second broadcast on top.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart:956-958`; `caller_pipeline.dart:29-64`
("this subscription exists to keep the buffer drained"). `websocket_caller_transport.dart:334-346`
re-broadcasts into `_incomingCtl` with a set lookup per message.

## Why it matters

One or two extra broadcast dispatches per response message on every client; the
design makes a missing no-op listener a memory leak.

## Witness a round would build

Messages/s for a server stream of small messages, websocket client, before and
after skipping the broadcast for locally-initiated stream ids.

## Fix sketch

Broadcast only frames that open or advance a PEER-initiated stream (and errors);
route the rest per stream only.

## Outcome (round 508)

**CONFIRMED on both halves — and the lead states them in the wrong order.** It leads
with the dispatch cost and mentions the leak second; the measurement puts the leak
first by a wide margin.

**Retention**, with the caller's observer detached, after a server stream is FULLY
consumed and a late subscriber attaches:

```
                            before   after
  10 messages consumed        11       0
 100 messages consumed       101       0
1000 messages consumed      1001       0
```

(the extra one is the trailer.)

**Speed**, 10 000 small messages, five runs each:

```
always broadcast     min 5.805   median 5.987   max 6.154 us/message
skip when routed     min 5.481   median 5.604   max 5.875 us/message
```

About 6%, with the ranges barely separated. **A first, single-run comparison read
16%** and a second arm in the same run moved the wrong way; printing the
distribution is what corrected it. Next to ~6 us per message this is a rounding
error, and "one or two extra broadcast dispatches per message" reads as the dominant
term when it is not.

Fixed as the sketch says: broadcast only what is not already routed to a
locally-initiated stream, by id parity. Errors are untouched — `_incoming.addError`
is a different path — so `startCallerListening` is still needed for its
error-observing half, just not to drain routed responses.

## Split out to B-203 — not measured here

**The websocket transport's second broadcast**, which this lead also names:
`websocket_caller_transport.dart` re-broadcasting into `_incomingCtl` with a set
lookup per message. Only the core channel transport was varied.

**Whether the broadcast should carry errors at all.** With the message half no
longer needed by a caller, `startCallerListening` exists purely to observe errors —
two responsibilities on one stream. Separating them is a design question with no
measured failure behind it.

## Owner decision

—
