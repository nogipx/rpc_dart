---
round: 726
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-09
bench: P-10 — reused
commit: yes
release: none
---

# Round 726 — the weighing did not move the sweep

## Target

`loop.py stale` aged RPC-09's round-717 sweep on four core files: round
719's own weighing (`security_policy.dart`, `transport.dart`,
`responder_pipeline.dart`, `responder_streams.dart`). Reading says those
changes touch the responder's request budget and not a deadline below a
write. P-10 runs in a minute, so it was re-run rather than argued. The same
round also checks round 719-722 on the web target, which the ordinary gate
never runs.

## Hypothesis

Round 719 changed what the responder refuses. Through that, it changed
whether a parked sender's call can complete.

## Before

P-10 (`parked_sender_learns.dart`), normal column:

```
  CONTROL drains     completed 'drained', 0.2 s, 2000 pulled
  CASE answers early completed 'early',   0.4 s,   19 pulled
```

Identical to round 717. `melos run test:web` over rounds 719-722: core 2045
on dart2js, every companion green.

## Mechanism

None. P-10 runs over a channel transport, which keeps its depth bound and a
zero per-message charge.

## After

n/a.

## Canary

n/a — no fix. P-10's ablation column was re-run in round 717.

## The verdict questions

1. Yes: the round-717 bench on the round-719 code.
2. The ablation column from round 717 stands. This round re-ran only the
   normal column.
3. At the request generator.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

No library change. `test:web` green.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-09-deadline-below-write.md`: `applied: [..., 726]`,
swept at `472dd6af`, the last code commit.
