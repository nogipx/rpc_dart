---
round: 514
verdict: FIXED
packages: [rpc_dart]
lens: RPC-14
bench: P-152 — new
commit: yes
---

# Round 514 — the drain waited for a tick

## Target

Both drains polling on a timer against the wall clock — thirtieth in the audit's
rank.

Lens RPC-14, the timeout/abandonment lens, read on the other side: not a wait that
gives up too early, but one that does not notice it is over. A drain's whole job is
to finish as soon as the work does.

## Hypothesis

`_runDrain` sleeps 50 ms and `drainUntilIdle` 25 ms in a loop against
`DateTime.now()`, so shutdown pays up to a poll interval and a clock step changes the
budget.

## Before

```
handler finishes into the drain      drain took
                    1 ms              52 ms
                    5 ms              51 ms
                  120 ms             156 ms   <- control
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b123_drain_latency.dart`

**CONFIRMED: ~51 ms of a 52 ms drain is waiting for a tick after the work is done.**

The control row is where the round gained something the lead does not mention. A
handler that genuinely runs 120 ms made the drain take `156 ms` — so polling added
~36 ms of rounding even when the work dominated. The cost is not confined to the
pathological case.

## Mechanism

```dart
final deadline = DateTime.now().add(timeout);
while (_respStreams.length > 0 && DateTime.now().isBefore(deadline)) {
  await Future<void>.delayed(const Duration(milliseconds: 50));
}
```

Nothing tells the drain that a stream finished, so it asks — at a rate chosen as a
compromise between latency and waste, which is the compromise a signal makes
unnecessary.

## After

```
                    1 ms               5 ms
                    5 ms               7 ms
                  120 ms             122 ms   <- control, now tracking the work
```

`_cleanupStream` completes a waiter when the active-stream count reaches zero, and
`_runDrain` awaits it with `.timeout(timeout)`.

**The signal is placed before `_cleanupStream`'s early return, deliberately.** That
method returns early when the id had no state, but what a drain waits for is the
COUNT reaching zero, which is true either way.

`.timeout()` is a Timer rather than a `DateTime.now()` comparison, so the budget half
is fixed in the same edit. `drainUntilIdle` keeps its 25 ms poll — it is generic over
a `pending()` callback and has nothing to be signalled by — but its deadline is now a
`Stopwatch`, on the argument `RpcCircuitBreakerInterceptor` already documents for its
own.

Regression: `test/endpoint/the_drain_is_signalled_not_polled_test.dart`,
1 WITNESS and 4 GUARD.

## Canary

The poll restored. The WITNESS fails, `Expected: < 35, Actual: <52>`, and all four
GUARDs hold.

Two of those guards are the ones that matter, because the risky direction here is a
drain that returns too soon: *a drain still waits for a handler that is genuinely
slow* (≥100 ms), and *the budget still expires when the handler never finishes*
(≥180 ms, and bounded). A completer that replaced the deadline rather than racing it
would hang a deploy, which is worse than the latency being fixed.

**The bounds are deliberately loose** — `< 35` against a measured 5, `≥ 100` against
120. The finding is an order of magnitude, and this gate is timing-sensitive enough
that B-196 exists about it; pinning 5 ms would buy nothing and flake.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**`drainUntilIdle` still polls**, at 25 ms. Its budget is now monotonic but its
latency is unchanged, and the lead's "two copies of one mechanism" is therefore still
two. Unifying them means giving the generic helper something to wait ON — a callback
that returns a Future, or an event — which changes its signature and every caller.
Worth doing; not this round.

**The wall-clock claim is fixed without being measured.** Nothing here steps a clock.
Both deadlines are now monotonic on the argument the circuit breaker already
documents, which is reasoning rather than evidence, and the record says so rather
than implying a measurement.

**`activeResponderCount`'s O(n) `where` per tick is untouched** — the lead's third
claim. With the responder drain no longer ticking, the site that called it per tick is
gone, so the remaining cost is whatever polls it elsewhere; that was not measured.

## Links

Lens RPC-14. Bench P-152 (new). Lead B-123 (closed on the responder drain;
`drainUntilIdle`'s polling and the shared-implementation half remain).
