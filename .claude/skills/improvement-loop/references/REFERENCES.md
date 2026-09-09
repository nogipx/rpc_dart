# References

Back to [SKILL.md](../SKILL.md). These are read on demand rather than every
round: the vocabulary, the one hard constraint, and the reviewer's core prompt.

- **[model.md](model.md)** — the terms and how they relate. Entities, artefacts
  and procedures are three different kinds of thing, and confusing them is the
  main source of misunderstanding; the file also carries the two diagrams (what
  produces what, and a lens's lifecycle). Read on first contact, and whenever a
  term in a round feels uncertain.
- **[rule-zero.md](rule-zero.md)** — a command must never ask for permission.
  What the allowlist does not cover and why each exclusion is there. Read before
  writing any shell command; it is the constraint that stops an unattended round
  dead.
- **[review.md](review.md)** — the core of the reviewer prompt, the questions a
  clean context puts to a round before its verdict. Not read directly: `loop.py
  review` assembles it with the enabled [packs'](../packs/PACKS.md) questions.

The schemas for the project's files are in [specs](../specs/SPECS.md); how to do
the work is [methods](../methods/METHODS.md).
