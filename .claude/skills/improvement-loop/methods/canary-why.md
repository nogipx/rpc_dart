# What paid for each canary item

> [Methods](METHODS.md) · the operative list is [canary.md](canary.md), printed
> by `loop.py brief` · writing the test itself: [tests.md](tests.md) · the
> constraint on switching a fix off in place:
> [references/rule-zero.md](../references/rule-zero.md)

Open a section when its item is the one biting.

## The protocol in full

Switch the fix off IN PLACE with `Edit` (`if (1 > 0) return;`, a raised ceiling,
a flipped flag) -> run the new test -> make sure the witness fails with a REAL
message, not a timeout you invented -> restore it with `Edit`. The failure text
goes into the commit and into the round record.

**Never `git stash`**: rule zero — a failure there needs the user to intervene,
and it is not on the allowlist. If the fix adds new API and the switched-off
tree does not compile, do a surgical canary: keep the declaration, remove the
logic.

## A witness and a guard are different things

- **The witness** MUST fail before the fix. It is the evidence.
- **The guard** passes on both sides. It pins behaviour that must not regress.

Say which is which. A test that passes on both sides proves nothing about the
defect: either isolate it, or call it a guard and stop presenting it as
evidence.

## A fix in two halves needs two canaries

A bound that is added but never RELEASED still stops the attack: the attack
witness stays green while the ceiling silently squeezes honest traffic.

It was the release canary that revealed its own guard was empty — 17-byte
payloads, 670 bytes over 40 iterations, never anywhere near a 64 KiB ceiling, so
the test passed with the release switched off.

> **When a canary unexpectedly passes, the TEST is wrong, not the code.** Check
> the QUANTITY through a metric, not its indirect consequence.

## A guard that can FAIL OPEN needs an attacking witness

A happy-path test cannot tell a working guard from a disabled one. The same
guard came out non-functional twice: first a silent no-op through mishandling
the preamble, then a direction flag whose wrong value switched it off. Both
times "ordinary traffic still works" passed.

> **If the fix has a mode, a flag or an offset that can be set wrongly, canary
> THOSE, not just the fix's absence.**

## A canary that leaves the OTHER tests green is a virtue

A new witness fired at 151.9 MiB in the client while four earlier tests under
the same canary kept passing, because they measure the other side, already
fixed. That separation is what proves the new test isolates a NEW defect. Check
it deliberately when adding a test to a file that already holds a neighbouring
bug.

## A new test can be a probe

A control hit the test's 90-second ceiling even though its call had a 3 s
deadline, and that localised a close hang in teardown no probe was aiming at.

> **When a test takes far longer than its own deadlines allow, that gap IS the
> measurement.** Deal with it before blaming a slow machine.

## An existing test that fails on your change may be RIGHT

Read its justification before touching it. A change that made an oversized
inbound frame fail one call instead of closing the connection broke a test whose
wording was "a surviving connection is an unbounded source of peaks" — a
measured objection from an earlier round.

Both positions were correct, because they spoke about **different sides**: the
old test drove a hostile client into the SERVER, the new battery drove a
legitimate server into the CLIENT. The answer was to bind the behaviour to the
side, and no test had to be weakened.

> **When an existing test contradicts the fix, ask which SITUATION it measured.**
> If it names an actor, a direction or a trust relationship, the fix probably
> concerns a different one, and the right shape is a split, not a replacement.

**But a test can also be pinning the defect itself.** Two tests went red when a
branch was removed that made a call skip the declared codecs. Neither had a
situation axis: one claimed "no serialization on this transport" while
explicitly PASSING codecs, the other built its fixture on the defect.

> **Do not trust a test whose claim stands only on what you are removing.** The
> fixture gives it away: it needs the broken path to assemble the scenario.

## Re-measure your own deferrals

"Open, deliberately not fixed" freezes the state of the code on the day it was
written; later unrelated fixes move that state and nobody comes back.

- **Check the stated blocker.** A fix deferred twice on "it will break the
  neighbouring feature" shipped the moment one grep showed that feature has its
  own implementation and never touches the code being changed. A deferral with
  an unchecked blocker is a guess dressed as a reason.
- **The check can also CONFIRM the blocker, and enlarge it.** Both outcomes are
  worth a round: the point is to find out which one you have.
- **The NUMBER goes stale too**, and re-running the original probe can wrongly
  CLOSE a real defect — see the latency trap in `measurement-why.md`.
- **A deferral justified by "nobody needs this any more" expires the moment
  somebody does.** It is a claim about a SET THAT GROWS.

## Before shipping: measure REACHABILITY and be ready to revert

A real fix for a silent truncation was written and thrown away: it is reachable
only from a foreign peer of the library's private protocol, and the fix rewrote
a path core depends on. The same defect class, where the peers are third-party
proxies, got the opposite answer.

> **When the blast radius exceeds the exposure, write it down for the owner
> rather than pushing it through by editing the test that disagrees.**
