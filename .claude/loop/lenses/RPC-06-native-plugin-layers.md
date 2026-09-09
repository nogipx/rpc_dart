---
refines: U-14, U-03
paths: [packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/lib/**]
applies: the plugin has a native layer in Swift and Kotlin
breaks: a hang until the watchdog fires, a silent death of the runtime.
applied: []
status: confirmed (round 180, off-journal)
---

# RPC-06 — The plugin's native layers

Checked by `analyze:native` and `test:wasm:device`, and the latter must be run
on BOTH platforms: they are two different scripts in two languages.

## Shape

The defect lives in Swift or Kotlin, where Dart greps never look.

## Detector

The `rpc_dart_wasm` sources on both platforms; callbacks that are nil after boot
(`finishBoot`); `Log.w(...); break`; script injection outside try/catch.

## Ask

Was this code RUN, or only read and compiled?

## Evidence

The first RUN of the Swift half in the project's history found a defect on the
very first test: a guest whose glue throws cost 30051 ms — the watchdog to the
millisecond, 334 ms after the fix.
