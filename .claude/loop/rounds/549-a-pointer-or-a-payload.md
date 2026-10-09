---
round: 549
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-17
bench: P-178 — new
budget: probes 1/5, canaries 0/5
commit: yes
release: none
severity: S1
---

# Round 549 — a pointer, or a payload

## Target

The owner's **MEASURE FIRST** decision on zero-copy backpressure: separate a MINTING producer
from a HOLDING one, because the fix options rank differently by the outcome and no round may pick
between them until the number exists. The lead is named in `## Links`.

**Phrased that way deliberately.** `lint` refuses a round whose `## Target` names a lead that is
`awaiting owner`, because taking an unanswered question as a target decides it. This round did
the opposite — it executed a decision and handed back a narrower question, which is what moved
that lead to `awaiting owner`. The check cannot see the ordering, and its own message names this
as the way to express it.

Lens RPC-17: a limit that fires after residency. Here the question is whether there is residency
to limit at all.

**No code changed.** The deliverable is the number and the narrowed question, which is what the
decision commissioned.

## Hypothesis

`bufferedBytes` is 0 for a `directPayload` and the code says queuing one "costs a pointer". That
holds for an object the process already retains and fails for one minted per message — and P-135
drove only the minting shape, so its unbounded queue could be read either way.

## Before

```
P-135, round 497
mode      consumer   window       produced   received
zeroCopy  PAUSED     4096 KiB      247722          1
zeroCopy  PAUSED       64 KiB      274289          1   <- shrinking the window changes nothing
codec     PAUSED       64 KiB        5960          1   <- for comparison, the metered path
```

Unbounded, and silent about WHY it matters.

## Mechanism

Nothing to fix yet; what the round did is make the two shapes distinguishable. 400 direct objects
of 1 MiB with no consumer, RSS read before, after the objects exist, and after they are queued.
The measure is the queue's MARGINAL retention.

## After

```
  arm        RSS before   after building   after queueing   queue cost   (nominal 400 MiB)
  HOLDING       220 MiB          616 MiB          615 MiB       -1 MiB
  MINTING       217 MiB          217 MiB          530 MiB      313 MiB
```

Bench `../probes/P-178-minting-against-holding.md`.

**−1 MiB against 313 MiB.** Both statements about a direct object are true, of different shapes.
Queuing one the process already holds costs a pointer, exactly as the code claims. Queuing one
nobody else holds costs its whole payload, and the queue is then the only thing retaining it.

The `after building` column is the control and it caught the rig twice — see the bench: a
zero-filled `Uint8List` is not resident until written (400 MiB of allocation moved RSS by 6), and
running both arms in one process made the second arm's baseline the first arm's high-water mark.
One arm per process now, baselines agreeing to 3 MiB.

## Canary

**None, and none is possible.** No mechanism was switched on or off: the round measured an
existing one. What stands in for a canary is the control column, which is what a wrong reading
would have shown — and did, twice, before the rig was fixed.

## Gate

```
melos run analyze        No issues found!            21 packages + wasm
melos run format:check   0 changed                   21 packages + wasm
melos run license:check  REUSE compliant
```

**`test:unit` was NOT re-run, and that is stated rather than implied.** Nothing under `lib/` or
`test/` changed in this round — `git status` is journal files and a gitignored probe — so the
suite would be measuring round 548's tree, which it already reported green at 1832 passed and 3
skipped. The three above were run because they are cheap and because `analyze` covers the
`.dart_tool` probe's package.

## What this does and does not settle

The decision said: *if holding is the RARE shape, in-memory's severity rises and a count-based
ceiling is obviously right; if it is the COMMON shape, the bound belongs only where the object is
copied, which is isolate.*

**That fork cannot be resolved by measurement here.** Which shape an application uses is a fact
about applications, not about this library, and no probe in this repository can reach it.

**But the fork may not need resolving.** A per-stream EVENT ceiling — a queue depth, which the
decision already named as the only bound an operator can set meaningfully — is correct for BOTH
arms:

- on the MINTING shape it is the only thing that bounds memory at all, and 313 MiB of retention
  from 400 messages says what is at stake;
- on the HOLDING shape it costs nothing real. The objects exist either way, so refusing to queue
  the 1001st is still honest backpressure about the QUEUE, and the measurement says the queue's
  own cost is `-1 MiB`.

So the recommendation is that the ceiling does not depend on which shape is common — which is the
narrowed question this round hands back.

## Not fixed

**Nothing is bounded yet**, deliberately: a queue depth is a new public policy field, and pinning
what it counts is the B-209 / B-128 trap from a third side. Both of those rounds show a field
whose meaning is not nailed down becomes its own lead.

**The isolate half needs no measurement and is unchanged.** `SendPort.send` deep-copies all but
deeply-immutable values, so the pointer argument does not apply there even in principle — settled
in B-106 and not re-derived.

**`P-135`'s numbers are not re-run.** This round adds an attribution measurement beside them
rather than repeating the count, and the two benches answer different questions on the same path.

## Links

Lead `../backlog/B-106-zero-copy-has-no-backpressure.md` — back to `awaiting owner` with the
number its decision asked for.
Bench `../probes/P-178-minting-against-holding.md` — new.
Bench `../probes/P-135-does-the-window-reach-a-direct-object.md` — the count; unchanged.
Round `497-vary-the-limit-to-see-if-it-is-the-limit.md` — measured the unbounded queue on the
minting shape.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [549]`.
