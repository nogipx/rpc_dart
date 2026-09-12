# Items — checklist lines that need a trait

Back to [SKILL.md](../SKILL.md). The universal checklists are
[methods/](../methods/METHODS.md); the vocabulary these draw on is
[references/traits.md](../references/traits.md).

An **item** is a checklist line that only applies to some projects. It lives in
a file named `<key>-<slug>.md`, where the key is `measure`, `canary`, `tests` or
`review` — the checklist it extends — and the frontmatter says which
[traits](../references/traits.md) it needs:

```
---
needs: two-sided-protocol
---

A1. ...
```

`loop.py brief` (and `loop.py review`) concatenate every file whose `needs:` the
project's `traits:` cover, straight onto the universal checklist, and then
**name every file they held back and the trait that would have admitted it**. A
checklist that is quietly short looks exactly like a complete one; that report
is the only defence.

## The rules

- **An items file holds frontmatter and items, nothing else.** No heading, no
  breadcrumb, no prose — it is concatenated whole into a checklist a round
  reads, or into a prompt a model answers. The stories go in the `-why` file
  beside it, which the script never opens.
- **`needs:` is an AND.** Where items in one file would need different traits,
  split the file: both halves are found by the key's glob.
- **A project extends this.** Its own items go in `.claude/loop/items/`, with
  `local traits:` in `config.md` for a name the registry has no word for. The
  script reads both directories.

## measure — extends [methods/measurement.md](../methods/measurement.md)

- [measure-async.md](measure-async.md) *(two-sided-protocol)* ·
  [why](measure-async-why.md)
- [measure-dart.md](measure-dart.md) *(dart)* · [why](measure-dart-why.md)

## canary — extends [methods/canary.md](../methods/canary.md)

- [canary-limits.md](canary-limits.md) *(byte-limits)* ·
  [why](canary-limits-why.md)

## tests — extends [methods/tests.md](../methods/tests.md)

- [tests-async.md](tests-async.md) *(two-sided-protocol)* ·
  [why](tests-async-why.md)
- [tests-limits.md](tests-limits.md) *(byte-limits)* ·
  [why](tests-limits-why.md)
- [tests-dart.md](tests-dart.md) *(dart)* — its story is the fixture section of
  the universal [methods/tests-why.md](../methods/tests-why.md), which is where
  the control-character trap was paid for
- [tests-dart2js.md](tests-dart2js.md) *(dart2js)* ·
  [why](tests-dart2js-why.md)

## review — extends [references/review.md](../references/review.md)

- [review-async.md](review-async.md) *(two-sided-protocol)*
- [review-limits.md](review-limits.md) *(byte-limits)*

## assets

- [assets/probe_template.dart](assets/probe_template.dart) — a probe skeleton:
  one number, a control flag, RSS at three scales. Copied, not read.
