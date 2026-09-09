---
round: 228
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-01
bench: P-11 — new
budget: probes 1/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record and the bench. Approved 10 of 10
commit: yes
---

# Round 228 — the branch round 206 did not cover

## Target

RPC-01, first by rank among the un-swept. It has produced four findings (206,
207, 208, 212) and has never had a recorded sweep: its status is `confirmed`,
not `swept here`, so no sha pins what was checked.

## Hypothesis

The detector asks, per level, what reclaims credit at teardown. Rounds 206-212
rewrote that accounting; some path charges the connection pool and never
returns it.

## Before

The sweep found the teardown handoff, and it is explicit:

```dart
void _fcForget(int streamId) {
  final consumer = _streamControllers[streamId];
  if (consumer == null || !consumer.hasListener) {
    _fcRepayConnection(streamId);
  }
```

With a consumer bound it defers to that subscription's `onCancel`, which does
repay (`channel_transport.dart:439-445`). So the question is whether `onCancel`
always runs — and a consumer that binds and then stops taking messages satisfies
`hasListener` while never cancelling.

Neither existing arm of round 206's bench sits in that branch: one never
listens, the other listens and drains. Added the third (one against the probe
budget) — `subscription.pause()` after binding, one call different from the
control:

```
  receiver drains                     12 calls, 3072 KiB, never wedged
  receiver never binds a listener     12 calls, 3072 KiB, never wedged
  receiver drains, per-stream OFF     12 calls, 3072 KiB, never wedged
  receiver BINDS and PAUSES            4 calls, 1024 KiB, wedged at call 4
```

1024 KiB is exactly the pool. Same number and same shape as the defect round 206
fixed, on the one branch of that `if` its fix does not reach.

## Mechanism

`_fcOweConnection` charges the pool when a frame is routed to a consumer that
credits on consumption. The debt is settled by consumption or repaid at
teardown. A stuck consumer does neither: it never consumes, and `_fcForget`
hands responsibility to an `onCancel` that never fires.

The three controls are what make this the pool rather than the stream window:
the per-stream window is identical in the control and the case, and only the
case wedges — at the pool's size, not the window's.

## After

n/a — deferred, nothing changed. `git diff` empty.

## Canary

n/a — no fix.

## Gate

No code changed. The gate proper is the one HEAD passed at round 226; this round
touched only the probe, which is gitignored, and the journal.

## Not fixed

**The fix is an accounting change, not a one-liner, and it is the wrong week for
one.** Repaying unconditionally in `_fcForget` double-credits: `_fcOnConsumed`
settles the ledger and then credits the connection directly, so once the entry
is removed a consumer that later drains its buffer credits bytes that were
already repaid, and the pool grows past its configured size. Moving the credit
inside the settle fixes that but breaks `onFrameDiscarded`, whose frames were
never routed and never owed — and `_fcSettleOwed`'s comment records that
separation as deliberate.

Two rounds remain before the cap, and the config says not to open work spanning
several rounds near it. Filed as
[B-22](../backlog/B-22-paused-consumer-never-repays-the-pool.md) with the three
candidates and the measurement, for the owner.

**Reachability, stated so the severity is not overread.** The leak needs a
consumer that stops *permanently* and never cancels. A merely slow handler
drains eventually and settles correctly — that is the ordinary backpressure case
and it is clean. What this measures is the stuck-handler shape, where the cost is
a shared pool that never recovers, so the whole connection wedges rather than
the one call.

**The sweep is recorded but the lens does NOT become `swept here`.** A sweep
that found a defect leaves the lens `confirmed`; the status now carries this
round and the sha, so `stale` can age it.

## Links

Lead `../backlog/B-22-paused-consumer-never-repays-the-pool.md` — new, awaiting
the owner.
Bench `../probes/P-11-connection-debt-with-a-paused-consumer.md` — new, round
206's bench with the third arm.
Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [228]`.
Round `206-connection-credit-never-repaid.md` — the fix this sits beside.
