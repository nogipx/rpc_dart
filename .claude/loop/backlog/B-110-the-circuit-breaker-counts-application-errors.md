---
status: closed (round 501)
round: 501
commit: 70372049
paths: [packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart]
probe: P-139
reason: "closed — CONFIRMED and fixed: the null-failureOn fallback counted every non-cancellation error, so five correct NOT_FOUND answers opened the breaker and an unrelated healthy method was refused; replaced by a named server-health default"
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

## Outcome (round 501)

**CONFIRMED and fixed.** The witness was built as sketched and read
`breaker=open failures=5`, with the healthy method answering `BREAKER OPEN`, for
NOT_FOUND, INVALID_ARGUMENT, PERMISSION_DENIED, ALREADY_EXISTS and UNIMPLEMENTED.
The cancellation control read `closed`/`0` in the same run.

The fix is the sketch's first half: a named `_isServerHealthFailure` default
covering UNAVAILABLE, RESOURCE_EXHAUSTED, INTERNAL, UNKNOWN and DEADLINE_EXCEEDED,
plus anything that is not an `RpcStatusException` at all. Note it is DELIBERATELY
wider than `RpcRetryInterceptor`'s transient set rather than equal to it — the two
interceptors are asking different questions, and the round record says why.

**The sketch's second half — per-method breakers — is not done.** P-139's third
column measures what it would buy: one unhealthy method still costs every other
method on the endpoint, because state is per interceptor instance. The
classification fix removes the cheap way to trigger that, not the property itself.
It is an API change with a policy question inside it.

## Owner decision

—
