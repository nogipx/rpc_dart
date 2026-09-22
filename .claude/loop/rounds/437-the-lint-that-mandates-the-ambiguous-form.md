---
round: 437
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none — a translation sweep; the evidence is that the swept directory is
  now 100% fixture and the list matches C-47 exactly, plus the gate
commit: yes
---

# Round 437 — the lint that mandates the ambiguous form

## Target

**B-30**, core `test/serializers/`. This is the slice round 436 said could only
be swept once C-47 existed: three of these five files mix prose to translate
with fixtures that must not be, on adjacent lines.

`lib/` remains deferred — the owner has not answered round 436's question and
in-scope work remains.

## Hypothesis

If C-47's line-level census is right, sweeping these files down to exactly the
census leaves the directory 100% fixture. That is a checkable prediction, not
an assertion: any leftover would be a line the census missed.

## Before

```
                            Cyrillic lines
cbor_test.dart                    15
optimized_cbor_test.dart          27
codec_complex_test.dart           23
fast_cbor_encoder_test.dart       19
cbor_parity_test.dart              1
```

## Mechanism

Not a behaviour defect. The repo diverging from "English for code, comments,
and logs".

## After

```
                            before   after   what the remainder is
cbor_test.dart                  15       4   :135 :138 :374 :404 :421
optimized_cbor_test.dart        27       3   :76 :164 :167
codec_complex_test.dart         23       0   nothing left
fast_cbor_encoder_test.dart     19       2   :48 :65
cbor_parity_test.dart            1       1   :75
```

Counting every script rather than Cyrillic alone, `test/serializers/` now holds
**20 non-ASCII lines and every one of them is in C-47**. The prediction held:
the census missed nothing, and the directory is a clean fixture-only state a
future sweep can verify in one command.

126 tests pass.

Repo-wide, tracked `*.dart` Cyrillic:

```
         files   lines
lib         23     316
test        33     970      (was 38 files / 1338 before round 435)
example      1      65
```

### One stale comment, surfaced by translating it

`fast_cbor_encoder_test.dart:144`:

```dart
expect(avgTime, lessThan(10000)); // < 3ms среднее время
```

10,000 microseconds is 10 ms, not 3. The comment had been wrong for as long as
it has existed, and it survived because a reviewer skipping a language they do
not read skips the claim inside it too. Corrected to `< 10 ms on average`. The
sibling on the next line (`lessThan(2000)`, "< 2ms") was right.

> This is the argument for the rule that is not about style: prose nobody reads
> is prose nobody checks.

## Canary

**The repo's own lint mandates the construct that broke round 435.**

`fast_cbor_encoder_test.dart:141` prints `min: $minTimeμs`. That reads as one
identifier and is not: `μ` is not an ASCII letter, so it terminates the name
and `μs` is a literal suffix. Round 435 met the same shape in the isolate suite
and mis-edited it into an undefined identifier.

The obvious repair is braces — `${minTime}μs` — which say where the name ends.
Tried, and the gate refuses it:

```
info - fast_cbor_encoder_test.dart:141:45 - Unnecessary braces in a string
       interpolation. Try removing the braces. - unnecessary_brace_in_string_interps
```

`melos run analyze` is `--fatal-infos`, so that is a build failure. The
analyzer knows the boundary from the grammar and therefore calls the braces
redundant — **removing the only signal a human reader has.** The rule is
correct and its effect here is to require the ambiguous form.

Reverted to `$minTimeμs` with a comment saying why, which is the only remedy
the lint config allows. Five other `μs` sites in the same file are already
brace-form because their interpolations are expressions, so the hazard is one
line, not a class.

Stands in for an ablation: the prediction ("sweep to the census, get a
fixture-only directory") was falsifiable and came out exact, and `test:unit` is
green, so no assertion about a byte encoding was quietly rewritten.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
melos run test:unit      SUCCESS
melos run format:check   SUCCESS
melos run license:check  compliant, 1609/1609
```

`test:web` not run: nothing here touches a dart2js-sensitive path, unlike round
436's `zero_copy_streams_test.dart`.

## Not fixed

```
lib/ logs        39 lines   rpc_notify only    deferred by the owner's ORDER
lib/ comments   277 lines   23 files           same
test/           970 lines   33 files           in scope, open
generated        21 lines   rpc_data/*.g.dart  fix the SOURCE first
```

Of the 970 `test/` lines, 20 are the C-47 fixtures and never go away. The
largest remaining files are `rpc_responder_endpoint_test.dart` (116) and
`rpc_context_test.dart` (83).

**Still the owner's call**, unchanged from round 436: whether 39 runtime log
lines in a published package outrank 950 internal test comments, given the
deferral was taken before anyone had counted the logs separately.

## Links

- B-30 — `test/serializers/` done and now fixture-only
- C-47 — the census held exactly; its line list is what made this sweepable
- RPC-23 — extended with the lint finding
