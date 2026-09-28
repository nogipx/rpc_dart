---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/does_a_retry_survive_the_window.dart
round: 464
commit: 3630c877
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-114 — does a retry survive the reconnect window?

## Why it exists

A prior round chose FAILED_PRECONDITION for a send inside the reconnect window
and wrote the reason into the test that pins it:

> *"a synthetic UNAVAILABLE is RETRYABLE and invites the caller to repeat what
> cannot work"*

That is a sentence a decision rests on, so L-13 says re-measure it rather than
override it. And it IS measurable: does a retry during the window work?

The sentence has a hidden premise — that "repeat" means "repeat immediately".
`RpcRetryInterceptor` backs off between attempts, so the premise is exactly what
the bench varies against.

## The harness

A real `RpcWebSocketServer` with an echo contract, a caller endpoint carrying
`RpcRetryInterceptor(maxAttempts: 4, ExponentialBackoff(baseDelay: 250ms))`, and
an injectable reconnect factory stalled 800 ms.

**The timings are chosen so the question has a fair answer both ways.** The call
is fired 100 ms into the window, leaving 700 ms of it; the first backoff is
250 ms, so a retried call has several chances to land after the window closes
and before its four attempts run out. A window longer than the whole retry
budget would prove only that retries can be exhausted.

## The numbers (round 464)

```
control, no reconnect                       OK pong after 30ms

a retried call fired 100 ms into the window
  FAILED_PRECONDITION (what was shipped)    status=9 after 0ms
  UNAVAILABLE (round 464)                   OK pong after 711ms
```

**The sentence is false for this state.** The retry was not a repeat of something
that cannot work: it backed off, the reconnect finished, and the call succeeded.
`after 0ms` is the other half — FAILED_PRECONDITION is not retried at all, so the
caller's whole call fails for a condition that cleared itself 700 ms later.

## Measures

The call's outcome and its wall-clock duration. The DURATION is what separates
the two: `0ms` proves no retry was attempted, and `711ms` proves the retry waited
out the window rather than succeeding on a first attempt that happened to race.

## Control

A call with no reconnect in flight, which returns in 30 ms — so the 711 ms is the
backoff and the window, not the harness being slow, and the echo path works.

The two status arms are each other's control: same code, same timings, same
server, one line different.

## What it establishes, and what it does not

Establishes: during a reconnect window, UNAVAILABLE recovers a call that
FAILED_PRECONDITION loses.

Does NOT establish anything about the state after a FAILED reconnect, where
nothing is running and a retry would land in the same refusal. That is why the
status stayed FAILED_PRECONDITION there, and P-113 is the bench that covers it.
