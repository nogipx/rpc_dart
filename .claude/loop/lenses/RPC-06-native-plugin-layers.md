---
refines: U-14, U-03
paths: [packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/lib/**]
applies: the plugin has a native layer in Swift and Kotlin
breaks: a hang until the watchdog fires, a silent death of the runtime.
applied: [348]
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

## Applied, round 348 — CLEAN, and what "clean" is worth here

```
analyze:native            PASS swift   PASS kotlin
test:wasm:device (iOS)    +17 All tests passed!
```

**Ablate each language SEPARATELY before believing either PASS.** They are two
scripts and one says nothing about the other; round 348 planted a type error in
each and got `FAIL kotlin / PASS swift` and then `FAIL swift / PASS kotlin`. Two
green lines from a gate never shown to fail are round 270's shape.

The iOS run is against a guest BUILT in the same run — the boot path, a guest
timer, an error in a guest timer, an unhandled rejection after boot, glue that
throws, all four call shapes, cancellation reaching inside the guest.

**Android was NOT run**: no emulator booted, only a simulator. It compiles and
the compile is sensitive; whether it runs is unestablished.

The detector's first shape is already handled and the two platforms handle it
DIFFERENTLY, which is correct rather than a missing port: Swift needs
`finishBoot` because WKWebView's boot is callback-driven with a timeout; Kotlin's
is a suspend call inside `withTimeoutOrNull` that returns or throws, so there is
no stored completion to go nil.
