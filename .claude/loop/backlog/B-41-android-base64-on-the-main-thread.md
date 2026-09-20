---
status: closed (round 415)
round: 362
commit: 8a7e6097
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: packages/transport/rpc_dart_wasm/.dart_tool/probe/android_main_thread_test.dart
reason: "bench — the code fact is certain from reading, and the IMPACT is not: five device runs could not distinguish the fix from its own ablation, because an emulator's idle worst-case (12-39 ms) is the same magnitude as the effect. Moving work off a thread with no measurable improvement is a change nobody can defend"
---

# B-41 — Base64 runs on `Dispatchers.Main`, and the evidence says it is not the cost

## The code fact, which is not in doubt

```kotlin
private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
```

Every coroutine this plugin launches runs on the Android main thread — the one
that dispatches every platform channel in the app, not only this plugin's. On
it:

- `forwardBytesToRuntime`: `Base64.encodeToString` per host-to-guest frame under
  64 KiB (above that, `provideNamedData` avoids Base64 entirely).
- `drainAndPush`: `Base64.decode` per guest-to-host frame, and the guest's
  outbox hands back up to **4 MiB of base64 per drain** (`_rpcOutboxBudget`).
- `sendRuntimeBytes`: an `allocateDirect` + `put` copy per frame.

CPU work sized by the peer, on the UI-dispatch thread. That is worth fixing on
its face.

## Why it is not fixed

The fix was written — `withContext(Dispatchers.Default)` around both Base64
sites, leaving every IPC and `messenger.send` call exactly where it was — and it
type-checks (`analyze:native`: PASS swift / PASS kotlin) and the device suite
stayed green (`+17`).

**Five runs on an Android 11 emulator could not tell it from its own ablation:**

```
run  state        payload  idle worst  busy worst
1    before fix   4 MiB    22ms        59ms
2    after fix    4 MiB    17ms        56ms
3    after fix    4 MiB    33ms        28ms
4    after fix    12 MiB   12ms        70ms
5    ABLATED      12 MiB   39ms        38ms
```

Run 5 is the canary: Base64 back on Main, and the main thread is no less
available than with the fix — better, against run 4. Idle worst ranges
12-39 ms, which is the size of the effect being looked for.

**The negative result is itself informative.** The occupancy is real (runs 1, 2
and 4 show busy clearly worse than their own controls) but removing Base64 from
the main thread does not remove it — so the cost is elsewhere, and the remaining
candidates are things that CANNOT simply be moved:

- `evaluateJavaScriptAsync("_rpcWasmDrainOutbox()")` marshals up to 4 MiB of
  string across Binder;
- `messenger.send` must run on the main thread by contract.

So the review item's hypothesis — Base64 is the jank source — is **not supported
by measurement**. Base64 of a 64 KiB frame is well under a millisecond; the
per-drain decode is the only large one, and moving it changed nothing.

## The witness criterion cannot be met as written

The item asks for "a 4 MiB response with no frames >16 ms from the plugin". On
this emulator the IDLE control alone exceeds 16 ms in most runs (up to 39 ms),
with no transfer running at all. No fix can make that criterion pass here; it
needs hardware where the baseline is below the threshold.

## What would resolve it

1. **A physical device.** Emulator scheduling noise is the whole obstacle.
2. **An in-plugin timer** reporting main-thread occupancy directly — wrap the
   Base64 sites, accumulate elapsed micros, report over the console channel.
   Instrument BOTH arms identically and ablate only the `withContext`, or the
   instrument becomes the measurement.
3. If neither is available: ship the `withContext` on the code fact alone. That
   is a defensible engineering judgement — the change cannot alter behaviour,
   only which thread runs a pure function — but it is NOT what this loop calls a
   fix, and round 362 did not make that call unilaterally.

## The fix, written out

In `forwardBytesToRuntime`:

```kotlin
val b64 = withContext(Dispatchers.Default) {
    android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
}
```

In `drainAndPush`, replacing the per-frame decode loop:

```kotlin
val frames = withContext(Dispatchers.Default) {
    raw.split('\n')
        .filter { it.isNotEmpty() }
        .map { android.util.Base64.decode(it, android.util.Base64.DEFAULT) }
}
for (bytes in frames) {
    sendRuntimeBytes(runtimeId, bytes)
}
```

Needs `import kotlinx.coroutines.withContext`.

## Owner decision

**Whether to ship a thread move that measurement cannot justify.** The code fact
is real and the change is cheap and safe; the impact is unproven and the one
measurement available says the cost is somewhere else. Round 362 recommends
taking option 3 only alongside option 1 or 2 — if a physical device ever runs
this bench, the question answers itself in one run.

**Taken in the backlog review: closed as unproven. Do not ship the move.**

Moving work off a thread with no measurable improvement is a change nobody can
defend later, and this one has five runs saying the fix is indistinguishable
from its own ablation — 38 ms busy against 39 ms idle, against the fixed state's
own 70 ms.

**The negative is the deliverable and it belongs in `checked/`**, because it is
worth more than the fix would have been. It carries three things a future round
would otherwise pay for again:

- the occupancy is REAL (busy clearly worse than control in 3 of 5 runs) and is
  NOT Base64;
- the remaining candidates cannot be moved — `evaluateJavaScriptAsync`
  marshalling 4 MiB across Binder, and `messenger.send`, which must be on Main
  by contract;
- **the emulator cannot measure this at all.** Its idle worst-case is 12-39 ms,
  the same magnitude as the effect, and the item's own criterion (no frames over
  16 ms) is already violated by the IDLE control. Any re-run on an emulator will
  reproduce this non-result.

So reopening needs a physical device or in-plugin instrumentation timing both
arms identically — not another emulator run. The written fix stays in the record
for whoever has the hardware.
