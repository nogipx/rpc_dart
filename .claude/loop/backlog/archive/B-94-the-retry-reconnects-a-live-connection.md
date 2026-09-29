---
status: closed (round 485)
round: 485
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-124
reason: "closed — the witness was built and CONFIRMED the lead: sockets 2 -> 1, and the unrelated call stopped being killed"
---

# B-94 — the retry interceptor reconnects on ANY unavailable, and a websocket reconnect kills every call on the socket

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_reconnectIfConnectionIsGone` checks nothing: any `RpcStatusException(unavailable)` — an application one, a drain refusal, one truncated stream — calls `transport.reconnect()`, and websocket's reconnect closes the LIVE socket, failing every other call on it.

## The shape

`packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart:149-160`:

```dart
Future<void> _reconnectIfConnectionIsGone(Object error, RpcMiddlewareContext call) async {
  if (error is! RpcStatusException) return;
  if (error.statusCode != RpcStatus.unavailable) return;
  try {
    await call.endpoint.transport.reconnect();
  } catch (_) {}
}
```

The name promises a check that is not there. `RpcWebSocketCallerTransport.reconnect()`
(`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:544+`) is unconditional: `_fwdSub.cancel()`,
`_inner.close()`, factory, `_attach`.

## Why it matters

UNAVAILABLE is not "the connection is gone". It is also a handler throwing
`RpcStatusException(unavailable)` (a downstream DB is down), the drain refusal
`Server is shutting down`, a single stream ending without a status
(`channel_transport.dart:975-980`), and `CircuitBreakerOpenException`. Each of
those, on one call, closes a working socket and fails every OTHER in-flight call
on it — and each of those failures is itself UNAVAILABLE, so N concurrent
retrying calls cascade into serial reconnects.

Round 414 (B-61) weighed "overloaded vs dead" and kept RESOURCE_EXHAUSTED out;
it did not weigh "one call failed, connection fine".

## Witness a round would build

Websocket pair with a reconnect factory, the retry interceptor on the caller.
Start a long server-stream call A; then a unary call B whose handler throws
`RpcStatusException(unavailable)`. Count: A's outcome, socket count at the
server (`onConnectionOpened`). Expected today: A fails, two sockets. Guard arm:
the same with B throwing RESOURCE_EXHAUSTED — A survives, one socket.

## Fix sketch

Reconnect only when the connection is actually gone: `transport.isClosed`, or a
`health()` level of `unhealthy`/`reconnecting`/`closed`, or an error type that
says so (`RpcNoConnectionException`, `RpcClosedException` from the transport).
Rename or keep the name honest.

## Owner decision

—

## Closed (round 485) — confirmed, and the witness ran as designed

The lead's own witness design was built (`P-124`) and every prediction in it
held: `A fails, two sockets` in the case arm, `A survives, one socket` in the
RESOURCE_EXHAUSTED guard arm.

```
                              sockets  A                B
case    unavailable    before    2     errored, 4 msgs  RpcStatusException
case    unavailable    after     1     alive,  30 msgs  RpcStatusException
control resourceExhausted        1     alive,  30 msgs  RpcStatusException
```

Fixed with the first option in the sketch, expressed through `health()` rather
than `isClosed`: the transport is asked whether IT is down, because the status
only ever described the call. `isClosed` alone would have been too narrow — a
websocket whose socket dropped reports `isClosed == false` and `degraded`, which
is exactly the case that must still reconnect.

**What the fix must not do is revert B-61**, so a third arm drives a path that
really died: `sockets=2, recovered` with the reconnect, `sockets=1,
RpcNoConnectionException` with it ablated.

The second half of the title — a websocket reconnect closing the live socket —
is NOT a defect and was left alone. Closing the socket is what a reconnect is.
