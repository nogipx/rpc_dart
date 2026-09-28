---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-108 — ping() bounds its wait only by `timeout:`, never by the context it was given

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The context deadline is pre-checked and sent as `grpc-timeout` but not enforced locally, and the token is only pre-checked — `ping(context: withTimeout(1s))` on a stalled connection never returns; the completer also lacks `.ignore()`, the pattern UnaryCaller fixed after it killed an isolate; RTT is measured on the wall clock.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart:293-366`: `throwIfCancelled()` and
`isExpired` once, then `RpcEndpointPingExchange.execute(timeout: timeout)`.
`ping.dart:200-221`: `RpcLongTimer.timeout` only `if (timeout != null)`.
`ping.dart` creates `completer` and awaits `sendMetadata` before anyone listens
to `completer.future` (compare `unary/caller.dart:136-156`). RTT is
`DateTime.now().toUtc()` minus `sentAt` (`:153`, `caller_pipeline.dart:302`).

## Why it matters

Ping is the keepalive; the case it exists for is the stalled connection, and that
is the case where it hangs. An error delivered to the stream while
`sendMetadata` is still awaiting completes an unlistened future — an unhandled
async error in the root zone. A wall-clock step makes the RTT negative or huge.

## Witness a round would build

Ping with `RpcContext.withTimeout(200ms)` against a responder that never answers
(drop the ping method's frames). Expected today: never returns.

## Fix sketch

Derive the local wait from the context deadline when `timeout` is null, listen to
the token, `completer.future.ignore()`, measure with a `Stopwatch`.

## Owner decision

—
