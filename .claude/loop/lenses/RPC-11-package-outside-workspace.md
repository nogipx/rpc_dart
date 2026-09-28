---
refines: U-03
paths: [packages/transport/rpc_dart_wasm/lib/**, packages/core/rpc_dart_generator/lib/**]
applies: the repository has packages outside the pub workspace
breaks: "wrong result: a green gate with the package broken, because what was checked is the published core rather than the one about to ship."
applied: [220, 226, 269, 270, 344, 470]
status: confirmed (round 220)
---

# RPC-11 — A package outside the workspace

## Shape

`rpc_dart_wasm` and `rpc_dart_generator` take no part in the common run, so the
ordinary gate never sees them.

## Detector

The workspace member list against the list of directories under `packages/`.

## Ask

Does this package resolve core from local source or from the published version?

## Evidence

Without `pubspec_overrides.yaml` the wasm target silently tests the PUBLISHED
core.

**Rounds 269-270 got this backwards and that is the sharpest thing the lens
carries.** 269 read `rpc_dart_wasm/pubspec.yaml`, found `rpc_dart '>=5.0.0
<6.0.0'` and no `dependency_overrides`, and wrote into `config.md` that
`test:wasm` validates the published core. `pubspec_overrides.yaml` is pub's own
override mechanism, does not appear in `pubspec.yaml`, and points core at
`../../core/rpc_dart` — grepping the one says nothing about the other. The
detector's "Ask" is answerable only from pub's RESOLUTION output, never from a
manifest. The real blind spot is the inverse and smaller: wasm is never tested
against an OLDER published 5.x, which its constraint allows.

Round 220 ran the detector. `melos list` gives 21, `packages/` holds 22, and the
difference is `rpc_dart_wasm`. The gap is wider than "not in the test run":

    scripts mentioning wasm      test:wasm, analyze:native, test:wasm:device,
                                 publish:dry, publish:release, tag:release
    scripts NOT mentioning it    analyze, format:check, test, test:unit

`test:wasm` runs `flutter test`, which does not analyse; `analyze:native` covers
Swift and Kotlin only. So the package's DART source is analysed by nothing and
format-checked by nothing, `melos run prepare` included. Run directly it is
clean — `No issues found!`, 18 files unchanged — so the hole costs nothing
today. `../checked/C-22-wasm-is-outside-every-gate-script.md`,
`../backlog/archive/B-19-close-the-gate-over-wasm.md`.

> **A compensating script is not the same as a covered package.** The three wasm
> scripts read like compensation and cover the native halves and the Dart tests;
> what nobody had checked is which of the ordinary gate's jobs they replace.
> Enumerate the gate's jobs, then ask which the compensation actually does.

## Round 470 — a compensating script nobody RUNS covers nothing at all

The section above asks which of the gate's jobs the compensation does. 470 is the
prior question: **is it run?** `melos run test:wasm:device` exists, is documented,
and had never been executed on Android. Its first run:

```
+23 ~2 -1   Some tests failed.
```

A test that had been wrong since round 416 — expecting a `StateError` the library
had stopped throwing — sat green-by-absence for fifty-four rounds, because
nothing ever asked it.

> **For a script outside the gate, the first question is not what it covers but
> when it last ran.** A gate entry that cannot fail is a known shape (round 348);
> a gate entry nobody invokes is worse, because its existence is cited as
> coverage in the very documents that explain why the package is excluded.

And the reason it went unrun for so long is worth separating from the reason it
was red:

> **A blocker recorded in a lead ages like any other claim.** Three leads shared
> one sentence — *"`xcrun simctl` is outside the agent's allowlist"* — written
> once in round 357 and copied forward. It is false; `simctl` runs. The genuine
> obstacle was different (simulator data missing from disk), fixable by one
> command, and pointed at a different person. L-13 applies to blockers, not only
> to findings.

`../rounds/470-the-device-suite-ran-on-android.md`.
