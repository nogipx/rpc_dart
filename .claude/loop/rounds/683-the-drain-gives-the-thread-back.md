---
round: 683
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — a device probe (`integration_test/zz_probe_burst.dart`, untracked) and the device suite
commit: yes
release: changelog
---

# Round 683 — the drain gives the thread back

## Target

B-255: "10k frames from one guest stream arrive in order" fails on the Android
emulator and passes on the iOS simulator. The failure text had never been
captured.

## Hypothesis

None at first: the lead asked for the error before any reading.

## Before

The test with a temporary `catchError` print, emulator-5554:

```
RpcStatusException(8): Stream 1 buffered more than 1024 un-consumed messages without being consumed
  RpcChannelTransport._admitToStreamBuffer  channel_transport.dart 383
```

The host's per-stream cap (`maxBufferedMessagesPerStream`, 1024). The
flow-control window cannot prevent it: 4 MiB by default, and 10000 frames of 26
bytes are about 260 KB.

A VM probe (`.dart_tool/probe/b255_burst.dart`) did NOT reproduce it: each
chunk delivered in its own `Timer` task, and sends that complete a task later,
both 10000 of 10000. So the consumer keeps up whenever microtasks run between
deliveries. The device probe wraps the bridge and counts, per incoming chunk,
microtasks scheduled and not yet run:

```
outcome=error RpcStatusException(8) ... added=3706 consumed=1536 maxLag=3706 maxPendingMicro=3703
```

3703 platform messages arrived with no microtask run between them.

## Mechanism

`RpcDartWasmPlugin.kt` `drainAndPush` runs on `Dispatchers.Main` and, for every
frame a drain returns (up to 4 MiB of base64 per round), calls
`messenger.send`. Each send runs the Dart handler on that same thread, inside
the same task; Dart's microtasks -- where `RpcChannelTransport` hands a frame to
its consumer -- only run once the task returns. So one drain queued thousands
of frames before the consumer saw any. iOS delivers each frame through its own
`fetch`, a separate task.

## Fix

`drainAndPush` calls `yield()` after every 256 frames sent, which returns the
main thread to the looper and lets the microtasks run.

The owner chose 256 over yielding per frame, measured on the order test
(debug build, emulator, 10000 frames):

```
yield every frame   4210 ms, 2844 ms
yield every 256     1951 ms, 2081 ms
```

The cost of 256: a host policy with `maxBufferedMessagesPerStream` under about
256 could still trip on a burst.

## After

Device probe: `outcome=ok 10000 added=10004 consumed=10000 maxLag=5
maxPendingMicro=2` (per-frame yield; the 256 variant passes the order test
twice). Full device suite: Android 27 passed, 3 skipped; iOS 29 passed, 1
skipped.

## Canary

Before is the canary: the same tree without the yield, the same test, the
1024 failure above. The VM probe is the control: it shows the consumer keeps up
when microtasks run, so the yield is what changed the outcome.

## The verdict questions

1. Yes: Before on the same tree is the canary.
2. Yes: the test the lead named, on the platform where it failed.
3. Yes: the frame count the caller received.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Yes; the owner chose the batch size after seeing both timings.
8. None.

## Gate

`analyze:native` (Swift and Kotlin PASS), `test:wasm:device` on both
platforms. No Dart source changed.

## Not fixed

A host policy with a per-stream cap under 256 against a fast guest burst.

## Links

Lead `../backlog/B-255-ten-thousand-guest-frames-fail-on-android.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 683]`.
