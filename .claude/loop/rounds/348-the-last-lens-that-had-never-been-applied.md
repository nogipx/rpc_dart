---
round: 348
verdict: CLEAN
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none
commit: yes
---

# Round 348 — the last lens that had never been applied

## Target

RPC-06, `applied: never` since round 180 and the only lens left with an empty
list. Its Ask is one question:

> Was this code RUN, or only read and compiled?

Both of its gates are on the config's "targets nobody runs" list, and neither had
been run this session.

## Hypothesis

Two, and they are different. That the compile gate is a gate that cannot fail —
round 270's shape, and the reason `analyze:native` exits 2 rather than 0 when it
checks nothing. And that the run gate is unreachable here, which would explain
why the lens has never been applied.

## Before

```
melos run analyze:native
  PASS  swift: RpcDartWasmPlugin.swift type-checks against Flutter + WebKit
  PASS  kotlin: RpcDartWasmPlugin.kt compiles against Flutter + javascriptengine
```

Both toolchains present, so nothing was skipped. The pass means something only if
the check can fail, so each half was ablated SEPARATELY — they are two scripts in
two languages and one proves nothing about the other:

```
Kotlin, `val probe: Int = evalResult`
  ERROR ...RpcDartWasmPlugin.kt:344:30: initializer type mismatch:
        expected 'Int', actual 'String'
  FAIL  kotlin      PASS  swift

Swift, `let probe: Int = body`
  error: cannot convert value of type 'String' to specified type 'Int'
  FAIL  swift       PASS  kotlin
```

Each half fails on its own and leaves the other green. The gate has sensitivity
in both languages, which is what the two PASSes are worth.

Then the level the lens actually asks about. A simulator was booted, so
`test:wasm:device` ran for real:

```
plugin_test.dart      9 tests
rpc_guest_test.dart   8 tests
01:08 +17: All tests passed!
```

Against a dart2wasm guest BUILT in the same run, not a committed artefact — the
boot path, a guest timer, an error thrown in a guest timer, an unhandled
rejection after boot, glue that throws, a boot failure naming its reason, all
four call shapes, cancellation reaching inside the guest, and closing mid-stream.

## Mechanism

Nothing to explain: no defect. The detector's named shapes are already handled —
the Swift carries the `if booted { reportDeath } else { finishBoot }` split that
the lens's own evidence was written about.

The Kotlin does NOT have that split, and that is not a missing port. Its boot is
a suspend call that returns or throws (`withTimeoutOrNull(30_000)` around
`evaluateJavaScriptAsync`), so there is no stored completion to go nil; the Swift
needs `finishBoot` because WKWebView's boot is callback-driven with a timeout.
Round 343's rule, on native: the question is not *did they copy this* but *do
they face this, and with what*.

## After

No change.

## Canary

The two ablations above ARE the canary, one per language, and they are the point
of the round: without them two PASS lines are a gate that has never been shown to
fail.

## Gate

`git status` clean after restoring both ablations, verified before the record.
No library change, so the workspace gate is unchanged from round 347's green.

## Not fixed

**Android was not RUN.** `fvm flutter devices` found one mobile target, an iOS
simulator; no emulator was booted. So half of the lens's Ask is answered and half
is not, and CLAUDE.md is explicit that this is not a detail — "the two boot
scripts are separate strings in separate languages, so a fix to one is never a
fix to the other, and some cases only exist on one".

What was established for Android: it COMPILES, and the compile has sensitivity.
What was not: whether it runs.

## Links

RPC-06 (`applied:` gains 348, its first since the lens was confirmed at round
180). Its status was `confirmed` on off-journal evidence and has now been
exercised in the journal.

> **A lens with an empty `applied:` list is not necessarily a lens nobody needed.**
> This one costs a booted simulator and a minute, and the reason it had never
> been applied is that its gates are the two the config files under "targets
> nobody runs" — which is a statement about habit, not about value.
