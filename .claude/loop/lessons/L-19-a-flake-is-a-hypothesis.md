---
round: 588
class: process
cost: one round's gate section stated a cause that was wrong by 8x — "load average 11.37" against a control that reads clean at 84.76 — and the lead it filed sent the next round after the wrong variable. The real cause took one probe and three `--concurrency` runs
paths: [packages/core/rpc_dart/test/transports/the_window_counts_wire_bytes_test.dart, .claude/loop/rounds/587-eight-calls-eight-errors.md]
commit: 878c443b
status: active
---

# L-19 — "it is a flake" is a hypothesis, and it names a variable

## The rule

A red that does not reproduce is not explained by calling it a flake. "Flake" is a
claim about a VARIABLE — load, ordering, timing, a cold cache — and like any claim
it owes a control: change that variable deliberately and see the red appear.

Round 587 wrote the variable down (`load average 11.37`) without varying it. Round
588 varied it and the claim collapsed: with 14 busy isolates in another process and
a load average of **84.76**, eight times the figure blamed, the arm read clean.

The actual variable was `dart test`'s own suite concurrency, which is not CPU
pressure from elsewhere:

```
--concurrency=16   green
--concurrency=24   RED, twice, different members each time
--concurrency=32   RED
```

## What made 587's story feel sufficient

Four true facts that are all consistent with the wrong cause:

- the change was in another package and could not reach the failing code
- the file passed alone
- the same gate had been green five times
- the load average was high

Every one survives into the correct explanation. **None of them is evidence about
the variable** — they establish that something environmental is involved, and then
the first environmental word that comes to mind gets written down as the cause.

## The question that settles it in one reading

**What is the MARGIN?** The arm sleeps 250 ms and then requires a sender to be
parked; nobody had measured how long the park needs.

```
settle    5000 us   produced  61   waiters 0
settle   25000 us   produced  66   waiters 1
settle  250000 us   produced  66   waiters 1
```

5-25 ms, so the margin is 10-50x rather than the 250x the number looks like — and a
10x margin is something a 2x-oversubscribed test runner can eat. Asking for the
margin converts "mysteriously flaky" into "insufficient headroom against a named
quantity", which is then fixable.

Corollary, from the same round: **the counter the test throws away is usually the one
that separates the two failure branches.** `waiters == 0` means either the producer
never reached the window or it reached it and was released; `produced` tells them
apart, and the assertion did not report it.

Sibling of `L-14`, from the other side. There the tell was that the red SURVIVED the
remedy a flake would respond to. Here the red responded to a remedy — running alone —
and that was still not enough, because "responds to isolation" does not say WHICH
shared thing it was competing for.
