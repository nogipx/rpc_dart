---
round: 688
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — a VM unit test, `packages/transport/rpc_dart_wasm/test/support_probe_matches_load_test.dart`
commit: yes
release: changelog
severity: S2
---

# Round 688 — the support probe matches load

## Target

B-171: `RpcWasmSupportInfo.canRunDartWasm` ignores the two sandbox features
the Android plugin requires, so it can say yes where `load()` fails; the
library doc says "transport layer only" while the barrel exports the Flutter
bridge; the stub's comment calls the JS-interop branch "non-Flutter"; the
podspec says 0.2.0 where the pubspec says 0.2.1.

## Hypothesis

`canRunDartWasm` reads `jsEngineAvailable && webAssemblyAvailable &&
wasmGcSupported`. The Kotlin `checkSupport` also reports
`wasmCompilationSupported` and `namedDataSupported`, and `loadRuntime` throws
when either is false; nothing joins the two.

## Before

```
no WASM compilation in the sandbox: cannot run   Expected: false  Actual: <true>
no named data in the sandbox: cannot run         Expected: false  Actual: <true>
```

## Mechanism

As hypothesised.

## Fix

- `canRunDartWasm` also requires `details['wasmCompilationSupported'] != false`
  and `details['namedDataSupported'] != false`. Absent counts as supported: iOS
  reports neither and needs neither.
- The library doc says what the package is: a Flutter package, a transport
  over any bridge, one bridge shipped, and what is exported on a JS-interop
  platform.
- The stub's comment names its branch: the web and a dart2wasm guest.

## After

4 of 4 green, both GUARDs (Android with both features; iOS with neither
reported) included.

## Canary

Before is the canary: the same tests against the old getter, 2 of 4 red.

## The verdict questions

1. Yes: Before is the canary; the GUARDs keep iOS and a capable Android true.
2. Yes, the probe item. The doc items are text.
3. Yes: the value an embedder branches on.
4. Not zero-valued.
5. Yes, quoted.
6. One cause for the probe.
7. Not a policy question, except the version below.
8. None.

## Gate

`test:wasm` (51, including the dart2js compile of the JS target), `analyze`,
`format:check`.

## Not fixed

The podspec version: versions are bumped by hand at release time, which is the
owner's step, so it is left for the next wasm release. Not witnessed on a
device: `checkSupport` was not run on a WebView without WASM compilation.

## Links

Lead `../backlog/B-171-wasm-api-surface-claims.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 688]`.
