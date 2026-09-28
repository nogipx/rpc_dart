---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-110 — the circuit breaker opens on NOT_FOUND by default, for every method at once

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

With `failureOn == null` every error except `RpcCancelledException` counts — NOT_FOUND, INVALID_ARGUMENT, PERMISSION_DENIED, DEADLINE_EXCEEDED — and one breaker instance covers the whole endpoint, so five lookups of missing records block every method for 30 s; the retry interceptor's default is transient-only, the breaker's is not.

## The shape

`packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart` `_onFailure`:

```dart
final counts = error is! RpcCancelledException &&
    (failureOn == null || failureOn!(error));
```

State (`_state`, `_failureCount`) is per interceptor instance, not per method.

## Why it matters

A healthy server that answers application errors opens the breaker for unrelated
methods; clients see `CircuitBreakerOpenException` (UNAVAILABLE) for calls that
would have succeeded.

## Witness a round would build

Five calls to a method that throws NOT_FOUND, then one call to a healthy method.
Expected today: the sixth is refused with the breaker open.

## Fix sketch

Default `failureOn` to transport/server-health statuses (UNAVAILABLE, INTERNAL,
UNKNOWN, DEADLINE_EXCEEDED, RESOURCE_EXHAUSTED); consider per-method breakers.

## Owner decision

—
