---
round: 623
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: P-158 — reused
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
severity: S2
---

# Round 623 — eighteen items, one of them real

## Target

B-129, the core hygiene lead filed by the external audit: eighteen items, four
of which round 521 said deserved leads of their own. Each item read at HEAD and
either done or answered.

## Hypothesis

The list is reading cost and nothing more, apart from what round 521 already
split out.

## Before

Item 13, round 521's "refuted", re-run on P-158's own probe at HEAD:

```
cancel DURING the backoff     status 1   after 1748 ms
CONTROL cancel immediately    status 1   after 3283 ms
CONTROL no cancel at all      status 14  after 11442 ms
```

Against round 521's 2118 / 1504 / 5237 ms. A cancel "immediately" that takes 3 s
is not prompt. Both runs used `ExponentialBackoff`, whose `jitter` defaults to
TRUE: each wait is uniform in (0, 4 s], so the numbers were random draws.

With a FIXED 3 s backoff (`a_cancel_cuts_the_retry_backoff_test.dart`), cancel
at 300 ms: **3053 ms**.

## Control

The same call with no cancel waits the backoff out (>= 3000 ms) and ends
UNAVAILABLE.

## Mechanism

`RpcRetryInterceptor.interceptUnary` slept with `await Future<void>.delayed(delay)`,
blind to the call's token. The next attempt saw the token and failed CANCELLED,
but only after the rest of the backoff, up to `maxDelay`. Round 521 read the
jittered timings as prompt.

## After

```
cancel at 300 ms during a 3 s backoff     status 1   after 304 ms
```

The wait races the token's `cancelled` future. The other items:

1. `takeClientBufferedMessages(markEndOfStream:)` was never passed true. The
   parameter, its branch and the duplicated doc line are gone.
2. `sendError`'s `!_initialMetadataSent` branch is a Trailers-Only diagnostic.
   Kept.
3. `start()`/`stop()` are the hooks the endpoints override. Kept.
4. `_validate*Transport` lost the try/throw/catch/rethrow; only the getter call
   is guarded, with the same behaviour.
5. `isValidHeaderName`'s CR/LF/NUL line, already covered by `<= 0x20`, is gone.
6. The doc comments of `_refuseMetadata` and `_maxMalformedMetadataFrames` are
   separated.
7. `rpc_notify`'s `is RpcInMemoryTransport` is outside this package. Left for its
   own lead.
8. The endpoint library's eight copies of "policy of this transport or the
   default" are one `_policyOfTransport`. `base_processor`, a separate library,
   keeps its own.
9. `lastPayloadMessage` is kept only until the responder is bound, and released
   when it binds.
10. The client-stream caller's internal log no longer interpolates the decoded
    response. It names nothing of the value: the owner pointed out that a
    `runtimeType` is meaningless in an obfuscated build.
11. `protocol.dart`'s claim that `<< 24` is a signed shift on dart2js was wrong.
    The comment is gone.
12. The unary caller's listener had no `await` and lost its `async`;
    `_statusResourceExhausted` no longer exists.
13. Fixed, above.
14. Already enforced: `validateMetadata` sums against `maxMetadataBytes`.
15. Already fixed in this session (B-198): the 128-character token cap is gone.
16. `C-60` stands: keeping the first response is the gRPC contract. What it
    left, a second response inside one chunk dropped without a word, is now
    warned once per call, as C-60 suggested. The zero-copy branch kept the LAST
    response instead of the first; it now keeps the first too.
17. The `'x-trace-id'` literals use `RpcHeaders.xTraceId`. The ping handler is
    built per ping, so `setLogController` reaches it.
18. The parser no longer logs a header-parse failure twice.

## Canary

1. Backoff wait restored to `Future.delayed`: `a cancel during the backoff ends
   the call promptly` fails at `3053 ms`.
2. Ping handler given `LogScope.noop`, which is what a scope captured at
   construction amounts to: `a log controller set after construction receives
   the ping` fails, with no `Ping handled` record.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (rpc_dart +1932,
websocket +271), `melos run format:check`, `melos run license:check` — green.
The final log-string change was re-run on `test/streams` and `test/resilience`
(+408).

## Not fixed

Item 7 belongs to `rpc_notify`. `RpcClientConnection`'s reconnect loop also
sleeps a plain `Future.delayed`, but it is stopped by `stop()`, not by a call's
token, and was not part of this lead.

## Links

Lead `../backlog/B-129-core-cleanup-items.md` — closed.
Bench `../probes/P-158-does-a-cancel-cut-the-retry-backoff.md` — reused, re-read.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 623]`.
Tests `packages/core/rpc_dart/test/resilience/a_cancel_cuts_the_retry_backoff_test.dart`,
`packages/core/rpc_dart/test/endpoint/a_late_log_controller_reaches_the_ping_handler_test.dart`.
