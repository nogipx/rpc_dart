---
round: 226 — where it was paid for; the bill arrived on CI and was settled by a hotfix, not by a round
class: toolchain
cost: a red CI on main with 304 analyzer errors, from a round whose ablation reported the gate working
paths: [pubspec.yaml, .github/workflows/rpc_dart_test.yml]
commit: 9d6ebfdd
status: active
---

# L-05 — a gate ablation proves sensitivity, not portability

Round 226 added `rpc_dart_wasm` to `melos run analyze` and checked it the way
this loop demands: plant a lint in the package, confirm the gate goes red; plant
one in a workspace member, confirm it still goes red. Four arms, all correct.

CI went red anyway, with **304 errors**, every one
`Target of URI doesn't exist: package:flutter/...`.

## Why the ablation could not see it

`rpc_dart_wasm` is not a workspace member, so the root `fvm dart pub get` never
resolves it. The local tree had `.dart_tool/package_config.json` from some
earlier `flutter pub get`, so the analyzer found Flutter and reported "No issues
found!". A fresh runner has no such file.

**The ablation varied the CODE and held the ENVIRONMENT fixed.** It answered
"does this gate notice a defect", which was the question asked, and never
touched "does this gate run at all where it will actually run".

## The rule

A gate has two properties and they fail independently:

- **Sensitivity** — it goes red on a real defect. Ablation answers this.
- **Portability** — it runs at all on a tree it did not prepare. Ablation cannot
  answer this, because the ablation runs in the prepared tree.

**Before shipping a gate step, ask what it depends on that nobody in CI has
done.** Resolved dependencies, a built artefact, a booted device, a warmed
cache. For each, either the workflow does it explicitly or the step must not
need it.

The tell here was available and unread: the step ran a DIFFERENT resolve from
every other package in the repository, and `CLAUDE.md` says so in as many words
— "it resolves standalone — test it separately". A step whose prerequisites
differ from its neighbours' is the one to check on a clean tree.

## The second half, found at the same time

Analysing the whole package also pulled in `example/`, whose
`assets/guest.wasm` and `guest.mjs` are **build artefacts not in the
repository**, so `asset_does_not_exist` fires on a perfectly green tree. Scope
the gate to what is published — `lib` and `test` — and leave the host app to
`test:wasm:device`.

Related: [L-04](L-04-a-guard-with-no-witness.md), which is the same shape one
level up — an ablation that answers the question asked and not the question that
matters.
