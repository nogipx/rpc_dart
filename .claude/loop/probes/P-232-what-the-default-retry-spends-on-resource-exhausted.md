---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b222_retry_cost.dart
round: 669
commit: d81849bf
paths: [packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-232 — what the default retry spends on RESOURCE_EXHAUSTED

## Why it exists

B-222: RESOURCE_EXHAUSTED means both "a limit that frees up" and "a message over
the size limit", and the default `RpcRetryInterceptor` retried both.

## The harness

Two files.

- `rpc_dart_http/.dart_tool/probe/b222_retry_cost.dart` -- `RpcHttpServer` with
  `maxMessageLengthBytes` 64 KiB behind a byte-counting TCP proxy; one unary call
  at 2x and 10x the ceiling, with and without the default interceptor. Prints
  uploaded KiB and time to the final error.
- `rpc_dart/.dart_tool/probe/b222_what_is_still_retried.dart` -- a channel pair,
  default interceptor (350 ms fixed backoff): two concurrent calls against
  `maxConcurrentHandlers: 1`; two back-to-back calls against a 1-per-300 ms
  `RpcRateLimiter`; one 4 KiB call against a 1 KiB ceiling.

## The numbers

```
round 669 before                         after
  2x  no retry    128 KiB    74 ms         128 KiB
  2x  retry       385 KiB   292 ms         128 KiB   13 ms
  10x no retry    640 KiB    32 ms         640 KiB
  10x retry      1921 KiB   262 ms         640 KiB   24 ms

  handler cap     [ok, ok], ran 2          (pushback ablated: [ok, 8], ran 1)
  rate limit      [ok, ok], ran 2          (pushback ablated: [ok, 8], ran 1)
  size            [8], ran 0
```

## Measures

Bytes the client put on the socket; handler invocations and call outcomes.

## Control

`no retry` for the cost; the pushback ablation for the capacity arms, which
shows they pass only because the refusal carries `RpcRetryInfo`.

## What it establishes, and what it does not

Establishes which RESOURCE_EXHAUSTED the default retries. Does NOT cover a
foreign server's quota error without RetryInfo, which is now final by decision.
