---
round: 325
verdict: FIXED
packages: [rpc_dart]
lens: RPC-26
bench: none
commit: yes
---

# Round 325 — the gate was green because it was not looking

## Target

The owner, mid-round: raise code cleanliness in core, then "make the linter the
strictest". That replaced the queued `curate` pass, which stays owed.

Core's doc ratio is already **4018 of 23318 lines, 17.2%**, down from RPC-23's
18.4% baseline, and rounds 308-318 swept its abstractions. So "cleanliness" was
not going to come from another reading of the same files — it had to come from
the instrument.

## Hypothesis

`melos run analyze` runs with `--fatal-infos --fatal-warnings` and is green, so
it reads as strict. It is not: core inherits `package:lints/recommended.yaml`
plus one rule, and nobody has ever asked what that preset leaves out.

## Before

Two independent dials, raised together on a green tree:

```
                                         lib/    test/ + example/   total
analyzer language modes
  argument_type_not_assignable            35          5
  inference_failure_on_untyped_parameter  34          -
  inference_failure_on_instance_creation   -        141
  strict_raw_type                          9         10
  inference_failure_on_collection_literal  -          6
  inference_failure_on_function_invocation -          4
  invalid_assignment                       -          2
                                          --        ---
                                          78        168

lint rules outside the preset
  prefer_final_locals                     10          1
  unnecessary_lambdas                      9         26
  directives_ordering                      7          4
  unnecessary_await_in_return              4          -
  unawaited_futures                        4          7
  unnecessary_parenthesis                  -          2
                                          --        ---
                                          34         40

                                   TOTAL 112        208     320
```

## Mechanism

**69 of lib's 112 collapsed into eleven edits**, all one shape:

```dart
onError: (error, stackTrace) {                      // both are `dynamic`
onError: (Object error, StackTrace stackTrace) {
```

An untyped handler makes both parameters dynamic, and every use downstream is an
implicit downcast nobody asked the analyser to flag. Sixteen error handlers
across core were written that way — which is RPC-13's own subject, an abandoned
future running user code, sitting unchecked in the gate.

The test tail had the same property: **123 of its 141 inference failures were
one pattern**, `Future.delayed(...)` with no type argument, where `lib/` already
writes `Future<void>.delayed(...)`. The tests had drifted from the library's own
convention and nothing could see it.

Five were genuine implicit downcasts rather than style — `TestRequest(json['message'])`
into a `String` parameter, `current = current['nested']` into a
`Map<String, dynamic>`, `closeTo(list[i], 0.000001)` into a `num`.

## After

```
melos run analyze         21 packages + rpc_dart_wasm   clean
rpc_dart, whole package   0 issues under the raised floor
rpc_dart tests            +1435 ~1, unchanged
```

The floor now on core: `strict-casts`, `strict-inference`, `strict-raw-types`,
plus fourteen lint rules over the preset.

## Canary

One handler put back to `onError: (error, stackTrace)` — **5 issues on that file
alone**: three `argument_type_not_assignable` and two
`inference_failure_on_untyped_parameter`. The floor rejects exactly what it was
raised for.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures. `rpc_dart` itself is
`+1435 ~1` — unchanged, so none of the 320 edits moved behaviour. Re-run in full
after reverting the automated fix described below.

## Not fixed

**Two rules were measured and deliberately left OFF, which is the part that
keeps the gate worth reading.**

- `close_sinks` (13 hits) and `cancel_subscriptions` (6): both track only locals
  within one function, and every hit was a controller or subscription held in a
  FIELD and closed elsewhere. 19 false positives.
- `unnecessary_lambdas` in `test/` only (26 hits): 14 are
  `expect(() => x.y(), throwsA(...))`, `putIfAbsent(k, () => T())`, or a test
  BODY — constructs where a tearoff is wrong or worse. Scoped out by
  `test/analysis_options.yaml`, which states the number; `lib/` keeps the rule
  and was cleaned of all 9 of its own.

  **The rule then proved the point mid-round.** An automated fix pass ran over
  the tests and, to remove one closure, inlined the helper behind
  `bidi_server_ends_first_test.dart`'s one-line body — deleting the fifteen-line
  comment that recorded why that guard is narrow:

  ```
  infinite handler, 1 request sent -> cancel returned (received=19)
  infinite handler, no request     -> CANCEL DEADLOCKED (received=0)
  mirror handler,   1 request sent -> CANCEL DEADLOCKED (received=1)
  ```

  A measured, still-unfixed deadlock, traded for a closure. The file was
  reverted and the numbers are back. A style rule that can delete evidence is
  not a style rule on this corpus.

**Only `rpc_dart` was raised.** The other 21 packages sit on whatever they
inherited and the same count has never been taken for any of them — the obvious
next round, and RPC-26 says so.

`curate` remains overdue since ~234, and RPC-02's re-ablation is still owed.
Russian comments were noticed in core's `test/` and `example/` while working
(B-30 is about `lib/` in other packages); not this round's target.

## Links

RPC-26 is new, `confirmed (325)`, refines U-03. Its keeper: the two dials do not
cost the same — the type modes found 208 real downcasts and raw generics, the
style rules 112 mostly-cosmetic ones, so if only one is ever turned on it should
be `analyzer: language:`.

RPC-13 for what the untyped handlers were hiding; RPC-23 for the doc ratio that
showed this round had to go after the instrument instead of the files.
