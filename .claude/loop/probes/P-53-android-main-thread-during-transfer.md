---
file: packages/transport/rpc_dart_wasm/.dart_tool/probe/android_main_thread_test.dart
round: 362
commit: 8a7e6097
paths: [packages/transport/rpc_dart_wasm/android/**]
status: broken (round 362) — resolves "the transfer occupies the main thread" but NOT which work does, so it cannot validate a fix that moves work off it
---

# P-53 — is the Android main thread available while the plugin moves bytes

Copy into `example/integration_test/` and run
`RPC_WASM_DEVICE=<id> melos run test:wasm:device`. Kept out of the committed
suite deliberately: it passes in every state measured, so as a TEST it would
read as coverage while proving nothing.

## Measures

Platform-channel round-trip latency, sampled every 8 ms, through
`SystemChannels.platform` — a channel the Flutter engine serves natively on the
PLATFORM thread, which is the thread `Dispatchers.Main` schedules on. Its
latency IS main-thread availability.

**Deliberately not frame timings.** A frame time is a consequence two layers
away: the Flutter UI thread is separate from the Android main thread, and an
idle test app renders nothing to be janked.

## Control

The same ping loop with no transfer running, taken in the same run — an
emulator's baseline is neither zero nor stable across runs.

```
run  state        payload  idle worst  busy worst  idle>16ms  busy>16ms
1    before fix   4 MiB    22ms        59ms        1          2
2    after fix    4 MiB    17ms        56ms        1          2
3    after fix    4 MiB    33ms        28ms        2          2
4    after fix    12 MiB   12ms        70ms        0          2
5    ABLATED      12 MiB   39ms        38ms        6          3
```

## Why it is `broken`, and what it still established

**It resolves one question and not the other.** In runs 1, 2 and 4 the busy arm
is clearly worse than its own control, so the bench CAN see that the byte path
occupies the main thread. But run 5 — the ablation, with Base64 put back on
`Dispatchers.Main` — reads 38 ms busy against 39 ms idle, no worse than the
fixed state and better than run 4's fixed 70 ms.

So the bench cannot attribute the occupancy, which is exactly what validating
the fix requires. Idle worst ranges 12-39 ms across runs; that noise is the same
magnitude as the effect.

Raising the payload from 4 MiB to 12 MiB was a deliberate rebuild — the guest's
outbox hands back at most 4 MiB of base64 per drain, so 4 MiB is roughly ONE
decode — and it did not help: run 4 and run 5 differ by more than the fix does.

**What would resolve it**: a physical device rather than an emulator, or an
in-plugin timer reporting main-thread occupancy directly instead of a
scheduling proxy. See `../backlog/archive/B-41-android-base64-on-the-main-thread.md`.
