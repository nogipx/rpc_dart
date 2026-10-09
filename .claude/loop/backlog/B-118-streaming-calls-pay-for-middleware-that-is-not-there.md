---
status: closed (round 509)
round: 509
commit: 61b4205a
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: P-147
reason: "closed — the middleware half is CONFIRMED and fixed: ~1.03 us per message, 19%, for wrapping a stream to apply an empty list. The other layers named here are untouched and are where the remaining ~4.4 us lives; closed rather than split because they are a different change with no measurement behind them yet"
---

# B-118 — streaming calls wrap every message in several async* layers even with no middleware

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_applyRequestMiddlewaresToStream`/`_applyResponseMiddlewaresToStream` are `async*` loops awaiting an async function per message even when `_middlewares` is empty; on top sit `handleServerStream` (async*), `_withHandlerSlotStream` (async*), `StreamBridge`, `_bridgeCallerResponses` and, for bidi, a controller plus `.transform`; StreamProcessor/CallProcessor also push every message into a controller only a no-op listener reads.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart:294-310`, `:482-587`;
`responder_pipeline.dart:206-218`; `caller_pipeline.dart:602-779`;
`base_processor.dart:196, 322-336, 693` (`_responseController`) and
`:914, 1047-1083, 1643` (`_requestController`).

## Why it matters

Several microtask hops and allocations per message per layer. These async*
layers are also the source of the dart2js cancel problems that the bridges were
later added to work around.

## Witness a round would build

Server-stream of 1M tiny messages over the in-memory pair, zero middleware; time
before and after a fast path.

## Fix sketch

Return the stream unchanged when there are no middlewares; replace the no-op
controllers with a direct call; collapse the bridge stack.

## Outcome (round 509) — the middleware half

**CONFIRMED and fixed.** Server stream of 10 000 tiny messages, run-set minima:

```
always wrapped      5.647 / 5.582 / 5.456           us/message
bypassed if empty   4.438 / 4.564 / 4.419 / 4.520   us/message
```

About 1.03 us per message, ~19%. Round 505 had given the SCALAR helpers an `isEmpty`
early return, which removed the work inside the loop but not the loop — the `async*`
still iterated an empty list once per message.

**It changes a contract**, stated as a test rather than left to be found: the
middleware set is now fixed when the stream is BUILT, so one added mid-stream does
not join the call. That matches interceptors, whose chain is built once and
synchronously at call start. Round 505's record had noted the per-message re-read as
preserved-not-decided; this is the decision.

**Seven run sets were needed to say this.** Two read `4.710` against `5.763` medians
and looked settled; the next fixed set's median was `5.949`, which would have
reversed it. The minima never overlap and are the right statistic, since noise here
only adds time.

## Split out to B-204 — not measured, a different change

The remaining ~4.4 us per message lives in the layers this lead also names, none of
which were varied: `handleServerStream`, `_withHandlerSlotStream`, `StreamBridge`,
`_bridgeCallerResponses`, the bidi controller and its `.transform`, and the
`StreamProcessor`/`CallProcessor` controllers that only a no-op listener reads.

The lead also ties these to the dart2js cancel problems the bridges were added to
work around — so collapsing the bridge stack is not only a cost question, and
whatever touches it owes the web target a measurement.

Closed rather than left open, because what remains is a different change with no
measurement behind it yet; it should be filed fresh when someone has one.

## Owner decision

—
