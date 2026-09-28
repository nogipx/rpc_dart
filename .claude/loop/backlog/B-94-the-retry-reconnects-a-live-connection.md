---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
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
