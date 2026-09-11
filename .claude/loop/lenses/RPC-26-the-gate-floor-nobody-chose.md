---
refines: U-03
paths: [packages/**/analysis_options.yaml, analysis_options.yaml]
applies: the project has a static-analysis gate configured from a shared preset
breaks: "wrong result: an unchecked implicit downcast from `dynamic` throws at run time where the analyser could have refused it, and the class stays invisible to CI so every instance costs a round."
applied: [325, 326]
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
root, included by RELATIVE path (a `package:` URI does not resolve from every
context this repo is analysed in), plus `analysis_options_test.yaml` for `test/`
directories. Still outside it, deliberately: `rpc_dart_wasm` (not a workspace
member, Flutter dependency set, count not taken) and `rpc_dart_generator` (its
`package:lints` include already fails to resolve in some contexts — understand
that before adding indirection).
