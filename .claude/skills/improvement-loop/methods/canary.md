# A canary for every fix

> [Methods](METHODS.md) · at the **Witness and canary** step · writing the test
> itself: [tests.md](tests.md) · the constraint on switching a fix off in place:
> [references/rule-zero.md](../references/rule-zero.md)

## Checklist — at the Witness and canary step

1. Switch the fix off IN PLACE with `Edit` (`if (1 > 0) return;`, a raised
   ceiling, a flipped flag). Never `git stash`. If the switched-off tree does
   not compile, do a surgical canary: keep the declaration, remove the logic.
2. Run the new test. The witness fails with a real message, not with a timeout.
   The failure text goes into the commit and into the round record.
3. Restore it with `Edit`. Run again: green.
4. Name which one is the witness and which is the guard. A test that passes on
   both sides proves nothing about the defect.
5. A fix in two halves (bound and release, entry and exit) needs two canaries,
   one per half.
6. If the fix has a flag, a mode or an offset that can be set wrongly, canary
   THAT, not just the fix's absence.
7. A canary that unexpectedly passes means the test is wrong, not the code.
   Check the QUANTITY through a metric, not through an indirect consequence.
8. The other tests staying green under the canary is a virtue: the new test
   isolates the new defect.
9. If an existing test fails on the fix, read which situation it measured before
   touching it. If it names a side or a direction, the answer is a split, not a
   replacement. If it stands only on what you are removing, it was pinning the
   defect.
10. Before shipping, measure reachability: if the blast radius exceeds the
    exposure, that is for the owner — do not push it through.
11. Every attempt to get a failing witness adds one to `budget:`. If the budget
    from the config («canaries: N») is exhausted with no failing witness, the fix
    is not proven: the verdict is INCONCLUSIVE, or DEFERRED with reason "bench".
12. Before the verdict, a review by a clean context (`references/review.md`); a
    "no" about the canary sends you back to item 1 with the same budget.

`loop.py next` adds the enabled packs' items to this list. Below is what paid
for each item.

**The protocol.** Switch the fix off IN PLACE with `Edit` (`if (1 > 0) return;`,
a raised ceiling, a flipped flag) -> run the new test -> make sure the witnesses
fail with a REAL message, not with a timeout you invented for yourself ->
restore it with `Edit`. The failure text goes into the commit and into the round
record.

**Never `git stash`** (rule zero: a failure there needs the user to intervene,
and `git stash` is not on the allowlist). If the fix adds new API and the
switched-off tree does not compile, do a surgical canary: keep the new
declaration, remove only the fix's logic.

## A witness and a guard are different things

- **The witness** MUST fail before the fix. It is the evidence.
- **The guard** passes on both sides. It pins behaviour that must not regress.

Say which is which. A test that passes on both sides proves nothing about the
defect: either isolate it (switch off another limit that masked the violation)
or call it a guard and stop presenting it as evidence.

## A fix in two halves needs two canaries

A bound that is added but never RELEASED still stops the attack: the attack
witness stays green while the ceiling silently squeezes honest traffic. Canary
the bound and the release separately.

It was the release canary that revealed its own guard was empty: 17-byte
payloads, 670 bytes over 40 iterations, never anywhere near a 64 KiB ceiling —
the test passed with the release switched off.

> **When a canary unexpectedly passes, the TEST is wrong, not the code.** The
> fix is to check the QUANTITY through a metric, not just its indirect
> consequence.

## A guard that can FAIL OPEN needs an attacking witness

A happy-path test cannot tell a working guard from a disabled one. The same
guard came out non-functional twice: first as a silent no-op through mishandling
the preamble, then through a direction flag whose wrong value switched it off.
In both cases the test "ordinary traffic still works" passed.

> **If the fix has a mode, a flag or an offset that can be set wrongly, canary
> THOSE, not just the fix's absence.**

## A canary that leaves the OTHER tests green is a virtue

The new witness fired at 151.9 MiB in the client, while four earlier tests under
the same canary kept passing, because they measure the other side, already
fixed. That separation is exactly what proves the new test isolates a NEW
defect rather than re-checking an old one. Check this deliberately when adding a
test to a file that already holds a neighbouring bug.

## A new test can be a probe

Twice a finding came from a test TIMEOUT rather than from a planned experiment:
the control hit the test's 90-second ceiling even though its call had a 3 s
deadline, and that localised a close hang in teardown that no probe was aiming
at.

> **When a test takes far longer than its own deadlines allow, that gap IS the
> measurement.** Deal with it before blaming a slow machine.

## An existing test that fails on your change may be RIGHT

Read its justification before touching it. A change that made an oversized
inbound frame fail one call instead of closing the connection broke an existing
test whose wording was "a surviving connection is an unbounded source of peaks".
That was a MEASURED objection from an earlier round.

Both positions were correct, because they spoke about **different sides**: the
old test drove a hostile client into the SERVER, the new battery drove a
legitimate server into the CLIENT. The answer was to bind the behaviour to the
side, and no test had to be weakened.

> **When an existing test contradicts the fix, first ask which SITUATION it
> measured.** If it names an actor, a direction or a trust relationship, the fix
> probably concerns a different one, and the right shape to ship is a split, not
> a replacement.

**But a test can also be pinning the defect itself.** Two tests went red when a
branch was removed that made a call skip the declared codecs. Neither had a
situation axis: one claimed "no serialization on this transport" while
explicitly PASSING codecs, and the other built its fixture on the defect itself.

> **Do not trust a test whose claim stands only on what you are removing.** The
> fixture usually gives it away: it needs the broken path to assemble the
> scenario at all.

## Re-measure your own deferrals

A record saying "open, deliberately not fixed" freezes the state of the code on
the day it was written, later unrelated fixes move that state, and nobody comes
back. Two rounds in a row found real defects exactly this way: one deferral had
already dissolved on two implementations out of three, and another described
what the code did incorrectly AND its blocker no longer held — with silent data
loss hiding behind it.

- **Check the stated blocker.** A fix deferred twice on the excuse "it will
  break the neighbouring feature" shipped the moment one grep showed that
  feature has its own implementation and never touches the code being changed. A
  deferral with an unchecked blocker is a guess dressed as a reason.
- **The check can also CONFIRM the blocker, and enlarge it.** Another blocker
  turned out to be real and BIGGER than recorded. Both outcomes are worth a
  round: the point is to find out which one you have.
- **It is not only the blocker that goes stale but the NUMBER**, and re-running
  the original probe can wrongly CLOSE a real defect — see the latency trap in
  `measurement.md`.
- **A deferral justified by "nobody needs this any more" expires the moment
  somebody else does.** It is a claim about a SET THAT GROWS. Re-check it
  whenever you add to whatever it depends on.

## Before shipping: measure REACHABILITY and be ready to revert

A real fix for a silent truncation was written and thrown away: it is reachable
only from a foreign peer of the library's private protocol (with the library on
both sides the server always sends a status — measured), and the fix itself
rewrote a path core depends on. The same defect class, where the peers are
third-party proxies and servers, got the opposite answer.

> **When the blast radius exceeds the exposure, write it down for the owner
> rather than pushing it through by editing the test that disagrees.** The
> conflict surfaced on a full suite run; running only your own package would
> have let the fix out.
