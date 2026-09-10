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

## Round 231: candidate 1 cannot be built as written

`_fcOnConsumed` has **two** callers, not one:

```
  _fcMetered (462)          the consumer takes a message   OWED
  inbound dispatch (1325)   the else branch: no controller,
                            not deferred                   NEVER OWED
```

The `else` is credit-on-arrival — ordinary traffic whose receiver never called
`getMessagesForStream`, and whose bytes were never entered in the ledger.
Routing that caller through `min(bytes, owed)` credits it
`min(bytes, 0) = 0`, so the pool would only shrink. Worse than the defect: the
wedge would no longer need a stuck consumer at all.

So the split cannot key on the caller. It must key on whether a debt was ever
entered, and an empty ledger cannot distinguish never-owed from
already-repaid — that needs a per-stream mark.

> **Candidate 1 collapses into candidate 2.** They are not alternatives; the
> first needs the second to be correct. What is left to choose is where the mark
> lives and how it is bounded.

**And P-11 is blind to this**: every arm calls `getMessagesForStream`, so the
1325 branch is never taken and all four arms would have stayed green while
ordinary traffic lost its credit. A fifth arm is required before any fix here,
whichever shape is chosen.

## Owner decision

**Build the per-stream mark** (round 247). The owner accepted round 231's
finding that it is not optional: mark each stream's owed bytes so the ledger can
tell owed from never-owed, instead of routing `_fcOnConsumed` through it
wholesale and de-crediting ordinary traffic.

The round that carries this out reuses P-11 as its bench — three controls reach
3072 KiB where the paused arm wedges at the pool — and needs a canary on the
ORDINARY-traffic path as well as on the wedge, because round 231's whole finding
was that the obvious fix breaks the former while fixing the latter.

> **Superseded — round 231 measured this to be unbuildable as written.** Kept
> below because the reasoning about `_fcSettleOwed` still holds; what changes is
> that a mark is not optional.

**Candidate 1 — split the credit paths.** (Asked and answered after round 230.)

Consumption on the owed path credits the connection THROUGH the ledger
(`min(bytes, owed)`); frames the channel stepped over and the credit-on-arrival
branch credit directly. `_fcForget` can then repay unconditionally with no
double credit.

Notes for the round that carries this out:

- **`_fcSettleOwed`'s comment is the specification of what must not break.** It
  records that settling is deliberately kept out of `_fcCredit` because
  `onFrameDiscarded` frames were never routed to a consumer and were never
  owed. The split has to preserve that, not delete it — those frames keep
  crediting directly.
- **Three callers of `_fcCredit` and they are not alike**: `_fcOnConsumed`
  (owed), `returnFlowCredit` (owed, the `IRpcFlowControlled` path), and
  `onFrameDiscarded` (never owed). The first two move to the ledger route, the
  third does not.
- **The witness is P-11's CASE C**, which must go from 4 calls / 1024 KiB to the
  full 3072 KiB, with all three existing arms unmoved. Two canaries per L-01:
  one for the repay half, one for the no-double-credit half — and the second
  needs its own assertion, because over-crediting shows up as a pool LARGER
  than configured, which no existing arm would notice.
- Round 212 is the cautionary tale for anything keyed per stream that outlives
  its stream; re-read it before adding state.
