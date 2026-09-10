---
pack: refactor
applies: the code carries comments written by whoever investigated it.
breaks: "wrong result: the comment reads as current when it records one moment, and what a caller needs is buried in it."
status: confirmed
---

# U-22 — The narrative beside the code

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

## Shape

A comment that tells how the code came to be — the measurement, the arms, the
wrong turn, the sibling that had it right — rather than what to pass or what not
to break. Every sentence was true when written; together they are unreadable by
the caller and unmaintainable by the next editor.

## Detector

**ALL comment lines, not just the documentation ones**, against total lines, per
file. Then per comment: does it contain a measured table, does it name commits
or investigations, and could a caller choose a value without it?

Counting only the doc-comment syntax measures a fraction of the problem, and
reports files finished that are not. The narrative lives in the block INSIDE the
method, beside the line it explains — which is where a measurement table
naturally ends up, because that is where the author was standing when they
learned it. Measured on one library: 27.6% of all lines were comment; the
doc-only metric said 18.4%.

## Ask

If this comment were deleted, what would the next caller get wrong? For internal
code there is no caller — ask what the next EDITOR would break without knowing.
That answer is the comment; the rest is journal.

## Evidence

A policy class at 236 doc lines in 451 total; four fields held 127 of them.
Rewritten to 151 with nothing lost, the tables having moved to the dated records
that a staleness check can age. **A comment cannot be aged, so it must not carry
what ages** — and a measured table beside the code is a claim with a timestamp
nobody can see. The same applies to a line-number reference: one such comment
cited `":1166-1174"` for a rule that had since moved.

Sweeping whole files rather than single blocks also exposes what only adjacency
shows: a comment fused to the declaration below the one it describes, a block
duplicated verbatim, the same measurement written twice in one file.

Keep the one or two lines saying what BREAKS if the code is undone. Cut the
how-it-was-found.
