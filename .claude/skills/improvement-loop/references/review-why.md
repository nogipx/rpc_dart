# Why the verdict check looks like this

> [References](REFERENCES.md) · the prompt itself is [review.md](review.md),
> assembled with the [trait-gated](../items/ITEMS.md) questions by
> `loop.py review` · what it checks is the record:
> [specs/round.md](../specs/round.md)

Whoever built the bench is inclined to defend it. The expensive mistakes in
these methods — a policy object shared by both sides, a number taken from the
wrong side, a canary that unexpectedly passed — are errors of judgement, not of
mechanics. Q2 is the question that earns its keep: *did the control show the
bench can SEE the defect*.

**This is a self-check, deliberately.** A version that demanded a clean context
and a `review:` key recording the score was answered `self` thirty-nine times
out of thirty-nine. A step satisfied nominally every time is worse than no step,
because it reads as evidence.

## How to run it

`python3 scripts/loop.py review` prints `references/review.md` followed by every
items file named `review*` whose `needs:` this project's [traits](traits.md)
satisfy. Whole files, concatenated. Questions held back for a missing trait are
listed after the prompt, never dropped in silence.

Answer point by point **in writing**, quoting the record and the probe rather
than recalling them — the answers are the check, not the intention to have
checked. Any "no" sends the round back to the **Bench** step. Nothing is
recorded when every answer is "yes": the round's own sections already carry the
control, the numbers and the canary message that the questions ask about.

Handing the assembled prompt to a subagent is allowed and sometimes worth it —
for a wide fix, or when the numbers came out exactly as hoped. It is a choice,
not a step: passing it on does not excuse you from reading the answers.
