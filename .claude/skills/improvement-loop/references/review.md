# Review — a clean context before the verdict

> [References](REFERENCES.md) · assembled with the enabled
> [packs'](../packs/PACKS.md) questions by `loop.py review`, not read directly ·
> what it checks is the record: [specs/round.md](../specs/round.md)

Whoever built the bench is inclined to defend it. The most expensive mistakes in
these methods — a policy object shared by both sides, a number taken from the
wrong side, a canary that unexpectedly passed — are errors of judgement, not of
mechanics. So before the verdict, the round record is read by a context that did
not build the bench.

## How to run it

`python3 scripts/loop.py review` assembles the prompt: the core below plus the
enabled packs' questions (`packs/<name>/review.md`) before the bottom line.

- **Claude Code**: a subagent (`Agent`/`Task`) with the assembled prompt; it
  receives only the round record (the draft per `specs/round.md`), the probe
  file, the bench file `P-N` if there is one, and this file. Do not pass the
  round's history.
- **The skill is running in a fork** (subagents unavailable): `claude -p` with
  the same prompt, if the allowlist permits it.
- **None of the above**: do it yourself, marked `review: self — ...`, and only
  after explicitly setting the context aside: re-read the record as a stranger's
  and answer point by point in writing.

The reviewer answers point by point, "yes / no — why". Any "no" sends the round
back to the bench step with the same budget. The outcome goes into the record's
`review:` key: `subagent — 7/7` or `subagent — 8/10: <what was rebuilt>`; the
denominator is the number of questions in the assembled prompt.

## The reviewer prompt

```
You are reviewing the record of an improvement-loop round. You did not build
this bench and you do not know what the author meant to show. Answer every
question "yes" or "no — why", quoting lines from the record or the probe. Do not
propose fixes. Do not praise.

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
   owner decision, not "it was broken before us". For INCONCLUSIVE: the budget
   is exhausted and that is recorded.

Bottom line: "approved N of M" (M is the number of questions above, including
the packs' questions) and the list of items answered "no".
```
