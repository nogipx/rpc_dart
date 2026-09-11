---
round: 345
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-07
bench: none
commit: yes
---

# Round 345 — the only gate that sees it

## Target

L-12 applied to round 344: that round fixed ONE tear-off. The class is "code the
JS target rejects", and the count had not been taken.

## Hypothesis

If `dart analyze` catches this class, the repo is covered — `analyze` runs on
every package including `rpc_dart_wasm`. If it does not, coverage is exactly the
set of files some gate COMPILES for a JS target, which is a much smaller set.

## Before

**The analyzer is blind to it.** With round 344's tear-off restored:

```
fvm dart analyze --fatal-infos --fatal-warnings .   No issues found!
fvm dart compile js ...                             Error: Tear-offs of external
                                                    extension type interop member
                                                    'close' are disallowed.
```

So a JS-target compile is the only thing that sees this class, and analysing
harder cannot help. Which files get one?

```
library files importing dart:js_interop     compiled for a JS target by
isolate_transport_web.dart                  test:web   (hoisted in round 344)
wasm/rpc_wasm.dart                          NOTHING
```

Two files, and the sweep is complete — `rpc_websocket_server.dart` matched the
grep on the word "external" in a doc comment and has no interop at all.

**`rpc_dart_wasm`'s web implementation is compiled by no gate.** `test:wasm` is
`flutter test`, which runs on the VM; `test:wasm:device` builds for iOS and
Android; `test:web` does not include the package. It is the package whose entire
purpose is a JS runtime.

Compiled by hand, it is clean today. Nothing would report the day it stops.

## Mechanism

`analyze` and `compile js` are different front ends. The interop rules live in
the CFE's JS-target checks, not in the analyzer's rule set — so a package can be
`--fatal-infos` clean and not build. Round 326's lint floor makes this worse
rather than better: `unnecessary_lambdas` asks for exactly the tear-off the
compiler refuses (round 344).

## After

`tool/js_target_entry.dart` — committed, compiled, never run — and a compile step
at the FRONT of `test:wasm`, where `flutter pub get` has just resolved the
package:

```
melos run test:wasm
  Compiled 11,084,686 input bytes ... in 0.45 seconds     <- new, first
  ...
  00:03 +40: All tests passed!
```

The resolution line confirms what it compiled against, which is the observable
`config.md` asks for on this package:
`rpc_dart 5.0.1 from path ../../core/rpc_dart (overridden in ./pubspec_overrides.yaml)`.

## Canary

A tear-off planted in `rpc_wasm.dart`:

```
fvm dart compile js tool/js_target_entry.dart
  Error: Tear-offs of external top-level member '_sendBytes' are disallowed.

fvm dart analyze --fatal-infos --fatal-warnings lib test
  No issues found!
```

Both halves matter: the new gate line sees it, and the gate that already
existed still does not.

A first attempt tore off `globalContext.delete` and **compiled fine** — that is
a Dart-implemented extension method, not an external one. The rule is about
`external` members, and this round also widened what round 344 knew: it covers
external TOP-LEVEL members, not only extension type ones.

## Gate

`analyze` clean over 21 packages plus `rpc_dart_wasm`; `format:check` clean;
`license:check` 1390/1390; `test:wasm` compile + 40 tests green.

`test:unit` **exited 1 on the first run and green on a paced re-run**, and I
cannot name the failure: the output was truncated before the failure line, so
there is nothing to quote. Load was 10.94 after six back-to-back suites, which
is the condition `config.md` warns about — but an unnamed failure is an unnamed
failure, and the honest record is that one run failed for a reason I did not
capture.

## Not fixed

The new step guards `rpc_wasm.dart` because the entry imports it. Any future
web-only library file in that package needs adding to the entry, and nothing
enforces that — the same shape as the coverage gap this round closed, one level
up. Stated rather than solved: a dependency-walking entry would be its own
piece of work.

## Links

RPC-07 — web as a separate runtime. Its usual form is a behaviour that differs
on dart2js; this is the earlier one, where the code does not build at all and
three of the four gates say it does.

> **"Is it checked?" is not the same question as "does some gate run over it?"**
> `analyze` runs over `rpc_dart_wasm` and reports on it, at
> `--fatal-infos --fatal-warnings`, and is structurally incapable of seeing the
> one failure mode that package has.
