# References

Back to [SKILL.md](../SKILL.md). These are read on demand rather than every
round: the vocabulary, the one hard constraint, and the core of the verdict
check.

- **[model.md](model.md)** — the terms and how they relate. Entities, artefacts
  and procedures are three different kinds of thing, and confusing them is the
  main source of misunderstanding; the file also carries the two diagrams (what
  produces what, and a lens's lifecycle). Read on first contact, and whenever a
  term in a round feels uncertain.
- **[traits.md](traits.md)** — the shared vocabulary a project uses to say what
  it IS. A project declares these in `traits:`, its own names in
  `local traits:`, and every items file that asks for no more than those is
  merged into `loop.py brief`. The registry exists to catch a typo, not to limit
  anybody: the vocabulary is open, and a project extends it.
- **[rule-zero.md](rule-zero.md)** — a command must never ask for permission.
  What the allowlist does not cover and why each exclusion is there. Read before
  writing any shell command; it is the constraint that stops an unattended round
  dead.
- **[review.md](review.md)** — the seven questions a round answers against its
  own record before the verdict. **The whole file is the prompt** — no title, no
  prose — because `loop.py review` prints it verbatim followed by the enabled
  [trait-gated](../items/ITEMS.md) questions, and anything in it that is not an
  instruction would be noise inside that prompt. Why the check exists and why
  the file is shaped this way: [review-why.md](review-why.md).

The schemas for the project's files are in [specs](../specs/SPECS.md); how to do
the work is [methods](../methods/METHODS.md).
