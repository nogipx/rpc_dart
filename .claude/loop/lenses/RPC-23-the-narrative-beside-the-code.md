---
refines: U-22
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: a doc comment carries the search that produced the code
breaks: "wrong result: the comment is read as current when it records one moment, and the thing a caller needs is buried in it."
applied: [293, 294]
status: confirmed (round 293)
---

# RPC-23 — The narrative beside the code

## Shape

A doc comment that tells the story of how the code came to be: the measurement,
the arms, the wrong turn, the sibling that had it right. Every sentence was true
when written. Together they are unreadable by the person the comment is for, and
unmaintainable by the person who changes the code.

The tell is a comment that answers *how did we find this* rather than *what do I
pass here*.

## Detector

Per file, `/// ` lines against total lines. Above ~20% the file is prose with
code in it. Then, per doc comment, three questions:

1. **Is there a measured table in it?** A table is a record of one run, on a tree
   that has moved. It belongs in the round record, which is dated and which
   `stale` ages; the comment cannot be aged by anything.
2. **Does it name rounds, commits, siblings or "an earlier version of this
   comment"?** That is journal content addressed to a reader who has the journal.
3. **Could a caller choose a value without it?** Keep exactly what answers that
   plus the one limitation that changes the choice. Everything else goes.

## Ask

If this comment were deleted, what would the next caller get wrong?

Whatever survives that question is the comment. It is usually three to six
lines, and for a field it is usually: what it bounds, why the default is what it
is, and the one case where the obvious value is wrong.

## Evidence

**`RpcSecurityPolicy`, round 293.** 236 doc lines in a 451-line file — every
field an essay with its own measurements. Four fields carried 127 of them:

    field                        before  after
    maxActiveStreams                 33      7
    maxConcurrentHandlers            43     11
    closeOnProtocolError             17     10
    halfOpenStreamTimeout            34     13

    file total                      236    151

Nothing was lost: the tables live in rounds 205, 213-215 and 245, which is where
a reader who wants the history should have to go, and which `loop.py stale` ages
against the code. What a caller needs — this bounds stream STATE not running
handlers, use `maxConcurrentHandlers` for the work; null by default because
turning it on trades slow for refused — survives in a quarter of the space.

> **The comment cannot be aged, so it must not carry what ages.** A measured
> table beside the code is a claim with a timestamp nobody can see. The journal
> has dates, shas and a linter; the comment has none of those, and rule one
> already says prose goes stale silently. That applies hardest to prose that
> looks like evidence.

Baseline for the mandate, `rpc_dart/lib/src`: **4430 doc lines in 24049 total,
18.4%.**

## What NOT to cut

A comment earns its place by saying what BREAKS if the code is undone — one or
two lines, per `config.md`. That is not narrative and it is the thing most worth
keeping: `_reject`'s "dart:io tears the connection down before the status is
flushed" is why the drain exists, and a future reader who deletes the drain
without it will reintroduce the bug.

Cut the how-we-found-it. Keep the what-breaks-if-you-undo-it.
