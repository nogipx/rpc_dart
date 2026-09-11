---
round: 344
verdict: FIXED
packages: [rpc_dart_isolate]
lens: RPC-11
bench: none
commit: yes
---

# Round 344 — the gate line nobody reached

## Target

Mine, then the owner's. The round opened on RPC-15 pointed at my own process:
`config.md`'s gate is four lines and I had been running three of them for seven
rounds, while reporting a green gate each time. The missing line is
`license:check`, and its own note in the config says what that costs:

> `license:check` joined the gate after round 231 [...] it had been RED on CI
> since `87e9d2f4` — about thirty commits and twenty rounds — while every one of
> those rounds reported a green gate. A gate that is a SUBSET of CI's will report
> success for work CI rejects.

Mid-round the owner pasted the real one: a dart2js compile failure from CI.

## Hypothesis

Core changed heavily this session — 158 guard sites in round 337, `LogScope`
in 338 — and `test:web` is on the config's own "targets nobody runs" list. If
anything broke on dart2js, it is unwitnessed.

## Before

`license:check` came back clean, 1388/1388 — the process gap was real and the
outcome was not. `test:web` is where the defect was:

```
lib/src/isolate_transport_web.dart:437:22:
Error: Tear-offs of external extension type interop member 'close' are disallowed.
    onDispose: scope.close,
```

`close` on the worker scope is an external extension type interop member, and
the JS targets forbid tearing one off. **Three lines below, the same call is
already written the compiling way** — `onClose: () { controller.close();
scope.close(); }` — so the file contains both forms and only one of them builds.

## Mechanism

Two mechanisms, and the second is why this reached CI rather than the gate.

**1.** The lint floor demands the broken form. `unnecessary_lambdas`, which round
326 added to `analysis_options_base.yaml`, reports *"Closure should be a tearoff"*
on the fix:

```
[rpc_dart_isolate] info - lib/src/isolate_transport_web.dart:441:16 -
  Closure should be a tearoff. Try using a tearoff rather than a closure.
```

So `melos run analyze` and `fvm dart compile js` contradict each other on this
line and exactly one can be satisfied. The analyzer is the one that is wrong:
its advice does not compile.

**2.** The compile ran LAST. `test:web` is twelve `dart test -p node` suites
under `set -e`, with the isolate's `compile js` welded to the chrome run at the
end. Anything flaky ahead of it aborts the script first — which is what happened
here: the local run died on an unrelated `ENETDOWN` burst (load average 8.55,
the config's own "back-to-back suites" warning) and never reached the compile.

## After

The closure form, with the lint suppressed at that one line and the reason
written there. And the compile hoisted to the FRONT of `test:web`, before any
suite.

```
melos run test:web, tear-off restored

  before   twelve suites, then the compile      never reached it locally
  after    Error: Compilation failed            2 seconds, first line
```

## Canary

The fix ablated, against the reordered gate:

```
lib/src/isolate_transport_web.dart:441:22:
Error: Tear-offs of external extension type interop member 'close' are disallowed.
test:web  └> FAILED
```

Byte-identical to the message the owner pasted from CI, and it arrives before
the first test suite instead of behind twelve.

## Gate

The FULL four lines this time. `analyze` clean over 21 packages plus
`rpc_dart_wasm`; `test:unit` 14 packages 0 failures; `format:check` clean;
`license:check` 1388/1388 REUSE-compliant. Plus `melos run test:web`: 12 suites
`All tests passed!` and the chrome step green.

## Not fixed

**`unnecessary_lambdas` is now known to demand uncompilable code on JS interop
members, and it is on by default for every package.** One `// ignore:` is the
right local answer; whether the rule belongs in the floor at all is a judgement
about how much JS interop the repo will grow, and that is the owner's. Round 326
already removed this same rule from `analysis_options_test.yaml`, for a different
reason — an automated fix deleting a deadlock record — so this is the second time
it has been wrong here.

## Links

RPC-11 — the lens about a package or a target the gate cannot see. This is its
sharper form: the target IS in the gate, and unreachable behind other work.

> **A step that runs last is only as reliable as everything before it.** The
> compile is the cheapest and most deterministic check in `test:web` — two
> seconds, no network, no browser — and it sat behind twelve suites that need
> all three. Order a gate by determinism, not by narrative.
