---
round: 470
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-11
bench: none — the bench is a device, and the instrument is the suite's own exit status
commit: yes
---

# Round 470 — the device suite ran on Android, and it was red

## Target

B-38, B-03 and B-85 all carry the same blocker, and it is written the same way in
each: *"`xcrun simctl` and `open -a Simulator` are outside this session's
allowlist"*. L-13 says re-measure the sentence a decision rests on, and this one
had never been re-measured — it was recorded in round 357 and copied forward.

**It is false.** `xcrun simctl list devices booted` runs here, and so does
`xcrun simctl boot`.

## Hypothesis

If the blocker is stale, one or both device platforms may be reachable, and the
Android arm of `test:wasm:device` has never been run at all — B-38 says so in as
many words: *"Run it on Android too, which this session never could."*

## Before

The real blocker, measured:

```
xcrun simctl list devices booted     runs; nothing booted
xcrun simctl boot <any iPhone>       Unable to boot device because it cannot be
                                     located on disk. The device's data is no
                                     longer present at
                                     .../Devices/<udid>/data
```

Every registered simulator, systemically. That is a broken CoreSimulator
installation, not a permission. **Android is a different story:**

```
fvm flutter emulators --launch Small_Phone   booted
fvm flutter devices                          sdk gphone arm64 • emulator-5554
                                             • Android 11 (API 30)
```

API 30 clears the `minSdk = 26` floor `androidx.javascriptengine` imposes, so the
suite can run.

First run, ever, of `melos run test:wasm:device` on Android:

```
+23 ~2 -1   Some tests failed.
```

## The defect

```
plugin_test.dart: glue code that throws is reported, not waited out
  Expected: throws <Instance of 'StateError'>
    Actual: <Instance of 'Future<RpcFlutterWasmBridge>'>
     Which: threw RpcStatusException(14): Failed to load WASM runtime: Uncaught ...
```

A stale assertion, and **two things had to line up for nobody to notice**. Round
416 replaced the library's `StateError`s with typed status exceptions — its whole
finding was that `wireStatusFor` is default-deny, so a `StateError` is redacted to
INTERNAL and the caller loses the reason. And this suite is outside every ordinary
gate: `melos run analyze` and `melos run test` do not compile a line of it, which
is exactly what `CLAUDE.md` warns about under "native code needs its OWN two
scripts".

**The throw is in SHARED Dart**, `rpc_flutter_wasm_bridge.dart:172`, not in either
platform's plugin. So the assertion was stale on iOS too, and fixing it needs no
simulator — which is the one part of these three leads that was never blocked.

## Mechanism

The assertion now pins what round 416 established: `RpcStatusException` with
`unavailable`, rather than a type the library stopped throwing. The timing
assertion the test exists for — under 15 s against a 30 s watchdog — is untouched.

## After

```
+24 ~2   All tests passed!
```

## Canary

None written, and the reason is the verdict: the failing run IS the canary. The
suite was red before the edit and green after, on the same device, with nothing
else changed — the strongest form of "switch it off and watch it break", because
it was off to begin with.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`melos run test:wasm` SUCCESS (+44), and `melos run test:wasm:device` SUCCESS
(+24 ~2) on `emulator-5554`.

## Not fixed

**B-38's own subject is untouched** — the iOS recv loop still gives up silently.
Its fix is Swift and its witness is iOS-only by construction (*"Android drives
host-to-guest over Binder with no pending-task slot, so there is nothing to
supersede"*), so the Android emulator does not reach it.

**iOS remains blocked, but for a different and more specific reason than the
leads record.** Not the allowlist: every simulator's data directory is missing
from disk. The remedy is one command in the owner's environment —
`xcrun simctl erase <udid>` or recreating the device in Xcode — and I have not
run it, because erasing a simulator destroys its contents and that is a change to
the machine rather than to this repository.

The two skips (`~2`) are the iOS-only cases the suite gates on
`!Platform.isIOS`, exactly as designed.

## Links

- RPC-11 — a gate that does not cover a target; this suite is outside every
  ordinary one, and the first run of it found a test that had been wrong since
  round 416
- L-13 — the blocker in three leads was a sentence nobody re-measured. `xcrun
  simctl` runs fine; the real obstacle is elsewhere and needed a different fix
- Round 416 — where the type changed
- B-38, B-03, B-85
