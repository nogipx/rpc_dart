---
round: 322
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-09
bench: P-10 — reused
commit: yes
---

# Round 322 — the ablation three rounds owed

## Target

RPC-09, the next item on 319's queue: 34 files have moved since its sweep at
`8d4d1e33`.

**Taken as an ablation, not a reading.** Round 320 ended by writing into RPC-02
that three consecutive readings are worth less than one re-measurement. RPC-09
is in the same position — 210 and 221 measured, 244 re-read — and unlike RPC-02
it has a registered bench with a validated control sitting unused (`P-10`). The
cheapest way to honour what 320 concluded is to do it on the lens where the
apparatus already exists.

## Hypothesis

Two, one old and one only possible now.

1. Nineteen behavioural commits along these paths, plus three refactors of my
   own in rounds 308-315, have broken a wake path or moved the parking site.
2. **New since 244:** rounds `7cba007b` and `cd6ee68e` put a BOUNDED queue on the
   inbound stream of the channel transport. If the answer must pass through a
   bound the request pump can exhaust, the independence RPC-09 rests on dies —
   and that door did not exist when 244 swept.

## Before

Bench `P-10` (`.dart_tool/probe/parked_sender_learns.dart`), reused whole, with
its registered control: `_fcOnGrant` made to refuse every grant, live or not.

```
                        normal                grants refused
                        221      322          221      322
CONTROL drains          0.2 s    0.2 s        HUNG     HUNG
                        2000     2000         20.0 s   20.0 s
                        pulled   pulled       16       16
CASE    answers early   0.4 s    0.4 s        0.4 s    0.4 s
                        17       17           16       16
                        pulled   pulled       pulled   pulled
```

**Eight cells, all eight identical across 101 rounds.** The bench still sees a
credit hang at full strength, and the asymmetry it exists to hold is intact:
starve the credit path completely and the draining call hangs, while the call
that receives an answer still returns in 0.4 s.

## Mechanism

Hypothesis 1 is false. One parking site (`_fcAwaitCredit:751`), and its loop is
still `while (!_closed)` with a `_fcTryConsume` re-check, so a spurious wake is
harmless and a closed transport leaves. `close()` walks `_fcSendWaiters` at 535
and `_idManager.releaseAll()` lands at 549 — eleven lines later, without
reaching them; 244 recorded twelve, and the code has shifted by one.

Hypothesis 2 is false for a structural reason worth keeping:
**`BufferedBroadcastController` enqueues only while NO listener is attached**,
and its overflow is fatal-with-error rather than silent — it delivers the
survivors, adds a `StateError` and closes. So it cannot produce RPC-09's break,
which is `a hang that never ends`. A bound that fails loudly is not on this
lens's surface at all.

**What the sweep did find is in the record, not the code.** Round 244 counted
"three wake paths — credit, the legacy grace timer, `close()`". There are four:

```
_fcOnGrant:866         per-stream credit arrives
_fcWakeConnection:827  connection credit, and the grace timer's expiry (787)
close():536            the peer is gone
_fcForget:1077         the call ended        <- not in 244's count
```

The missing one is not an obscure branch. It is the wake round 206 added and
round 211 proved load-bearing — 30 abandoned uploads leave 30 stranded senders
without it, 0 with it — and the one round 210 ablated when it wrongly concluded
the rig was blind. A re-sweep that had only re-read would have copied the three
forward again.

## After

```
RPC-09   swept here (round 244, 8d4d1e33)  ->  swept here (round 322, 9bb632e0)
```

## Canary

The ablation IS the canary, and it is the registered one: `_fcOnGrant` returning
before it touches the window. With it in place the healthy, draining call reads
`HUNG — no answer in 20 s` after 16 messages. Reverted, the same call reads
`completed: drained` in 0.2 s after 2000.

## Gate

No code changed — the ablation was reverted and `git status` is empty.
`rpc_dart`'s `test/transports/` green after the revert. Last full gate at round
321's `9bb632e0`: analyze clean over 21 packages plus wasm, `test:unit` 14
packages 0 failures, format clean.

## Not fixed

Nothing to fix. RPC-14 (33 files) and RPC-19 (21) are what remains of 319's
queue, and `curate` is overdue since ~234.

RPC-02's own re-ablation is still owed; this round discharges the debt on
RPC-09, which is a different lens. Doing it here rather than there was a choice
about where the apparatus already existed, and it should not read as RPC-02
having been settled.

## Links

RPC-09 (`applied:` gains 322, status re-dated to `9bb632e0`), P-10 reused with
its control repeated first, as a reused bench requires.

What this adds to RPC-09: the wake-path COUNT is part of its detector, and a
sweep that reports it from the previous sweep instead of from the code will
carry an undercount forward indefinitely.
