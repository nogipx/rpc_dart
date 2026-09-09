# Lessons

What a lesson is and how it is promoted into the skill — [../LOOP.md](../LOOP.md).
The record format — `../../skills/improvement-loop/specs/lesson.md`.

The lessons of rounds 1-205 live in private memory and in the skill's methods,
not here. They cannot be filed after the fact — a lesson must have a cost in
numbers, not a retelling.

- **[L-01](L-01-half-a-fix-can-mask-the-other-half.md)** active (round 206), bench — when a fix has two halves, check whether one masks the other's witness
- **[L-02](L-02-vary-the-event-not-the-setup.md)** active (round 207), bench — when the defect is an event, vary the event and not the setup
- **[L-03](L-03-no-backticks-in-a-shell-argument.md)** active (round 210), toolchain — never put a backtick in a shell argument; substitution both mangles the text and defeats the allowlist

## Promotion candidacy — curate pass after round 220

All three hold OUTSIDE this repository, so all three are candidates for the
skill. None has been promoted, because editing `methods/` or
`references/` is a separate SKILL commit and this pass touches project data
only. Each was re-read against its own test — "does the rule hold in any code?"

- **L-01** → `methods/canary.md`. It already says a two-half fix needs two
  canaries; what L-01 adds is the failure mode where one half MASKS the other's
  witness, and the remedy (build the witness so the other half cannot cover).
  Nothing in it is specific to flow control.
- **L-02** → `methods/measurement.md`, next to "the control differs by exactly
  one thing". Its addition is the case where the hypothesis is about a
  TRANSITION: both arms must be asserted equal before they diverge.
- **L-03** → `references/rule-zero.md`, which already forbids substitutions. The
  addition is *why it is worse than a broken string*: it also defeats the
  allowlist and therefore prompts the owner, which is the thing rule zero
  exists to prevent.

Round 218 produced a fourth candidate rule that is NOT yet filed as a lesson,
because its price is recorded in the round rather than counted: prevention and
detection are not interchangeable when the caller's handle is the only thing
identifying the work. If it recurs, file it.
