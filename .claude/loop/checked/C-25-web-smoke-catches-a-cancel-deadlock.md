---
round: 227
commit: 9d6ebfdd
paths: [packages/blob/rpc_blob/test/web_smoke_test.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
scope: [core, blob]
---

# C-25 — the web smoke tests do catch a cancel deadlock

Round 219 called the web guard a census: it proves a package still builds for
JS, and "was never shown to catch the bug classes RPC-07 is about". Round 227
showed it, for the cancel class, by ablation.

## Measurement

A hang planted in the stream controller's `onCancel`
(`caller_pipeline.dart:480`) — the hop `sub.cancel()` awaits — then
`rpc_blob/test/web_smoke_test.dart`:

```
  plant absent    +2, All tests passed
  plant present   -2

    RPC get-stream cancel mid-download does not deadlock (web)
      TimeoutException after 0:00:03.000000: Future not completed
      test/web_smoke_test.dart 63:5

    RPC put/get/list round-trip (web)
      TimeoutException after 0:00:30.000000: Test timed out
```

The detector fired at exactly the budget it sets for itself on line 63,
`await sub.cancel().timeout(const Duration(seconds: 3))`.

## Control

The same file with the plant removed passes (`+2`), so the red is the plant and
not the harness. And the test is not vacuous: lines 60-61 assert
`received > 0` and `received < data.length ~/ 4096`, so the cancel provably
lands while the server stream is still producing.

## What this does NOT establish

- **Only this class, only this file.** `rpc_data`'s watchChanges/export cancels
  and `rpc_dart_websocket`'s "caller close cancels subscription without
  deadlock" and "32-bit header (JS-safe)" have the same shape and were NOT
  ablated. Each would need its own plant.
- **Coverage is still whatever those files happen to exercise.** Nine of twelve
  packages contribute a handful of hand-written tests, not a suite — round 219's
  census stands. What is retired is the inference that a handful of tests must
  therefore be shallow.

## Also measured, and worth not re-hunting

**The dart2js `async*` cancel-deadlock does not reproduce on Dart 3.10.1.**
Reverting the documented mitigation at `responder_pipeline.dart:1604`
(`unawaited(handlerSub.cancel())` → `await handlerSub.cancel()`) left core's
`handler_cancellation_leak_test.dart` green on BOTH the VM and node. The class
is in private memory as a confirmed history for this project; that history is
over, and a plant of it measures nothing.

**`melos run test:web`'s Chrome step is cold-start flaky here.** A full baseline
failed on `Timed out waiting for Chrome to connect` in `rpc_dart_isolate`;
rerunning that step alone exited 0. The `-j 1 --timeout 3x` in `pubspec.yaml`
already exists for this and is not always enough. Not a regression.

Lead, now closed: `../backlog/B-18-web-guard-is-a-census-not-a-sweep.md`.
