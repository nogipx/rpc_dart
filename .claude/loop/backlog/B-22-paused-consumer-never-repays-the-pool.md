---
status: awaiting owner
round: 228
commit: af64eeac
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/conn_window_leak.dart
reason: owner decision — the fix has to choose how to avoid double-crediting the pool, and that is an accounting change rather than a one-liner
---

# B-22 — a consumer that binds and never drains never repays the pool

`_fcForget` repays a stream's connection debt only when there is no live
consumer:

```dart
final consumer = _streamControllers[streamId];
if (consumer == null || !consumer.hasListener) {
  _fcRepayConnection(streamId);
}
```

With one bound it defers to that subscription's `onCancel`. A consumer that
binds and then stops taking messages — a stuck handler — satisfies
`hasListener`, so `_fcForget` skips the repay, and `onCancel` never runs because
nothing ever cancels. The debt is never settled and never repaid.

Measured (`conn_window_leak.dart`, 1 MiB pool, 256 KiB stream window, 256 KiB
per call, 12 sequential calls):

```
  receiver drains                     12 calls, 3072 KiB, never wedged
  receiver never binds a listener     12 calls, 3072 KiB, never wedged
  receiver drains, per-stream OFF     12 calls, 3072 KiB, never wedged
  receiver BINDS and PAUSES            4 calls, 1024 KiB, wedged at call 4
```

1024 KiB is exactly the pool. Same signature and same number as the defect round
206 fixed, on the one branch that fix does not cover: 206 added the debt ledger
and repays it when nobody is listening, which is CASE A above.

## Why this is not a one-line fix

Repaying unconditionally in `_fcForget` double-credits. `_fcOnConsumed` does
`_fcSettleOwed(bytes)` then `_fcCredit(bytes)`, and `_fcCredit` credits the
connection directly. Once `_fcRepayConnection` has removed the ledger entry, a
consumer that later drains its buffered messages finds nothing owed — the settle
is a no-op — but still credits the connection for every byte. The pool then
grows past its configured size, which is the same bug pointing the other way.

Moving the connection credit inside the settle (credit `min(bytes, owed)`) fixes
that, but `_fcCredit` is also reached from `onFrameDiscarded` for frames the
channel stepped over, which were never routed to a consumer and were never
owed — and the comment at `_fcSettleOwed` records that this separation is
deliberate. So the two callers need splitting before the arithmetic is safe.

## Candidates

1. **Split the credit paths.** Owed-path consumption credits through the ledger;
   discarded frames and the credit-on-arrival branch credit directly. Then
   `_fcForget` can repay unconditionally. Correct, and it touches the hottest
   accounting in the transport.
2. **Mark the stream repaid.** Keep the current structure, add a bounded set of
   ids already repaid, and skip the connection half of `_fcCredit` for them.
   Smaller, but it is one more piece of per-stream state with its own lifetime,
   and round 212 is what happens when such state outlives its stream.
3. **Accept it.** The leak needs a consumer that stops permanently and never
   cancels. A merely slow handler drains eventually and settles correctly.

## Owner decision

—
