---
file: packages/transport/rpc_dart_wasm/example/integration_test/frame_cost_test.dart
round: 364
commit: 8b1b055c
paths: [packages/transport/rpc_dart_wasm/android/**, packages/transport/rpc_dart_wasm/ios/**, packages/transport/rpc_dart_wasm/lib/**]
status: valid
---

# P-55 — what one call over the wasm bridge costs

Round-trips a real dart2wasm guest at four payload sizes and reports p50/p95/p99
per shape. Run with `RPC_WASM_DEVICE=<id> melos run test:wasm:device`; add a
shape by adding a row.

Round-trip, not one-way: it is what a caller experiences, and the only thing
measurable without clocks on both sides of a process boundary.

## Measures

Wall-clock microseconds from `unaryRequest` to its answer, at the caller. A
**warm-up call is discarded** — the first pays sandbox and isolate setup no
later call pays, and folding it into the median would describe a cost nobody
sees twice.

## Control

The empty-unary row is the control for every other row: it carries no payload,
so whatever it costs is the boundary itself. That an empty call and a 1 KiB call
cost the SAME is the finding — the price is the round trip, not the bytes.

```
platform: android            (Android 11, API 30, emulator)
shape             n       p50      p95      p99
empty unary       n=200   12.9ms   50.8ms   153.0ms
1 KiB response    n=200   12.3ms   66.3ms   214.2ms
64 KiB response   n=100   15.5ms   94.2ms   556.3ms
1 MiB response    n=20    114.9ms  903.3ms  903.3ms
```

**An emulator is a floor, not a prediction.** Real hardware is faster and its
tail much more so, which is why the README publishes the SHAPE — flat to 1 KiB,
p99 roughly ten times p50 because a call can miss a driver tick — and labels the
absolute numbers with the hardware they came from.

Not measured: the same table on iOS, and the latency a guest `Timer` sees while
the WKWebView is offscreen. Both need a simulator.
