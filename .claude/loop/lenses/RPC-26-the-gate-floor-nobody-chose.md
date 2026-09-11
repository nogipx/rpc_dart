---
refines: U-03
paths: [packages/**/analysis_options.yaml, analysis_options.yaml]
applies: the project has a static-analysis gate configured from a shared preset
breaks: "wrong result: an unchecked implicit downcast from `dynamic` throws at run time where the analyser could have refused it — LATENT on this corpus (round 329), so the damage is a permanently unguarded surface rather than a live defect."
applied: [325, 326, 328]
status: confirmed (round 325)
---

# RPC-26 — The gate's floor is a default nobody chose

## Shape

`melos run analyze` is green, `--fatal-infos` is on, and it reads as strict. It
is not: the package inherits a shared preset (`package:lints/recommended.yaml`),
and nobody has ever asked what that preset LEAVES OUT. The gate's sensitivity is
whatever the preset's authors picked for a general audience, which is
necessarily the intersection of what suits everyone.

## Detector

For each `analysis_options.yaml`: what does the preset omit? Two dials, and they
are independent —

1. `analyzer: language:` — `strict-casts`, `strict-inference`,
   `strict-raw-types`. **No preset turns these on.** They are the type system,
   not style.
2. `linter: rules:` — everything outside the preset.

Turn them on and COUNT. The count is the finding.

## Ask

Does the raised floor catch a class the loop has been finding BY HAND? That is
what separates a real gate from churn.

## Evidence

Core sat on `lints/recommended` plus one rule. Raising the floor reported **320
issues on a tree where `melos run analyze` was green**:

```
                                         lib/    test/ + example/
strict-casts / inference / raw-types      78         130
lint rules outside the preset             34          78
                                         ---         ---
                                         112         208
```

**69 of lib's 112 collapsed into ELEVEN edits**, all the same shape:

```dart
onError: (error, stackTrace) {      // both parameters are `dynamic`
onError: (Object error, StackTrace stackTrace) {
```

An untyped handler makes `error` and `stackTrace` dynamic, and every use
downstream is then an implicit downcast the analyser was not asked to flag. That
is RPC-13's own subject — an abandoned future running user code — sitting
unchecked in sixteen error handlers across core.

> **Reject a rule with the count, not with a feeling.** `close_sinks` (13 hits)
> and `cancel_subscriptions` (6) were measured and left OFF: both track only
> locals within one function, and every hit was a controller held in a field and
> closed elsewhere. Nineteen false positives would have taught the next reader to
> skim the gate. Same for `unnecessary_lambdas` in `test/` — 14 of its 26 hits
> were `expect(() => x.y(), throwsA(...))`, `putIfAbsent(k, () => T())`, or a
> TEST BODY, so it is scoped to `lib/` by a `test/analysis_options.yaml` that
> states the number.

> **A raised floor invites an automated fix, and the fix can destroy
> measurements.** Applied to the tests mid-round, `unnecessary_lambdas` inlined a
> helper to remove one closure and deleted the fifteen-line comment recording a
> measured, still-unfixed deadlock — `CANCEL DEADLOCKED (received=0)` and two
> sibling numbers. Raise the floor and fix by hand, or read the diff of whatever
> fixed it; a rule that can delete evidence has a cost the count does not show.

## Catalog candidate (curate after 327)

`refines: U-03`, but it is not U-03. That shape is a target the gate never
EXECUTES; this one is a target it executes with nothing switched on. Both print
green, and the second is the one nobody looks for.

Nothing in it is Dart-specific: every configurable analyser inherits a preset
someone else chose for a general audience (ESLint, ruff, clippy,
golangci-lint), every one of them has strictness dials outside its preset, and
every one of them silently falls back to a parent config when a unit has none.
A candidate for `catalog/`, not promoted here — that is a change to the SKILL,
and a curate pass touches project data only.

## What this lens does NOT buy — measured in round 329

The `breaks:` line above originally claimed the downcasts throw at run time and
that "a whole class of defect the loop finds by hand is invisible to CI". Round
329 tested both halves and **both were overclaims.**

**It found no live defect.** 534 issues fixed across rounds 325, 326 and 328,
and every test count in the workspace unchanged at each one — `rpc_dart`
`+1435 ~1`, http2 `+204`, websocket `+137`, isolate `+74`. The surface was
latent throughout. That is still worth closing, permanently and for the cost of
three rounds; it is not the same as finding a bug.

**And it does not catch the classes this loop hunts.** Round 242's defect — an
unguarded `.then()` running user code, which ends the isolate when it throws —
is still in `client_connection.dart:432` in the shape RPC-13 describes, and the
floor calls it clean. A three-case probe says why:

```dart
void inVoidFunction()          { work().then((_) {}); }   // not flagged
Future<void> inAsyncFunction() async { work().then((_) {}); }   // FLAGGED
void withNestedVoid()          { void inner() { work(); } ... } // not flagged
```

`unawaited_futures` fires only inside an `async` body. Round 242's site is a
`void` method, which is exactly where a fire-and-forget future is most likely to
be written and least likely to be awaited.

> **A lint floor and a defect lens cover different things, and the overlap is
> smaller than it looks.** Nothing in the floor addresses RPC-01 (credit on
> skip), RPC-05 (charge point), RPC-14 (timeout abandons work), RPC-16 (check
> before await) or RPC-17 (limit after residency) either. Raise the floor for
> the surface it closes cheaply; do not let a green gate read as coverage of the
> classes rounds are spent on.

## The asymmetry worth keeping

The two dials do not cost the same. The type modes found 208 real implicit
downcasts and raw generics; the style rules found 112 mostly-cosmetic ones. **If
only one is ever turned on, turn on `analyzer: language:`** — it is the half
that changes what compiles rather than what reads well.

## The sharper case: no floor at all

**Round 326 took the count over core and transport and found something worse
than a weak preset.** Three packages — `rpc_dart_framework`,
`rpc_dart_grpc_reflection`, `rpc_dart_websocket` — had **no
`analysis_options.yaml` at all**, so they fell through to the repo-root file,
which configured only the formatter. No `include:`, no `linter:`. `melos run
analyze --fatal-infos --fatal-warnings` printed `No issues found!` for a
priority transport with 137 tests because nothing was switched on.

> **Count the packages with NO options file before counting what the preset
> omits.** It reads identically in CI and it is the bigger hole. Of the 211
> issues the floor found across nine packages, **ten violate
> `lints/recommended` itself** — the baseline, not the strict extras — and all
> ten are in two of those three. One is
> `curly_braces_in_flow_control_structures`, the lint `CLAUDE.md` records as
> having once shipped into a published `rpc_dart`; it is in the tree again,
> because that package's gate never had a rule to break.

The fix is one floor, not N copies: `analysis_options_base.yaml` at the repo
root, included by RELATIVE path, plus `analysis_options_test.yaml` for `test/`
directories.

**Round 328 brought in the last two and all 22 packages are now on it.** They
held 3 issues between them, against 211 for the other nine — the packages nobody
had raised were the cleanest in the repo, which is worth knowing before assuming
an unraised package is the worst one.

> **A config that fails to RESOLVE is not necessarily a config that fails to
> APPLY, and the difference is one measurement.** `rpc_dart_generator` has no
> per-package `.dart_tool/package_config.json` (the workspace centralises it),
> and `dart format` does not walk up, so it cannot resolve `package:lints/...`
> in any analysis_options file — the warning predates the shared floor. It reads
> like a hole. It is not: setting `page_width: 100` in the base reformatted the
> generator along with everyone else, so the `formatter:` section arrives. Only
> the half the ANALYSER needs is unresolvable, and `dart analyze` resolves it.
> Change a setting and check whether the target obeys it before filing the hole.
