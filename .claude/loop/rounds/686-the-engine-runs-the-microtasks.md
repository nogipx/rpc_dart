---
round: 686
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — a new device test, `example/integration_test/guest_awaits_a_native_promise_test.dart`, and a guest method for it
commit: yes
release: changelog
severity: S1
---

# Round 686 — the engine runs the microtasks

## Target

B-167: the iOS boot script replaces `queueMicrotask` with a queue it drains
only on a timer tick, an inbound frame or boot, so a Dart continuation resumed
by a native promise waits for the next tick -- indefinitely when idle. The lead
said the polyfill was needed on Android.

## Hypothesis

dart2wasm schedules every Dart microtask through `queueMicrotask` (the
generated `guest.mjs`: `queueMicrotask(() => dartInstance.exports.$invokeCallback(c))`).
When the engine resumes a promise, the Dart code it runs schedules into the
polyfill's queue, and nothing drains it until something else happens.

## Before

A guest method `AfterPromise` that awaits `Promise.resolve()` N times. N = 1
answered (iOS 31 ms, Android 121 ms): one await slips through on a tick the
call itself causes. N = 100:

```
platform: ios      answer: ERR TimeoutException  after 10015ms
platform: android  answer: ERR TimeoutException  after 10022ms
```

Both platforms, not iOS alone: the Android boot script has the same queue.

## Mechanism

As hypothesised, on both boot scripts.

## Fix

- iOS: the boot script no longer defines `queueMicrotask`, so WebKit's own is
  used.
- Android: `queueMicrotask` puts the callback on the engine's microtask queue
  through a promise job (`Promise.resolve().then(...)`), which runs at the
  engine's checkpoint, after a native promise as after anything else.
- `_flushMicrotasks` keeps its other job on both: delivering frames held for a
  receiver the guest installs late.

## After

```
platform: ios      answer: resumed 100 in 1000us  after 31ms
platform: android  answer: resumed 100 in 1000us  after 81ms
```

Full device suite: Android 28 passed, 4 skipped; iOS 30 passed, 2 skipped.

## Canary

Before is the canary: the same guest and test against the old boot scripts,
timing out on both platforms. N = 1 is the control that shows why the
existing suite never saw it.

## The verdict questions

1. Yes: Before on the same guest is the canary; N = 1 is the control.
2. Yes, and wider than the lead: both platforms.
3. Yes: whether a guest call completes, and how long it takes.
4. Not zero-valued.
5. Yes, quoted.
6. One cause, in two boot scripts.
7. Not a policy question.
8. None.

## Gate

`analyze:native` (Swift and Kotlin PASS), `test:wasm:device` on both
platforms, the example's guest and new test analysed clean.

## Not fixed

Nothing in scope. The timer polyfills (B-169) are untouched.

## Links

Lead `../backlog/B-167-ios-wasm-replaces-queuemicrotask.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 686]`.
