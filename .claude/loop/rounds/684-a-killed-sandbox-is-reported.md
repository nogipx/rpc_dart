---
round: 684
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — the committed kill probe (`example/integration_test/idle_sandbox_death_test.dart`), driven to a kill for the first time
commit: yes
release: changelog
severity: S2
---

# Round 684 — a killed sandbox is reported

## Target

B-102 (continuation): on Android, a JS sandbox that dies while the driver is
parked is never reported, so every call waits out its own deadline. Round 493
verified the four sites by reading and built the probe, but could not kill the
sandbox process.

## Hypothesis

The lead's: with no timer pending the driver waits on its waker and evaluates
nothing; no termination callback is registered; a forward that throws skips
`wakeDriver` and only logs.

## Before

Why round 493 could not kill it: on the Play-image emulator (API 30) the
process is visible -- `ps -A -o PID,USER,NAME` shows
`u0_i9026 com.google.android.webview:js_sandboxed_process0:...` -- but it is an
isolated uid, so `kill -9` is `Operation not permitted`, `adb root` is refused
on a production build, and `am kill` / `am force-stop` of the WebView package
leave it running.

So a second AVD, `rpc_root_33` (API 33 `google_apis`, rootable). Its stock
WebView (103) cannot compile WASM (`JS_FEATURE_WASM_COMPILATION is not
supported`), so the WebView APK from the first emulator (153.0.8010.36) was
installed on it. Then, root, `kill -9` of the sandbox pid inside the window:

```
PROBE after-window  death: NONE  closed: false
PROBE after-kill call: ERR TimeoutException  after 15036ms  death: NONE  closed: false
```

## Mechanism

As the lead read it, all three parts confirmed by the measurements below.

## Fix

`RpcDartWasmPlugin.kt`:

- `addOnTerminatedCallback` on each runtime's isolate, on the main executor,
  calling `reportDeath`. An ordinary close removes the id first, so
  `reportDeath` ignores the callback it causes.
- `forwardBytesToRuntime` wakes the driver in a `finally`.
- The forward's catch reports an `IsolateTerminatedException` (a no-op after an
  ordinary close, for the same reason).
- `reportDeath` wakes the driver, which otherwise stays parked on its waker
  after its runtime is gone.

`tool/check_native.sh` puts `androidx.core` on the Kotlin classpath:
javascriptengine's own API takes its `Consumer`, and without it the type-check
failed on the callback.

## After

Same rig, same kill:

```
PROBE after-window  death: RpcStatusException  closed: false
PROBE after-kill call: ERR RpcStatusException  after 23ms  death: RpcStatusException  closed: true
```

## Canary

Callback registration disabled, same rig and kill:

```
PROBE after-window  death: NONE  closed: false
PROBE after-kill call: ERR RpcStatusException  after 308ms  death: RpcStatusException  closed: false
```

The idle death is unreported again, so the callback is what reports it. The
next call still fails fast, which is the forward's catch -- the other half,
seen on its own. Restored: the After above.

## The verdict questions

1. Yes: the canary takes out one half and the measurement shows the other.
2. Yes: the scenario the lead named, a kill while idle.
3. Yes: what Dart was told, and how long a call took.
4. Not zero-valued.
5. Yes, quoted.
6. Two mechanisms, separated by the canary.
7. Not a policy question.
8. None.

## Gate

`analyze:native` (Swift and Kotlin PASS), `test:wasm:device` on the Android
emulator (27 passed, 3 skipped). No Dart source changed.

## Not fixed

The witness needs the rooted AVD and a sideloaded WebView, so it stays a
manual, gated probe.

## Links

Lead `../backlog/B-102-the-android-wasm-sandbox-death-goes-unreported-when-idle.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 684]`.
