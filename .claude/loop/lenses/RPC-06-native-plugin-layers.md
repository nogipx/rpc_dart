---
refines: U-14, U-03
paths: [packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/lib/**]
applies: the plugin has a native layer in Swift and Kotlin — and a contract ACROSS that boundary, which is neither language
breaks: a hang until the watchdog fires, a silent death of the runtime, a diagnostic that arrives corrupted.
applied: [348, 355, 357, 362, 363, 365, 482, 484, 492, 493, 665, 683, 684, 685, 686, 687, 688, 689, 707, 708, 716]
status: confirmed (round 365)
rank: 24
---

# RPC-06 — The plugin's native layers

Checked by `analyze:native` and `test:wasm:device`, and the latter must be run
on BOTH platforms: they are two different scripts in two languages.

## Shape

The defect lives in Swift or Kotlin, where Dart greps never look — or in the
contract between them and Dart, which is in neither language.

## Detector

- The `rpc_dart_wasm` sources on both platforms; callbacks that are nil after
  boot (`finishBoot`); `Log.w(...); break`; script injection outside try/catch.
- The boundary itself: every encoder on the native side (`data(using:)`,
  `toByteArray`) and its reader on the Dart side, and every
  `String.fromCharCodes` over bytes the code did not itself produce. For any
  cross-boundary payload, ask what input would DISTINGUISH the two readings,
  and check that some test sends it.
- The JS globals each boot script assumes, and which of them the other sandbox
  does not have. A WKWebView gives you a browser; a JavaScriptSandbox gives you V8.
- Ablate each language SEPARATELY before believing either PASS.

## Ask

Was this code RUN, or only read and compiled? The levels are reading <
compiling < running < measuring, and the Ask applies to the round as well as to
the code.

## Evidence

The first RUN of the Swift half in the project's history found a defect on the
very first test: a guest whose glue throws cost 30051 ms — the watchdog to the
millisecond, 334 ms after the fix.

- **Round 348** — CLEAN: `analyze:native` PASS on both, iOS device suite `+17`;
  a planted type error gave `FAIL kotlin / PASS swift` and then the reverse, so
  each language must be ablated separately (two green lines from a gate never
  shown to fail are round 270's shape). Android was not run. Swift needs
  `finishBoot` (callback-driven boot); Kotlin's `withTimeoutOrNull` has no
  stored completion to go nil — different, not a missing port.
- **Round 355** — both plugins encode UTF-8 (`RpcDartWasmPlugin.swift:581,629`,
  `RpcDartWasmPlugin.kt:425,493`) and Dart read bytes with
  `String.fromCharCodes`: Cyrillic 17 ch / 30 B arrived as 30 ch. The arrived
  count equals the BYTE count, the signature of one character per byte; ASCII
  is the control and ASCII is why it shipped. Sweep of 14 sites: two wrong,
  both here. `../probes/P-47-native-text-encoding.md`,
  `../rounds/355-the-encoding-both-sides-agreed-on-and-neither-said.md`.
- **Round 357** — INCONCLUSIVE: the iOS recv loop gives up silently, fix
  compiled (`PASS swift / PASS kotlin`) but no simulator would start, so it was
  reverted. The lens applies to the round, not only to the code; `analyze:native`
  passing is not evidence about behaviour, and round 348 already priced that.
  `../backlog/B-38-ios-recv-loop-dies-silently.md` holds the patch.
- **Round 362** — Base64 on `Dispatchers.Main` is certain as code but not the
  cost: idle worst 39 ms ablated vs 12 ms after the fix, busy 38-70 ms in every
  arm. A green native gate plus a green device suite says nothing about a
  PERFORMANCE claim; measure the thread (a platform-channel round trip), not a
  consequence two layers away; when the threshold sits inside the noise floor,
  say so. Reverted. `../probes/P-53-android-main-thread-during-transfer.md`
  (`broken` by its own ablation), `../backlog/B-41-android-base64-on-the-main-thread.md`,
  `../rounds/362-the-thread-was-not-the-cost.md`.
- **Round 363** — `stripModuleSyntax` (four literal `replace` calls) now names
  the construct on Android. A cross-platform claim needs a per-platform
  measurement, and the platform you can reach may be the one where it is false.
  The control was the finding: `contains("export")` took the suite from
  `+21 ~2` to `+3 ~2 -13`; when a fix is a new REFUSAL, the arm that must keep
  working matters most. Write the shared rule so two languages cannot disagree
  (a trimmed `hasPrefix`). `../backlog/B-42-ios-strip-failfast-unwitnessed.md`,
  `../probes/P-54-unstripped-module-syntax.md`,
  `../rounds/363-the-check-that-would-have-refused-everything.md`.
- **Round 365** — two-platform gate (Android `+24 ~2`, iOS `+26`): dart2wasm's
  glue calls `performance.now()` (`guest.mjs:123`), which `JavaScriptSandbox`
  lacks, so any guest using `Stopwatch` failed on Android with
  `RpcStatusException(13): Internal server error`. Ablating each language
  separately is not the same as running the same code on both; a bench built
  for one question (timer lag, which was clean) found the defect.
  `../probes/P-56-guest-timer-lag.md`, `../probes/P-57-guest-to-host-frame-order.md`,
  `../rounds/365-the-clock-one-sandbox-does-not-have.md`.
- **Round 482** — B-93's "the same shim" twice: of 14 functions each, 5 are
  identical and all trivial; every difference is forced by the host API. Before
  de-duplicating two implementations, measure the OVERLAP, not the resemblance;
  the cost of two native layers is real but it is not in the shared code (B-38
  is the platform-specific half). `../rounds/482-five-trivial-functions-is-the-whole-overlap.md`,
  `../probes/P-123-what-the-two-shims-actually-share.md`,
  `../checked/C-56-the-two-shims-have-not-drifted.md`.
- **Round 492** — a Kotlin forward-path reorder reads true statically and does
  not happen (peak in flight 110 Android / 56 iOS, 15 frames >=64 KiB). For a
  race, a bench that failed to create the concurrency is green exactly like a
  negative, so it asserts its own precondition (fail below peak two). A native
  negative usually rests on a DEPENDENCY property (`androidx.javascriptengine`,
  `evaluateJavaScriptAsync`), which must be labelled, as RPC-15 does for records.
  `../probes/P-131-does-a-large-host-to-guest-frame-keep-its-place.md`,
  `../rounds/492-the-race-that-had-its-chance.md`,
  `../checked/C-57-a-large-host-to-guest-frame-keeps-its-place.md`, B-101.
