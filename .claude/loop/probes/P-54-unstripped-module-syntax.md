---
file: packages/transport/rpc_dart_wasm/example/integration_test/unstripped_module_syntax_test.dart
round: 363
commit: b1053a84
paths: [packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/ios/**]
status: valid
---

# P-54 — what a caller is told when the glue uses unstripped module syntax

Loads a real guest with the REAL dart2wasm glue mutated one way per arm, and
reports what `RpcFlutterWasmBridge.load` handed back. Mutating the real glue
rather than synthesising one holds everything else about the boot fixed. Add a
form a future SDK might emit by adding a row.

Kept in `example/integration_test/` as a test, unlike P-53: these arms
distinguish the fixed state from the broken one, so they are witnesses.

## Measures

The exception text the caller receives — the only thing an application
developer ever sees when a boot fails.

## Control

**The unmutated glue, which must boot**, and it is load-bearing rather than
ceremonial. `export` and `import` appear 19 times in the real glue and only 4 at
statement position — `dartInstance.exports`, `importObjectPromise`, and a
comment naming the `'import'` API are the rest. A `contains` check instead of a
line-anchored one refuses every working boot.

```
arm                   before                        after
unmutated (control)   booted                        booted
export let            SyntaxError: Unexpected       names the construct and
export default        token 'export' ...            says stripModuleSyntax
trailing export {}                                  needs updating
a leading import      Cannot use import statement
                      outside a module
```

The control's ablation is the sharper number: swapping the line-anchored check
for `plainJs.contains("export")` takes the suite from **`+21 ~2` to `+3 ~2 -13`**
— thirteen tests, every guest boot in the repository.

## Platform

Android only, measured. The same arms would report differently on iOS, where a
SyntaxError kills the whole `<script>` tag and the failure surfaces as the 30 s
boot watchdog instead — see `../backlog/archive/B-42-ios-strip-failfast-unwitnessed.md`.
