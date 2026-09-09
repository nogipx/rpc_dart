# The seven questions before the verdict

> [References](REFERENCES.md) · assembled with the enabled
> [packs'](../packs/PACKS.md) questions by `loop.py review`, not read directly ·
> what it checks is the record: [specs/round.md](../specs/round.md)

Whoever built the bench is inclined to defend it. The most expensive mistakes in
these methods — a policy object shared by both sides, a number taken from the
wrong side, a canary that unexpectedly passed — are errors of judgement, not of
mechanics. The questions below are what catches them, and Q2 is the one that
earns its keep: *did the control show the bench can SEE the defect*.

**This is a self-check, deliberately.** It used to demand a clean context — a
subagent, or `claude -p` from a fork — and a `review:` key recording the score.
Thirty-nine rounds out of thirty-nine wrote `review: self`, so the ceremony went
and the questions stayed. A step that is satisfied nominally every time is worse
than no step, because it reads as evidence.

## How to run it

`python3 scripts/loop.py review` assembles the prompt: the core below plus the
enabled packs' questions (`packs/<name>/review.md`) before the bottom line.

Answer point by point **in writing**, quoting the record and the probe rather
than recalling them — the answers are the check, not the intention to have
checked. Any "no" sends the round back to the **Bench** step. Nothing is
recorded when every answer is "yes": the round's own sections already carry the
control, the numbers and the canary message that the questions ask about, and a
score beside them would be a second copy of the same fact.

Handing the assembled prompt to a subagent is allowed and sometimes worth it —
for a wide fix, or when the numbers came out exactly as hoped. It is a choice,
not a step: passing it on does not excuse you from reading the answers.

## The prompt

```
You are checking the record of an improvement-loop round before its verdict.
Read it as a stranger's: what the author meant to show does not count, only what
the record proves. Answer every question "yes" or "no — why", quoting lines from
the record or the probe. Do not propose fixes. Do not praise.

1. Does the control differ from the case under test by exactly one thing — the
   removed suspected mechanism? Name anything else that differs.
2. Did the control show the bench is ABLE to see the defect (a number different
   from the case under test)? If the control and the case showed the same
   thing, the bench is not valid.
3. Is the number taken on the library's side rather than the bench's? Name
   where exactly it is counted.
4. If it is zero or "bounded", is it proven that the mechanism could emit
   anything at all and that the observation window is long enough?
5. Did the witness fail with a real message when the fix was switched off,
   rather than with a timeout? Quote the message from the record.
6. If the fix has two halves, are there two canaries?
7. Does the verdict follow from the numbers rather than from expectation? For
   CLEAN: there is a valid control. For DEFERRED: the reason is cost, risk or an
   owner decision, not "it was broken before us". For INCONCLUSIVE: the record
   says what was tried and why none of it produced a valid number.

Bottom line: the list of items answered "no", or "nothing to send back".
```
