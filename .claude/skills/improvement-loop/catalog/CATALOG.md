# Universal catalog of shapes

> Back to [SKILL.md](../SKILL.md) · the packs that make a shape available:
> [packs/PACKS.md](../packs/PACKS.md) · how a shape becomes a lens:
> [methods/lens-derivation.md](../methods/lens-derivation.md)

Defect shapes by pack. The `pack:` key says which enabled pack makes a shape
available to `lenses` mode (`loop.py catalog`). The field schema is
`../specs/lens.md`; a catalog shape has no `paths:` and no `applied:` — those
appear when it is instantiated into a project's set, together with a real
detector.

**A shape here is not applied directly.** It has no detector for any particular
code: the `## Detector` section describes the WAY to search, not the symbols.
Before use, a shape is instantiated into the project's set —
`.claude/loop/lenses/` — with real paths, names and commands, and gets
`refines: <U-ID>`. The procedure is `../methods/lens-derivation.md`.

Statuses here are cross-project: `confirmed` means "paid for by a real finding
in at least one project". Round numbers live in the project's set and journal.

The evidence gives the size of a finding without its provenance: a rule with no
size is easy to talk away, while a size carries anywhere.

The order roughly descends by yield, but it is a hint rather than a queue: look
at the least-explored surface first.

## core — holds in any code

- **[U-01](U-01-comment-justifying-deliberateness.md)** — a comment justifying deliberateness is a lead, not a closed door
- **[U-02](U-02-attack-your-own-fix.md)** — attack your own fix, and again in the next round
- **[U-03](U-03-target-nobody-runs.md)** — a target nobody runs: reading < compiling < running
- **[U-04](U-04-unregistered-extension-point.md)** — a dependency callback nobody registered
- **[U-05](U-05-capability-hidden-by-wrapper.md)** — a capability hidden by a wrapper: `is IFoo` silently fails
- **[U-06](U-06-log-only-catch.md)** — a log-only `catch` on a path that later reports success
- **[U-12](U-12-rerouted-path-drops-guards.md)** — a rerouted path drops the old one's guards
- **[U-14](U-14-compare-siblings-signal-vs-handling.md)** — compare siblings; an absent defect may mean an absent signal
- **[U-15](U-15-lifecycle-twice.md)** — drive the lifecycle APIs twice
- **[U-17](U-17-unbounded-wait-abandoned-work.md)** — an unbounded wait, and work abandoned by a timeout
- **[U-18](U-18-silent-acceptance-of-programmer-error.md)** — silent acceptance of a programmer error
- **[U-19](U-19-parity-matrix.md)** — the parity matrix: holes live in combinations
- **[U-20](U-20-leak-accounting-to-baseline.md)** — leak accounting against a baseline; wait for the rise first
- **[U-21](U-21-remeasure-own-deferrals.md)** — re-measure your own deferrals and "checked" marks

## async-io — two sides, a channel, limits, waits

- **[U-07](U-07-abort-became-continue.md)** — "abort" became "continue": all the accounting moved onto you
- **[U-08](U-08-happy-path-limit-on-error-path.md)** — a happy-path limit is wrong on the error path
- **[U-09](U-09-refusal-must-pass-its-own-rule.md)** — a refusal must pass the rule it enforced
- **[U-10](U-10-new-option-new-combinations.md)** — a new option makes new combinations reachable
- **[U-11](U-11-shared-producer-per-shape-consumers.md)** — a shared producer with per-shape consumers is a matrix
- **[U-13](U-13-mirror-of-a-paid-battery.md)** — run the mirror of a battery that already paid off
- **[U-16](U-16-write-and-answer-in-one-wait.md)** — the write and the answer in one wait; a deadline that never fires

A new shape's number is the maximum plus one. A shape lands here only once a
real finding has paid for it in at least one project; `curate` mode names the
candidates.
