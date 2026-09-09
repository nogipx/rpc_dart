# Schema: a lead

> [Schemas](SPECS.md) · produced by a DEFERRED or INCONCLUSIVE verdict, see
> [round.md](round.md) · re-measuring one is a round of its own:
> [catalog/U-21](../catalog/U-21-remeasure-own-deferrals.md)

Path: `.claude/loop/backlog/B-N-slug.md`. Plus a line in `backlog/BACKLOG.md`,
where the line order is the rank — `loop.py status` prints the leads in it.

A lead is what a round left unfinished, including a wait on an owner decision
and a bench that produced no number. Something still has to be done about it;
answered questions live in `checked/`.

```
---
status: open | awaiting owner | closed (round N) |
        decided by owner (round N)
round: N — when it was measured; `— (not re-measured)` if the record was
       carried over at setup rather than taken again
commit: <the HEAD sha at the moment of measurement>
paths: [<globs of the code the claim is about>]
probe: <the probe file, if there is one; otherwise «—»>
reason: cost | risk | owner decision | bench — and in what exactly
continuation: yes            # OPTIONAL. Work a round STARTED and did not finish
---

# B-N — <title>

<the numbers; the mechanism in one or two sentences; links to the lens and the
round by ID>

## Owner decision

—
```

**`## Owner decision` is the LAST section and holds `—` until the owner writes
in it.** The owner writes the decision in their own words and touches nothing
else; the next round takes such leads first, carries them out, sets the status
`decided by owner (round N)` and names the round.

Free prose goes FIRST, before the sections, not after them: text after the last
`##` becomes part of THAT section. Checked during the format migration — a
lead's description, having landed under `## Owner decision`, made `loop.py next`
announce a non-existent owner decision as the round's target.

**`continuation: yes` marks a lead whose work is understood and merely
unfinished** — a round ran out of scope, not out of ideas. Finishing it before
opening a new lens is the expected judgement, and a round that opens one anyway
says why in `## Target`; the script reports the flag and decides nothing. It is
opt-in and never inferred, because a lead that is genuinely BLOCKED (waiting on
the owner, a bench that cannot produce a number, a change held for the next
major) must not look unfinished. `lint` refuses it on a lead that is not `open`.

The flag exists because a loop with nothing marking debt cannot finish a thread.
Measured over rounds 234-238: five rounds, five different lenses, while a
migration opened at 234 sat at 27 unfinished files the whole time. The round
that defers work decides, there and then, whether it is leaving a continuation
or a blocker.

**The flag is a debt, not a parking space.** A round that takes a continuation
either closes the lead or says in its record why the flag stays — otherwise one
unfinishable lead would monopolise every future round.

**`reason` must be cost, risk, an owner decision or the bench.** "It was broken
before us" is not a reason: it only says whether a regression was introduced,
which changes the urgency and the commit text, not whether to fix it at all.

**A lead goes stale in parts.** Its number ages separately from its blocker, and
re-running the original probe can wrongly close a real defect. A re-measurement
is a full round target — see `../catalog/CATALOG.md`, shape U-21; `loop.py stale`
says when it is due.

**The owner protocol.** The only channel for decisions in an unattended loop is
the `## Owner decision` section of the lead's file. The status is changed not by
the owner but by the round that carried the decision out: that is how
`loop.py status` sees decisions not yet taken up. Standing requirements that
hold in every round live in `config.md`, not here.
