---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-176 — http2 caller: reconnect() cancels stream subscriptions without telling their consumers

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_discardConnection` then `await subscription.cancel()` for each; `terminate()` delivers per-stream errors asynchronously, so the first subscription is gone before its error arrives and its consumer waits out its deadline; `_streams`, `_fcOutstanding`, `_fcRefused`, `_resetStreams` are not cleared; parked `sendMessage` calls return as if sent.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:1779-1799`.

## Why it matters

Calls in flight at reconnect hang instead of failing fast.

## Witness a round would build

Three in-flight server-stream calls, `reconnect()`; time to error per call.

## Fix sketch

Fail each stream's router entry with UNAVAILABLE before cancelling; clear the
maps; make parked sends throw.

## Owner decision

—
