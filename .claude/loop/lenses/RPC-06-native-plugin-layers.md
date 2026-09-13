---
refines: U-14, U-03
paths: [packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/lib/**]
applies: the plugin has a native layer in Swift and Kotlin — and a contract ACROSS that boundary, which is neither language
breaks: a hang until the watchdog fires, a silent death of the runtime, a diagnostic that arrives corrupted.
applied: [348, 355, 357, 362, 363, 365]
status: confirmed (round 365)
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

## Round 355 — the third place, which is neither language

Round 348's rule is that two scripts in two languages say nothing about each
other. The corollary it did not draw: there is a place that is in NEITHER, and
no single-language gate reaches it. `analyze:native` reads Swift and Kotlin,
`dart analyze` reads Dart, and a disagreement about what the bytes between them
MEAN passes all three.

Both plugins encode text as UTF-8, in one line each —
`RpcDartWasmPlugin.swift:581,629`, `RpcDartWasmPlugin.kt:425,493`. Nothing on
the Dart side named an encoding at all: `String.fromCharCodes` maps each byte to
the code unit of the same value.

    arm                sent          arrived   text
    ascii (control)    22 ch / 22 B  22 ch     I:hello from the guest
    cyrillic           17 ch / 30 B  30 ch     I:Ð¿ÑÐ¸Ð²ÐµÑ Ð¸Ð· Ð³Ð¾ÑÑÑ
    emoji               9 ch / 11 B  11 ch     I:done ð

> **The arrived count equals the BYTE count**, which is the signature of one
> character per byte. Print both and the pair names the failure mode; print one
> and you know only that it is wrong.

> **ASCII is the control and ASCII is why it shipped.** Below 128 a
> byte-per-character read and UTF-8 agree exactly, the operation cannot throw,
> and the suite's shared helper builds its payload with `text.codeUnits`. Every
> test passed on input that could not tell the two apart. Add to the detector:
> for any cross-boundary payload, ask what input would DISTINGUISH the two
> readings, and check that some test sends it.

Extend the detector's list with the boundary itself: every encoder on the native
side (`data(using:)`, `toByteArray`) and its reader on the Dart side, and every
`String.fromCharCodes` over bytes the code did not itself produce. The sweep
over all 14 such sites in the workspace found two wrong, both here; the other
twelve are ASCII by protocol or read an alphabet the code defines.

Bench `../probes/P-47-native-text-encoding.md`,
`../rounds/355-the-encoding-both-sides-agreed-on-and-neither-said.md`.

## Round 357 — the Ask answered against the round itself

INCONCLUSIVE, and the lens is why. Round 357 found the iOS recv loop giving up
silently — conclusive from READING, because Android's driver already reports
death and breaks and its comment describes the iOS behaviour. It wrote the fix.
`analyze:native` said `PASS swift / PASS kotlin`.

Then this lens's own Ask — *was this code RUN, or only read and compiled?* —
answered "compiled", and the fix was reverted rather than committed. No
simulator could be started: five `flutter emulators --launch` attempts, waits up
to 240 s, `-d "iPhone 16"` refused, `flutter doctor` listing only macOS and
Chrome. One had booted earlier in the same session.

> **The lens applies to the round, not only to the code.** Its whole point is
> that compiling is not running; a round that stops at compiling and ships
> anyway has failed its own detector. `../backlog/B-38-ios-recv-loop-dies-silently.md`
> holds the patch so the next round with a device spends its time measuring
> rather than rediscovering.

> **`analyze:native` passing is not evidence about behaviour, and round 348
> already priced that.** Two green lines from a gate never shown to fail; here
> the gate was shown to fail (348 ablated both languages) and still says nothing
> about whether the loop recovers.

## Round 362 — running it answered a question nobody asked

An Android emulator came online mid-session, so the Ask got its other answer:
the code was RUN, five times, and it disagreed with the hypothesis under test.

The claim was that Base64 on `Dispatchers.Main` janks the app. The code fact is
certain — `CoroutineScope(Dispatchers.Main)`, with `Base64.decode` over batches
of up to 4 MiB per drain — and the measurement says it is not the cost:

    run  state        payload  idle worst  busy worst
    1    before fix   4 MiB    22ms        59ms
    4    after fix    12 MiB   12ms        70ms
    5    ABLATED      12 MiB   39ms        38ms

> **A green native gate plus a green device suite still says nothing about a
> PERFORMANCE claim.** Both passed in every arm above. This lens's levels —
> reading < compiling < running — need a fourth for this class: running is not
> measuring. A suite that exercises the path proves the path works, not that the
> work is where you think it is.

> **Measure the thread, not a consequence two layers away.** Frame timings are
> the obvious instrument and the wrong one here: Flutter's UI thread is separate
> from the Android main thread, and an idle test app renders nothing to be
> janked. A platform-channel round trip is dispatched ON the main thread, so its
> latency IS the observable.

> **On an emulator the baseline can exceed the criterion.** The review asked for
> "no frames >16 ms"; the IDLE control alone reached 39 ms with no transfer
> running. When a target threshold sits inside the noise floor, no fix can be
> shown to meet it — say so rather than reporting whichever run looked best.

Reverted, not shipped. `../probes/P-53-android-main-thread-during-transfer.md`
(`broken` by its own ablation),
`../backlog/B-41-android-base64-on-the-main-thread.md`,
`../rounds/362-the-thread-was-not-the-cost.md`.

## Round 363 — one platform answers the Ask and the other cannot

`stripModuleSyntax` is four literal `replace` calls in each plugin with no check
that they accomplished anything, pinned to the module forms dart2wasm emits
today. Mutating the REAL glue, on Android:

    arm                   before                        after
    unmutated (control)   booted                        booted
    export let            SyntaxError: Unexpected       the plugin names the
    export default        token 'export' ...            construct and says
    a leading import      Cannot use import statement   stripModuleSyntax

> **The review item's premise held on one platform and not the other.** It
> predicted `compile is not defined`; Android's message already named the token,
> because `evaluateJavaScriptAsync` rejects on the syntax error. The confusing
> symptom is iOS's, where a SyntaxError kills the whole `<script>` tag — which
> the Swift source says two comments away and which nobody has run. **A
> cross-platform claim needs a per-platform measurement, and the platform you
> can reach may be the one where it is false.**

> **The control was the finding.** Swapping the line-anchored rule for
> `contains("export")` took the device suite from `+21 ~2` to **`+3 ~2 -13`** —
> every guest boot in the repository. `export`/`import` appear 19 times in the
> real glue and only 4 at statement position; the rest are
> `dartInstance.exports`, `importObjectPromise` and a comment. When a fix is a
> new REFUSAL, the arm that must keep working is worth more than the arms that
> must now fail.

> **Write the shared rule so two languages cannot disagree.** The same check
> runs in Kotlin and Swift; a trimmed `hasPrefix` means the same thing in both,
> which no two regex engines guarantee. That is what let the Android measurement
> carry any weight at all for the unrun Swift half — an argument recorded as
> `../backlog/B-42-ios-strip-failfast-unwitnessed.md` rather than passed off as
> evidence.

`../probes/P-54-unstripped-module-syntax.md`,
`../rounds/363-the-check-that-would-have-refused-everything.md`.

## Round 365 — both platforms at once, which is when parity becomes visible

The first two-platform device gate of the session: Android `+24 ~2` and iOS
`+26`. Running the SAME guest on both is what turned three open questions into
one defect.

The round was sent to measure whether an offscreen WKWebView throttles guest
timers. It does not — iOS median lag is 0-1 ms up to a 100 ms delay, ~99 ms on a
1 s timer; Android is a flat 3-7 ms. The finding was the other arm:

    platform: android    RpcStatusException(13): Internal server error

The identical guest, the identical call. dart2wasm's glue calls
`performance.now()` (`guest.mjs:123`); a WKWebView is a full browser environment
and supplies it, `JavaScriptSandbox` is a bare V8 isolate and does not. So any
guest using `Stopwatch` crashed on Android and worked on iOS.

> **Ablating each language separately (round 348) is not the same as running the
> same code on both.** 348's rule catches a fix ported to one platform and not
> the other. This is the opposite shape: nothing was ported anywhere, and the
> gap is in what the two HOST ENVIRONMENTS provide for free. Add to the
> detector: list the JS globals each boot script assumes, and ask which of them
> the other sandbox does not have. A WKWebView gives you a browser; a
> JavaScriptSandbox gives you V8.

> **A bench built for one question found the defect.** The timer probe was the
> first guest code in the repository to use a `Stopwatch`, which is why six
> rounds of device work had not hit it. When a platform pair looks equivalent,
> the fastest way to find where it is not is to run code that exercises
> something new.

Its canary is also the field symptom: disabling the shim reproduces exactly the
`Internal server error` a user would see, which is what makes the message worth
recording rather than just the assertion.

`../probes/P-56-guest-timer-lag.md`,
`../probes/P-57-guest-to-host-frame-order.md`,
`../rounds/365-the-clock-one-sandbox-does-not-have.md`.
