---
round: 363
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: P-54 — new
commit: yes
---

# Round 363 — the check that would have refused everything

## Target

The owner's 6.0.0 review list, P2 item 12: `stripModuleSyntax` should fail fast
when `export`/`import` survive the strip. Taken now because the Android emulator
is still up.

RPC-06, and for once its Ask — *was this code RUN?* — could be answered for one
platform and not the other. Both halves shipped; only one is witnessed, and the
asymmetry with round 357 is argued in `## Not fixed`.

**Scope counted before the fix.** The strip is four literal prefixes, in both
plugins, pinned to what dart2wasm emits today:

```
"export async function "  "export const "  "export function "  "export class "
```

The current `guest.mjs` uses three of the four, which is why it works. Forms
that survive: `export let`, `export var`, `export default`, a trailing
`export {a, b}`, and every `import`.

## Hypothesis

A future SDK emitting any other module form leaves it in a classic script, and
the caller is told something that does not name the cause.

## Before

```
arm                   what the caller was told
unmutated (control)   booted
export let            SyntaxError: Unexpected token 'export' export l...
export default        SyntaxError: Unexpected token 'export' export d...
trailing export {}    SyntaxError: Unexpected token 'export' export {...
a leading import      Cannot use import statement outside a module...
```

Probe: `packages/transport/rpc_dart_wasm/example/integration_test/unstripped_module_syntax_test.dart`,
Android 11 emulator, mutating the REAL glue so everything else about the boot is
held fixed.

**The item's premise does not hold on Android, and that is worth saying.** It
predicted `compile is not defined`; Android's `evaluateJavaScriptAsync` rejects
on the syntax error and the message already names the token. The confusing
symptom belongs to iOS, where a SyntaxError kills the whole `<script>` tag — and
that half is unmeasured.

## Mechanism

Four `replace` calls with no check that they accomplished anything. Nothing
anywhere asserts the post-condition the rest of the boot depends on: that the
glue is now a classic script.

## After

```
arm                   what the caller was told
unmutated (control)   booted
export let            The dart2wasm glue uses module syntax this plugin does
export default        not strip ... "export let invoke = ..." ... a newer Dart
trailing export {}    SDK emitting another form needs stripModuleSyntax updated
a leading import
```

Checked before anything is allocated — on Android before the isolate, on iOS
before the web view — because the answer does not depend on any of it.

## Canary

Two, and the second is the one worth having.

```
the check removed
  Expected: contains 'module syntax this plugin does not strip'
    Actual: 'Bad state: Failed to load WASM runtime: Uncaught SyntaxError:
             Unexpected token \'export\''
  four witnesses red, the control green

the check made NAIVE  (plainJs.contains("export") || contains("import"))
  +21 ~2  ->  +3 ~2 -13
```

**The naive check kills thirteen tests — every guest boot in the repository.**
`export` and `import` appear 19 times in the real glue and only 4 at statement
position; `dartInstance.exports`, `importObjectPromise` and a comment naming the
`'import'` API are the rest. That is why the check is line-anchored, and why the
control is load-bearing rather than ceremonial: a wrong rule here is far worse
than the failure it diagnoses.

Deliberately not a regex in either language: the same rule runs in Kotlin and
Swift, and a trimmed `hasPrefix` means the same thing in both, which no two
regex engines guarantee.

## Gate

`melos run analyze:native` PASS swift / PASS kotlin;
`RPC_WASM_DEVICE=emulator-5554 melos run test:wasm:device` **`+21 ~2`**, five
new tests on top of the previous `+16`;
`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:wasm` all passed; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**The iOS half is compiled and never run**, and unlike round 357 it SHIPPED. The
asymmetry is deliberate: 357 changed a live path's behaviour, where being wrong
breaks something that works today; this adds a check to a path that is already
failing, so a false negative leaves exactly today's behaviour. The dangerous
direction — refusing working glue — lives in the line-anchoring rule, which is
identical in both languages, written without a regex for that reason, and
measured on Android by the ablation above.

That is an argument, not a measurement. Filed as **B-42** with the reasoning
written out so the owner can overrule it, and with what one simulator run would
settle: whether the check fires correctly on iOS, and whether the 30 s watchdog
really is what it replaces there.

## Links

Lens `../lenses/RPC-06-native-plugin-layers.md`, fifth application.
Bench `../probes/P-54-unstripped-module-syntax.md`, new.
Lead `../backlog/B-42-ios-strip-failfast-unwitnessed.md`, new.
Round `../rounds/357-a-fix-nobody-could-run.md`, whose opposite call this round
departs from on stated grounds.
Catalog shape U-18 — silent acceptance of a programmer error, here the
library's own.
