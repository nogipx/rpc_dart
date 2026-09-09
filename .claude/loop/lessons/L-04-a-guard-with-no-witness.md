---
round: 223 — where it was paid for; the first half was round 222, and round 225 amended it
class: bench
cost: 2 rounds of ablation, each of which planted a real defect and got a green suite — 222 removed `_detached`'s `.catchError` (+1395 ~1, all other tests passed), 223 removed the isolate's startup `teardownStartup()` (+73, all tests passed). Round 225 added the amendment below at the cost of 2 subprocess witnesses built and discarded
paths: []
commit: 0e7b984a
status: active
---

# L-04 — a guard with no witness, and how the ablation finds it

Q4's ablation exists to prove the instrument could have seen the defect. When
the sweep's verdict is "every site is guarded", that same ablation answers a
second question for free, and it is the more interesting one: **remove the
guard, and does anything go red?**

Twice in a row, nothing did.

```
222  _detached .catchError removed, core suite:        +1395 ~1, all passed
223  isolate startup teardown removed, isolate suite:  +73,      all passed
```

Both guards exist because of a measured production failure — two replicas
exiting 255 within hours of each other, and a leaked isolate that keeps the host
process alive. Both can be deleted and shipped green.

That is not a coincidence twice. It is structural: **a guard against a LEAK or a
CRASH has to be witnessed by an absence** — no process death, no surviving
isolate, no growing RSS — and the ordinary suite shape cannot express an absence
from inside the process under test. A test that asserts "the isolate did not
die" runs in the isolate that would have died. So the guards that matter most
are exactly the ones the suite is structurally unable to cover, and their sweeps
read CLEAN while being one careless refactor from regressing.

## The rule

After a sweep concludes a guard family is fully guarded, ablate one guard before
writing the verdict. A green suite is a finding in its own right — file it — and
the verdict's wording has to carry it: not "this class cannot arise" but "this
class does not arise today, and nothing would notice if it started".

## Amended by round 225: a green ablation has TWO explanations

Round 225 set out to write the witness this lesson called for, and could not —
because the guard is never reached. `_detached` was instrumented to print on
rejection and driven through three scenarios; **not one handed it a rejected
future**, because all 25 expressions it wraps are guarded from the inside.

So "I removed the guard and nothing went red" means one of:

1. **Untested** — the path is live and no test drives it. Write the witness.
2. **Unreachable** — the path cannot produce the failure, because something
   inner already handles it. There is nothing to witness, and trying costs
   rounds.

They look identical from the ablation alone. **Tell them apart before writing a
witness, not after**: instrument the guard to report when it actually fires, and
run the scenarios. If it never fires, stop — the answer is a negative
([C-24](../checked/C-24-detached-guard-is-unreachable.md)), not a test.

The cost of not doing this first was two subprocess witnesses built and thrown
away, both aimed by reading the code rather than by measuring it — which is the
older lesson this repository already learned as "measure every hop, don't reason
about which one is wrong".

## The remedy, when the witness is worth writing

Drive the failure in a **subprocess** and assert on its exit code and its
lifetime, not on anything visible from inside. `rpc_dart_isolate` already owns
that harness — `close_releases_the_isolate_test.dart` — and it is the shape both
outstanding leads need:
`../backlog/B-20-detached-guard-has-no-witness.md` for core, and the closing
note on `../backlog/B-04-isolate-future-timeout-unaudited.md` for the isolate
startup path.

## Where it does NOT apply

A guard whose failure is a wrong VALUE, not an absence, is ordinarily testable
and this lesson says nothing about it. The rule is scoped to guards whose
failure mode is that something keeps existing, or stops existing, outside the
assertion's reach.
