---
round: 211
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-04 — new
budget: probes 1/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record, the bench and both controls; approved 10 of 10
commit: no
---

# Round 211 — the wake is load-bearing after all

## Target

Not the lens `next` named — it has offered RPC-01 five rounds running because
its status is `confirmed` rather than `swept here`. Instead, B-13, the lead
round 210 opened and specified a bench for: round 206 added
`_fcWake(streamId)` to `_fcForget` so "a torn-down call can never leave a sender
waiting forever", round 210 ablated that wake and NOTHING moved, so the claim
was untested by any measurement in the journal. That is RPC-15 — re-measure the
loop's own record. Closing an opened question beats opening a sixth.

## Hypothesis

Round 210 could not see the wake do anything because it watched the CALL, which
resolves on the response path. Watching `flowControlStateSizes['waiters']`
instead should show it — or show that round 206 shipped a no-op.

## Before

```
30 client-stream uploads into a handler that consumes nothing, 64 KiB window,
8 MiB offered per call, so each one parks at 17 messages (68 KiB):

                                    waiters   sendCredit
  CONTROL handler drains               0          0
  CASE    handler consumes nothing     0         30
  CASE    same, _fcWake ablated       30          0
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/parked_waiters_drain.dart`
(P-04), plus `sendcredit_timeline.dart` as a diagnostic.

## Mechanism

The wake is load-bearing and round 206's claim holds: remove it and every
abandoned upload strands its sender permanently — 30 calls, 30 parked senders,
never released. Round 210's ablation looked clean only because it watched the
wrong counter.

So B-13 is answered, and the bench is registered: this is the control round 210
explicitly could not produce, which is why it refused to promote its own probes.

## After

n/a — nothing was changed. `git diff` is empty; the ablation and the
diagnostics were reverted in place.

## Canary

n/a — no fix. The ablation IS the control, and it is what makes P-04 a bench
rather than a probe.

## Gate

No code changed, so the gate is the one HEAD already passed at round 209.

## Not fixed

**A different leak the same bench found, deliberately left as a lead.** The
`sendCredit` column above: one stale `_fcSendCredit` entry per
parked-then-abandoned upload, linear (6 calls gave 6), zero for ordinary drained
traffic. It is bounded by `_fcCanTrack`'s cap and the behaviour at that ceiling
is documented and was attacked in round 145 — but round 145's story is a hostile
ghost-id flood, and this is ordinary successful traffic reaching the same
ceiling, after which `initialSendWindowBytes` stops seeding new streams. Filed
as B-14.

I wrote a fix for it and **reverted it**: the theory was that the sender woken by
`_fcForget` loops back into `_fcTryConsume` and re-seeds, and closing that path
left the number at exactly 30. Diagnostics in the seed branch and in `_fcForget`
printed `SEED 1, SEED 1, FORGET 1 x4` — every forget after every seed, no seed
after — so the writer is elsewhere, most likely `_fcOnGrant`, which also writes
`_fcSendCredit` and is not gated on the stream being live. Shipping the fix
would have been an unproven change to core flow control; B-14 records the
disproven theory so it is not re-tried.

## Links

Lead `../backlog/B-13-parked-sender-outlives-its-call.md` — closed by this round.
Lead `../backlog/B-14-stale-sendcredit-per-abandoned-upload.md` — new.
Bench `../probes/P-04-parked-waiters-drain.md` — new, validated by two controls.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [201, 211]`.
Round `210-the-answer-does-not-wait-on-the-send.md` — whose ablation opened this.
Round `206-connection-credit-never-repaid.md` — the claim re-measured.
