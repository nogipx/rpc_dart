---
applies: "Dart code: pub packages, dart2js/AOT targets, isolates"
damage classes: —
shapes: —
contains: "measure.md, tests.md, detectors/log_only_catch.py (instances of U-06 in .dart), assets/probe_template.dart (a probe skeleton: one number, a control flag, RSS)"
---

# dart — language and runtime idioms

> [Packs](../PACKS.md) · schema: [specs/pack.md](../../specs/pack.md) · its
> items extend [measurement.md](../../methods/measurement.md) and
> [tests.md](../../methods/tests.md)

## Contains

`loop.py` appends the two markdown files to their universal counterparts when
the pack is enabled; the other two are run and copied, not read.

- [measure.md](measure.md) — added to the measurement checklist
- [tests.md](tests.md) — added to the regression-test rules
- `detectors/log_only_catch.py` — instances of
  [U-06](../../catalog/U-06-log-only-catch.md) in `.dart` sources
- `assets/probe_template.dart` — a probe skeleton: one number, a control flag,
  RSS
