<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Errors and resilience

This covers the error types, what reaches the peer, structured error details, and the client-side
tools: retry, circuit breaker, rate limiter and reconnecting connection.

## Rules

- To tell the caller something, throw `RpcStatusException(statusCode, message,
  {details})` with a constant from `RpcStatus`. Nothing else keeps its status.
- `RpcException` is the base type. Its constructor is `const RpcException(this.message)`: it has a
  message only, with no code and no details. Catch `RpcException` to mean "came from rpc_dart".
  Throw `RpcStatusException` or one of its subclasses.
- On the caller, a server-sent error ALWAYS arrives as a plain
  `RpcStatusException`. Branch on `e.statusCode`, not on subtype. Only
  errors raised on the caller itself keep their subtype:
  `RpcCancelledException`, `RpcDeadlineExceededException`,
  `CircuitBreakerOpenException`, `RpcClosedException`,
  `RpcNoConnectionException`, `RpcMetadataViolation`.
- Interceptors are attached with `endpoint.addInterceptor(...)`. The first one added is
  the OUTERMOST.

## What reaches the peer (`wireStatusFor`)

| Thrown by handler | Status on the wire | Message on the wire | Details |
| --- | --- | --- | --- |
| `RpcStatusException` or a subclass | its `statusCode` | its `message` | its `details` |
| other `RpcException` | `INTERNAL` (13) | its `message` | none |
| anything else (`StateError`, `Exception`, ...) | `INTERNAL` (13) | `'Internal server error'` | none |

The real cause of a redacted error is logged on the server only. If the trailer carries no
message, the caller shows `'Unknown error'`. The message is percent-encoded and
cut to 1024 encoded characters.

```dart
import 'package:rpc_dart/rpc_dart.dart';

Future<String> getUser(String id, {RpcContext? context}) async {
  if (id.isEmpty) {
    throw RpcStatusException(
      RpcStatus.invalidArgument,
      'id is required',
      details: [
        RpcBadRequest([
          const RpcFieldViolation(field: 'id', description: 'must be set'),
        ]),
      ],
    );
  }
  throw RpcStatusException(
    RpcStatus.notFound,
    'user $id not found',
    details: [RpcErrorInfo(reason: 'USER_NOT_FOUND', domain: 'users.v1')],
  );
}

Future<void> callIt(RpcCallerContract api) async {
  try {
    await api.callUnary<String, String>(methodName: 'getUser', request: '42');
  } on RpcStatusException catch (e) {
    if (e.statusCode == RpcStatus.notFound) {
      final info = e.details.whereType<RpcErrorInfo>().firstOrNull;
      print('${e.message} ${info?.reason}');
    }
  }
}
```

## Status constants and helpers

`RpcStatus` is a set of `int` constants: `ok` 0, `cancelled` 1, `unknown` 2,
`invalidArgument` 3, `deadlineExceeded` 4, `notFound` 5, `alreadyExists` 6,
`permissionDenied` 7, `resourceExhausted` 8, `failedPrecondition` 9, `aborted`
10, `outOfRange` 11, `unimplemented` 12, `internal` 13, `unavailable` 14,
`dataLoss` 15, `unauthenticated` 16. `RpcStatus.isFault(code)` is true for
UNKNOWN, INTERNAL, UNAVAILABLE and DATA_LOSS. `RpcStatus.isFaultError(e)` is also true for any error that is not an
`RpcStatusException`.

## Error details (`grpc-status-details-bin`, `google.rpc.Status`)

| Class | Constructor |
| --- | --- |
| `RpcErrorInfo` | `RpcErrorInfo({required reason, domain = '', metadata = const {}})` |
| `RpcBadRequest` | `RpcBadRequest(List<RpcFieldViolation>)` |
| `RpcFieldViolation` | `const RpcFieldViolation({required field, required description})` (not a detail itself) |
| `RpcRetryInfo` | `RpcRetryInfo(Duration retryDelay)` |
| `RpcDebugInfo` | `RpcDebugInfo({stackEntries = const [], detail = ''})`. It IS sent to the peer, so never include internals |
| `RpcRawErrorDetail` | `RpcRawErrorDetail({required typeUrl, required value})`. Unknown detail types decode to this |

`RpcStatusException.atCapacity(message)` gives RESOURCE_EXHAUSTED plus
`RpcRetryInfo(Duration.zero)`. Use it for limits that clear by themselves
(concurrency, queue depth), so that retry policies treat the error as transient. A
plain RESOURCE_EXHAUSTED means "too big" and is never retried.

## Built-in exception types

| Type | Status | Notes |
| --- | --- | --- |
| `RpcCancelledException(message)` | CANCELLED | `reason` == `message` |
| `RpcDeadlineExceededException(deadline, timeout)` | DEADLINE_EXCEEDED | not const |
| `RpcClosedException(what, {detail})` | FAILED_PRECONDITION | this side closed it; `byPeer == false` |
| `RpcClosedException.byPeer(what)` | UNAVAILABLE | peer went away; `byPeer == true` |
| `RpcNoConnectionException(what, reconnecting:)` | UNAVAILABLE | no live connection |
| `CircuitBreakerOpenException({retryAfter})` | UNAVAILABLE | thrown by the breaker on the caller |
| `RpcRateLimitException(message, {retryAfter})` | RESOURCE_EXHAUSTED | carries `RpcRetryInfo` when `retryAfter` is set |
| `RpcMetadataViolation` | INVALID_ARGUMENT | also `implements ArgumentError` |
| `RpcFrameException` / `.limit` / `.policy` | INTERNAL / RESOURCE_EXHAUSTED / INVALID_ARGUMENT | malformed or oversized frames |

## Retry: `RpcRetryInterceptor` (caller)

```dart
import 'package:rpc_dart/rpc_dart.dart';

void configure(RpcCallerEndpoint caller) {
  caller
    ..addInterceptor(RpcCircuitBreakerInterceptor(failureThreshold: 5))
    ..addInterceptor(
      RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: const ExponentialBackoff(
          baseDelay: Duration(milliseconds: 200),
          maxDelay: Duration(seconds: 5),
        ),
      ),
    );
}
```

- UNARY calls only. All streaming shapes pass through without retry.
- `maxAttempts` counts the first call and must be >= 1 (otherwise `ArgumentError`). The defaults are 3 attempts and
  `ExponentialBackoff(baseDelay: 200 ms, maxDelay: 5 s)`.
- What the default predicate retries: UNAVAILABLE; RESOURCE_EXHAUSTED only with pushback
  (`RpcRetryInfo` detail or `RpcRateLimitException`). Never retried: cancellation,
  deadline exceeded, a context with no time left, INTERNAL, INVALID_ARGUMENT, a
  bare `RpcException`, non-RPC errors. `retryOn: (error) => ...` REPLACES the
  default predicate, but never overrides the cancellation and deadline rules.
- It never sleeps past the deadline. If the next delay is longer than `remainingTime`, the last error is
  rethrown immediately. A cancel during backoff ends the wait.
- On UNAVAILABLE it calls `transport.reconnect()` before the next attempt, but only
  if `transport.health()` reports unhealthy.
- ONLY for idempotent methods: a lost response is also UNAVAILABLE, so a call
  may have been executed more than once. Deduplicate on the server with `context.requestId`.

## Backoff

`BackoffPolicy` is abstract, with one method: `Duration delayFor(int attempt)` (attempt is 0-based).
`ExponentialBackoff({baseDelay = 1 s, maxDelay = 60 s, jitter = true})`:
`baseDelay * 2^attempt`, capped at `maxDelay`. With jitter, the delay is uniform in (0, cap].
`FixedBackoff(Duration delay)`. To build a custom policy, extend `BackoffPolicy`.

## Circuit breaker: `RpcCircuitBreakerInterceptor` (caller)

`RpcCircuitBreakerInterceptor({failureThreshold = 5, resetTimeout = 30 s,
failureOn, probeAbandonTimeout = 30 s})`. Covers all four call shapes.

- closed -> open after `failureThreshold` CONSECUTIVE counted failures. Any success resets
  the count.
- open: calls fail at once with `CircuitBreakerOpenException(retryAfter: remaining time)`.
  Streaming calls get it as a stream error.
- After `resetTimeout`, the state is half-open: exactly one probe call is admitted, and other calls get
  `CircuitBreakerOpenException`. If the probe succeeds the circuit closes; if it fails, the circuit opens again.
- Failures counted by default: UNAVAILABLE, INTERNAL, UNKNOWN, DEADLINE_EXCEEDED,
  RESOURCE_EXHAUSTED with pushback, and any error that is not an `RpcStatusException`.
  Cancellation is never counted. `failureOn` replaces the default set.
- Inspect with `state` (`CircuitBreakerState.closed/open/halfOpen`) and `failureCount`. Use `reset()` to close it manually.
- Add it BEFORE the retry interceptor, so it is outermost: then an open circuit fails
  fast instead of being retried, and one logical call counts once.

## Rate limiting: `RpcRateLimiter` (responder)

```dart
import 'package:rpc_dart/rpc_dart.dart';

void limit(RpcResponderEndpoint responder) {
  const second = Duration(seconds: 1);
  responder.addInterceptor(
    RpcRateLimiter(
      global: const RateLimit.slidingWindow(max: 5000, window: second),
      perService: {'Search': const RateLimit.slidingWindow(max: 50, window: second)},
      perMethod: {'Sync.push': const RateLimit.tokenBucket(max: 10, window: second, burst: 20)},
      perKeyFallback: const RateLimit.slidingWindow(max: 100, window: second),
      keyExtractor: (call) => call.context.getHeader('x-user-id'),
    ),
  );
}
```

- `RateLimit.slidingWindow({max, window})` (strict, no burst) and
  `RateLimit.tokenBucket({max, window, burst})` (`burst` defaults to `max`).
  A `max` or `window` <= 0 throws `ArgumentError` when the limiter is constructed.
- `perMethod` keys are `'Service.method'` (with a dot). `perService` keys are service names.
- `global` is a CEILING that is always charged. Each call is also charged against the first matching one of
  `perMethod` > `perService` > `perKeyFallback`. Both must admit the call.
- With `keyExtractor`, each key gets its own per-service, per-method and fallback counters. A
  `null` key charges `global` only. Without `keyExtractor`, `perKeyFallback` is not used.
- Each call is charged once when it is established. Client-stream and bidi calls are also charged per inbound message,
  where the first message is already paid for. For server streams, charging per message is opt-in with
  `meterServerStreamMessages: true`.
- A refusal throws `RpcRateLimitException` (RESOURCE_EXHAUSTED + `RpcRetryInfo`),
  which the caller's default retry predicate treats as transient.
- Other parameters: `maxTrackedKeys` (100000, LRU), `cleanupInterval`, `nowMicros`
  (inject a fake clock in tests). Call `dispose()` at shutdown.

## Reconnecting client: `RpcClientConnection`

```dart
import 'package:rpc_dart/rpc_dart.dart';

RpcCallerEndpoint connectWithRetry(
  Future<IRpcReconnectableTransport> Function() open,
) {
  final connection = RpcClientConnection(
    transportFactory: open,
    backoff: const ExponentialBackoff(maxDelay: Duration(seconds: 30)),
    maxAttempts: 10,
    connectTimeout: const Duration(seconds: 5),
    shouldReconnect: (error) => true,
    onStateChanged: (state) => switch (state) {
      RpcClientOnline() => print('online'),
      RpcClientConnecting(:final attempt) => print('connecting #$attempt'),
      RpcClientOffline() => print('dropped, reconnecting'),
      RpcClientDisconnected(:final reason) => print('gave up: $reason'),
      RpcClientIdle() => print('idle'),
    },
  );
  connection.connect(); // returns void; watch `state` / `currentState`
  return RpcCallerEndpoint(transport: connection.transport);
}
```

- Create the endpoint ONCE on `connection.transport`. It stays valid across reconnects.
- The factory must return `Future<IRpcReconnectableTransport>`.
  `RpcChannelTransport` implements it.
- `connect()` returns `void` and does not wait for the connection. A call made before the state is
  `RpcClientOnline` fails with `RpcNoConnectionException` (UNAVAILABLE).
- Other members: `state` (a broadcast stream), `currentState`, `forceReconnect()`, `disconnect()`
  (resume later with `connect()`), `dispose()` (permanent).
- When the state is `RpcClientDisconnected(reason)`, the connection has stopped trying. Call `connect()` to start again.
- A connection that drops within 5 s of coming online counts as a failed attempt, so `maxAttempts` and the backoff
  still apply to a server that accepts and then refuses. One that held up longer starts the count over.
- `connection.transport.reconnect()` starts nothing: it waits, up to 5 s, for the outcome of the connection's next
  attempt. So `RpcRetryInterceptor` on an endpoint over `connection.transport` retries after a real connect, not in
  the backoff's gap, and the connection keeps its own backoff however many calls are retrying.
- Calls that are in flight during a drop are lost. Issue them again.

## Pitfalls

- These do NOT exist: `RpcException(code:, message:, details:)`, `e.code`,
  `RpcTimeoutException`, `RpcTransportException`, `StatusCode`,
  `BackoffPolicy.exponential(...)`, `RpcClientConnection(reconnectPolicy:)`,
  `RpcRateLimiter(maxRequests:, window:)`.
- `on RpcCancelledException` does not catch a CANCELLED status sent by the server. Check
  `e.statusCode == RpcStatus.cancelled`.
- A handler that throws `Exception('user not found')` sends the caller
  `INTERNAL 'Internal server error'`. Use `RpcStatusException`.
- `RpcDebugInfo` and the `message` text are sent to the peer as written. Do not put secrets in them.
- Retry plus a non-idempotent method can execute it more than once.
