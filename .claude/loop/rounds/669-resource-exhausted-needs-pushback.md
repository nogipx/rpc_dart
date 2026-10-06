---
round: 669
verdict: FIXED
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-19
bench: P-232 — new
commit: yes
release: changelog
---

# Round 669 — RESOURCE_EXHAUSTED is retried only with pushback

## Target

B-222, in the owner's order core first. One status, two meanings: a limit that
frees up, and a message over a size limit. The lead owed the cost and whether
anything behind a 413 changes between attempts.

Measured first, then put to the owner (decided in this session): **retry 8 only
with pushback** -- an `RpcRateLimitException` or a status carrying
`RpcRetryInfo` -- and the same narrowing in the breaker.

Scope, counted before the fix: 31 RESOURCE_EXHAUSTED producers in core and the
transports. Capacity (transient) ones that must now carry pushback to stay
retried: 3 responder-pipeline refusals (stream ceiling, pre-method budget,
handler ceiling), 6 local throws (core id exhaustion, channel/http1/http2 stream
ceilings, http2 server's MAX_CONCURRENT_STREAMS, http2 parser slots), the rate
limiter. The rest are size or per-call buffer refusals and stay bare.

## Hypothesis

A size refusal fails identically on every attempt, so each retry is pure cost.

## Before

```
2x ceiling   no retry   128 KiB   74 ms    retry   385 KiB  292 ms
10x ceiling  no retry   640 KiB   32 ms    retry  1921 KiB  262 ms
```

Nothing behind our 413 changes between attempts: `maxMessageLengthBytes` is
fixed for a server's lifetime, and the message does not shrink.

## Mechanism

`_isTransient` read the status alone. `_isServerHealthFailure` likewise, so a
client sending oversized messages opened the breaker for every method.

## Fix

- `RpcRetryInterceptor`: RESOURCE_EXHAUSTED retried only with `RpcRetryInfo`
  (or as `RpcRateLimitException`).
- `RpcCircuitBreakerInterceptor`: counts RESOURCE_EXHAUSTED only on the same
  condition.
- `RpcStatusException.atCapacity(message)`: new constructor, status 8 plus
  `RpcRetryInfo(Duration.zero)`. Used at the 6 local throws.
- The responder pipeline's 3 capacity refusals send the same detail in
  `grpc-status-details-bin`.
- `RpcRateLimitException(message, {retryAfter})`: the limiter passes one slot's
  period (window / max) of the counter that refused.

## After

```
2x ceiling   retry   128 KiB   13 ms
10x ceiling  retry   640 KiB   24 ms
handler cap  [ok, ok], ran 2      rate limit  [ok, ok], ran 2
```

## Canary

`packages/core/rpc_dart/test/resilience/resource_exhausted_needs_pushback_test.dart`:

- predicate back to "any 8": `a message over the size limit is sent once` red,
  `Expected: <1> Actual: <3>`.
- breaker back to "any 8": `a bare RESOURCE_EXHAUSTED does not open the breaker`
  red, `Actual: CircuitBreakerOpenException`.
- pushback removed (pipeline detail and limiter `retryAfter`): handler-cap and
  rate-limit arms red, `Expected: ['ok', 'ok'] Actual: ['ok', 'status 8']`.

All restored: 4 of 4 green.

Four existing tests pinned the old contract and were updated to the decided one:
`retry_interceptor_test` (bare 8 now 1 attempt; with pushback 3),
`retry_reconnects_before_trying_again_test` and the breaker GUARD (now with
pushback; a bare 8 joins the breaker WITNESS list), and http's
`a_slow_upload_is_worth_retrying_test` (413 now 1 request).

## The verdict questions

1. Yes: each canary removes one half; the cost arms differ by the interceptor.
2. Yes: 385 against 128 KiB, 1921 against 640.
3. Yes: bytes at the socket, handler counts at the server.
4. Not zero-valued.
5. Yes, quoted.
6. Three halves, three canaries.
7. Yes; the fix is the owner's choice of three, put after the measurement.
8. None.

## Gate

`analyze` (21 packages and wasm) green; `test:unit` green in all 15 packages
(rpc_dart +2062, http +217, http2 +284); `format:check` clean;
`license:check` compliant.

## Not fixed

A foreign server's RESOURCE_EXHAUSTED without RetryInfo is now final -- by
decision, as gRPC's own guidance has it. ENHANCE_YOUR_CALM (http2 RST code 11)
maps to a bare 8 and is now final too; it is a peer telling us to slow down and
carries no delay.

## Links

Lead `../backlog/B-222-a-too-large-body-is-uploaded-three-times.md` closed.
Bench `../probes/P-232-what-the-default-retry-spends-on-resource-exhausted.md`.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` -- `applied: [..., 669]`.
