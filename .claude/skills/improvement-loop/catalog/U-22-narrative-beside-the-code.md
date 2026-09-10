---
pack: refactor
applies: the code carries doc comments written by whoever investigated it.
breaks: "wrong result: the comment reads as current when it records one moment, and what a caller needs is buried in it."
status: confirmed
---

# U-22 — The narrative beside the code

> [Catalog](CATALOG.md) · instantiate before use:
> [lens-derivation](../methods/lens-derivation.md) · schema:
> [specs/lens.md](../specs/lens.md)

## Shape

A doc comment that tells how the code came to be — the measurement, the arms,
the wrong turn, the sibling that had it right — rather than what to pass. Every
sentence was true when written; together they are unreadable by the caller and
unmaintainable by the next editor.

## Detector

`///` lines against total lines, per file. Then per comment: does it contain a
measured table, does it name commits or investigations, and could a caller
choose a value without it?

## Ask

If this comment were deleted, what would the next caller get wrong? That answer
is the comment; the rest is journal.

## Evidence

A policy class at 236 doc lines in 451 total; four fields held 127 of them.
Rewritten to 151 with nothing lost, the tables having moved to the dated records
that a staleness check can age. **A comment cannot be aged, so it must not carry
what ages** — and a measured table beside the code is a claim with a timestamp
nobody can see.

Keep the one or two lines saying what BREAKS if the code is undone. Cut the
how-it-was-found.
