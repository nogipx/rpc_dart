---
round: 221
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-09
bench: P-10 — new
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record and the bench, and Q4 — the one round 210 had to answer NO — is now YES
commit: no
---

# Round 221 — the sweep that could not see a hang, now can

## Target

Not B-17: its decision was measured unimplementable in round 218 and the
replacement is with the owner. Declined for the third time, recorded rather
than skipped.

RPC-09, which the curate pass put at the head of the rank as **due a
re-measurement**: its sweep was STALE since `beed83e5`, and round 212 changed
exactly the credit path it reasoned about — adding a new way for a grant to be
REFUSED, which is a new way for a parked sender to hang.

## Hypothesis

Round 212 gated `_fcOnGrant` on the stream still being tracked. If that gate is
ever wrong about a LIVE stream, a parked sender never gets credit and the call
hangs — RPC-09's damage exactly, introduced by the fix for something else.

## Before

```
core, 64 KiB window, 8000 KiB offered:
  CONTROL handler drains         completed 'drained', 0.2 s, 2000 pulled
  CASE    answers while parked   completed 'early',   0.4 s,   17 pulled

http2, deaf handler, 4 MiB window:
  CONTROL handler consumes       completed 'done',    6.6 s, 40000 pulled
  CASE    server refuses         RpcStatusException(8), 0.2 s, 1038 pulled
```

Probes: `parked_sender_learns.dart` (P-10) and
`refusal_reaches_the_uploader.dart`.

Both halves reproduce round 210's numbers, so the sweep's conclusion survives
rounds 211-220. The CONTROL row is the load-bearing one: 2000 messages through a
64 KiB window means the sender parks and is woken by grants repeatedly, so
round 212's gate is demonstrably not refusing grants to live streams.

## Mechanism

**What this round adds is the ablation round 210 could not produce.** That round
refused to register its probes as benches because it had not shown they would
catch a hang, and recorded the refusal honestly. With `_fcOnGrant` made to
refuse EVERY grant:

```
                          normal              grants refused
  CONTROL drains     0.2 s, 2000 pulled    HUNG, 20 s, 16 pulled
  CASE    answers    0.4 s,   17 pulled    completed, 0.4 s, 16 pulled
```

So the rig sees a credit hang at full strength. And the asymmetry is round 210's
finding demonstrated rather than argued: starve the credit path completely and
the draining call hangs, while the call that RECEIVES AN ANSWER still returns in
0.4 s. The answer path does not wait on the send path, which is why RPC-09's
shape cannot arise here.

## After

n/a — nothing changed. `git diff` is empty, `analyze` green; the ablation was
reverted in place.

## Canary

n/a — no fix. The ablation is the control, and it is what promotes the probe to
a bench.

## Gate

No code changed, so the gate is the one HEAD passed at round 212.

## Not fixed

Nothing outstanding for this lens. **Review Q4 is now answered YES**, where
round 210 had to answer NO: it is proven the mechanism could emit a hang,
because ablating the credit path produces one.

The http2 half's probe is still not registered. Its numbers reproduce, but no
ablation was run on that side, so the same objection round 210 raised would
apply — and one validated bench for this lens is enough to hold the claim.

## Links

Bench `../probes/P-10-parked-sender-learns.md` — new; the probe round 210 wrote
and deliberately did not register.
Lens `../lenses/RPC-09-deadline-below-write.md` — `applied: [210, 221]`,
`swept here` refreshed to 7d06201c with the ablation recorded.
Round `210-the-answer-does-not-wait-on-the-send.md` — the sweep this re-measures,
and the round whose stated gap this closes.
Round `212-a-late-grant-resurrects-a-dead-stream.md` — the change that made the
re-measurement due.
