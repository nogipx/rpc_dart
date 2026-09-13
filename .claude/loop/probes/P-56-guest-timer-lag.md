---
file: packages/transport/rpc_dart_wasm/example/integration_test/guest_timer_lag_test.dart
round: 365
commit: 760511a5
paths: [packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/ios/**]
status: valid
---

# P-56 — how late is a guest `Timer`

Asks the guest to sleep for a requested delay ten times and report its own
min/median/max lag, at four delays. Run with
`RPC_WASM_DEVICE=<id> melos run test:wasm:device` on each platform.

## Measures

Lag over the requested delay, in microseconds, **clocked INSIDE the guest**. A
round trip through the bridge costs 3-31 ms (P-55), which is more than most of
the delays under test, so timing this from the host would report the transport
rather than the timer.

## Control

Each platform is the other's control, and they are genuinely different
mechanisms: Android computes the next deadline in a Kotlin driver loop and
sleeps on it; iOS runs a JS tick scheduler inside a WKWebView that is never
added to a view hierarchy — a permanently hidden page, which is exactly where
WebKit throttles timers.

```
platform: ios              min       median    max
Timer(1 ms)                0.0ms     0.0ms     1.0ms
Timer(10 ms)               0.0ms     1.0ms     1.0ms
Timer(100 ms)              0.0ms     1.0ms     101.0ms
Timer(1000 ms)             53.0ms    99.0ms    101.0ms

platform: android          min       median    max
Timer(1 ms)                2.0ms     3.0ms     8.0ms
Timer(10 ms)               3.0ms     4.0ms     8.0ms
Timer(100 ms)              4.0ms     5.0ms     6.0ms
Timer(1000 ms)             5.0ms     7.0ms     12.0ms
```

**Neither platform throttles into uselessness**, which is the question the
review asked. iOS is tighter at short delays and drifts ~10% on a 1 s timer;
Android is a flat few milliseconds everywhere.

## What building it found

The Android arm did not merely differ — it **threw**. `RpcStatusException(13):
Internal server error` from the guest, where the identical guest worked on iOS.
dart2wasm's glue calls `performance.now()` (`guest.mjs:123`), WKWebView supplies
it, and JavaScriptSandbox is a bare V8 isolate that does not. Fixed in round
365 with a `Date.now()` shim.

> A bench built to answer one question found a defect the question did not
> mention, because it was the first guest code in this repository to use
> `Stopwatch`.
