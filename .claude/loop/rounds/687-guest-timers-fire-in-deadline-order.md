---
round: 687
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — a new device test, `example/integration_test/guest_timer_order_test.dart`, and a guest method for it
commit: yes
release: changelog
severity: S2
---

# Round 687 — guest timers fire in deadline order

## Target

B-169: the timer polyfills in both boot scripts. Due timers fire in id order,
not deadline order; microtasks run after ALL due timers instead of between
them; `_scheduleNextTick` walks every timer on every `setTimeout`; extra
`setTimeout` arguments are dropped; `setInterval(fn, 0)` becomes 16 ms; on iOS
the polyfill replaces working native timers.

## Hypothesis

The two ordering items are visible to Dart code; the rest are cost or
parity.

## Before

A guest method `TimerOrder`: Timer(30 ms) 'late', Timer(10 ms) 'early' (which
schedules a microtask 'micro'), Timer(10 ms) 'same', then a 60 ms busy wait so
all three are due on one tick. A browser and the VM give
`early,micro,same,late`.

```
platform: ios      order: late,early,same,micro
platform: android  order: late,early,same,micro
```

## Mechanism

As the lead read it: both tick functions walk `Object.keys(_timers)` -- id
order -- and drain microtasks once, after the loop.

## Fix

- iOS: the polyfill is gone. `setTimeout`/`setInterval`/`clear*` are thin
  wrappers over WebKit's own, captured in the earlier script tag, which log a
  throw and deliver frames held for a late receiver after each callback.
  Deadline order, microtasks between callbacks, extra arguments, and the
  per-`setTimeout` walk are all WebKit's.
- Android (a bare V8 sandbox, no timers of its own): `_tickAndReportNext` is
  async, sorts due timers by deadline then id, skips one cleared by an earlier
  callback, and `await`s after each, which yields to the engine's microtask
  queue -- where dart2wasm drains every pending Dart microtask in one job.
  `setTimeout` no longer walks the timers. Extra arguments are passed.

## After

```
platform: ios      order: early,micro,same,late
platform: android  order: early,micro,same,late
```

Full device suite: Android 29 passed, 4 skipped; iOS 31 passed, 2 skipped.

## Canary

Before is the canary for both platforms. Android ablation, the `await` after
each timer removed: `early,same,late,micro` -- the sort holds, and the
microtask is back after every timer.

## The verdict questions

1. Yes: Before, plus an ablation of the Android half.
2. Yes: the two ordering items, on both platforms.
3. Yes: the order the guest's own code observed.
4. Not zero-valued.
5. Yes, quoted.
6. Two mechanisms on Android, separated by the ablation.
7. Not a policy question.
8. None.

## Gate

`analyze:native` (Swift and Kotlin PASS), `test:wasm:device` on both
platforms, the example's guest and new test analysed clean.

## Not fixed

Android keeps a zero `setInterval` at 16 ms, on purpose: the driver evaluates
one tick per deadline, so 0 would spin it. The O(n) scan per tick on Android
stays; only the per-`setTimeout` one is gone.

## Links

Lead `../backlog/B-169-wasm-timer-polyfills.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 687]`.
