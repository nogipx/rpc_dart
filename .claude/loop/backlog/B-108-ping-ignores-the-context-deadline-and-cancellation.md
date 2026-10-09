---
status: closed (round 499)
round: 499
commit: d5cfdf8a
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
probe: P-137
reason: "closed — the deadline and token halves CONFIRMED (3003ms and 3002ms against a 3 s probe budget, now 204ms and 203ms) and all four items addressed"
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

## Closed (round 499) — two halves measured, all four items addressed

```
                              before    after
timeout: 200ms                 222ms     217ms   TimeoutException
context deadline 200ms        3003ms     204ms   TimeoutException
token cancelled at 200ms      3002ms     203ms   RpcCancelledException
nothing asked                 3002ms    3004ms   <- correct, see below
CONTROL, a peer that answers    32ms      20ms   ok
```

The 3 s rows are the probe's budget, not a library bound. The rig swallows ONLY
the ping frame, so nothing ends that stream and each arm is a statement about the
caller's own bound.

**A deadline SENT is not a deadline ENFORCED**, which is why this was easy to
miss: the `grpc-timeout` header made the intent visible on the wire and bounded
the server, so everything about the call said 200 ms except the code that waits.

Fixed as the sketch says, all four:

- `timeout ?? routingContext.remainingTime` — the explicit argument still wins.
- `execute` takes a `cancellationToken`, completes `RpcCancelledException`, and
  cancels that subscription in the same `finally` as the stream's.
- `Stopwatch` for the round trip; `sentAt`/`receivedAt` stay on the result because
  they are what went on the wire.
- `completer.future.ignore()` before the awaited send.

**The clock half has a real witness after all**: `sentAt` is a constructor
parameter, so injecting an hour in the past stands in for a wall-clock step, and
the ablation reads `1:00:00.012557`.

**`.ignore()` is the one change with no failing test behind it** — the race needs
an error arriving while `sendMetadata` is still awaiting, which nothing here can
drive. Shipped because the pattern is established in `UnaryCaller`, where the cost
was a dead isolate.

Deliberately unchanged: a ping with NO bound requested still waits forever. A
guard pins it, because inventing a bound would answer B-107's policy question by
the back door.

## Owner decision

—
