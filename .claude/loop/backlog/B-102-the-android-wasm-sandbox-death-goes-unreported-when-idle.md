---
status: open
round: 493
commit: 016d34d6
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/example/integration_test/idle_sandbox_death_test.dart]
probe: "packages/transport/rpc_dart_wasm/example/integration_test/idle_sandbox_death_test.dart — built, gated, never yet driven to a kill"
reason: "bench — the witness needs the sandbox process killed from the HOST mid-run, and round 493 could not identify that process on the emulator in five runs; the instrument is built and committed"
continuation: yes
---

# B-102 — Android wasm: a sandbox that dies while the driver is parked is never reported

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

With no timers pending the driver parks on `waker.await()`; only `wakeDriver` at the END of `forwardBytesToRuntime` wakes it, which an `IsolateTerminatedException` skips (the catch only logs); no `setOnTerminatedCallback` is registered — so `reportDeath` never runs and every in-flight call hangs.

## The shape

`packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:410-442` (driver: `if (nextDeadlineMs == null) waker.await()`), `:478-491`
(`wakeDriver(runtimeId)` is the last statement, after `.await()`), `:549-575`
(the forward catch logs "Forward to $runtimeId dropped" and nothing else).
`grep setOnTerminatedCallback` finds nothing.

## Why it matters

The "died" channel exists so Dart fails in-flight calls instead of waiting out
their deadlines (optional on this transport). An idle runtime whose sandbox
process is killed (low memory, crash) reports nothing until a timer is scheduled —
which a dead runtime never does.

## Witness a round would build

Emulator: load a runtime with no timers, kill the sandbox process
(`adb shell am kill` / `kill` on its pid), issue a call. Expected today: the call
hangs to its deadline and no `died` event arrives.

## Fix sketch

Call `wakeDriver` in a `finally`, route the forward catch to `reportDeath` for
`IsolateTerminatedException`, and register the isolate's termination callback.

## Round 493 — the four sites are verified, the kill is not

**The instrument exists now**:
`example/integration_test/idle_sandbox_death_test.dart`, committed and `skip`ped
unless `--dart-define=rpcWasmKillProbe=true`. It makes a call, proves the pipe
works, opens a 40 s window, then reports whether death was reported and how long
a later call took. A probe outside `integration_test/` is refused outright
(`integration_test plugin was not detected`), which is why it lives there.

**Every structural claim checked, by reading:**

1. `setOnTerminatedCallback`, `addOnTerminated` and `IsolateStartupParameters`
   appear NOWHERE under `android/` — grep returns nothing. No callback exists.
2. `startDriver`'s catch does call `reportDeath`, but it can only fire on an
   exception from an evaluation IN FLIGHT; parked on `waker.await()` there is
   none.
3. `wakeDriver` is the last statement of `forwardBytesToRuntime`, after the
   `.await()` that throws, so a throwing forward skips it.
4. `registerByteChannel`'s catch logs and then `reply.reply(null)` — Dart's
   `send` resolves as SUCCESS over a dead runtime.

**A concern about the FIX SKETCH, raised and refuted:** routing the forward's
catch to `reportDeath` looked unsafe, because the code's own comment says an
ordinary close with traffic in flight is the usual source of
`IsolateTerminatedException`. It is safe — `closeRuntime` removes the id from
`runtimes` before closing, and `reportDeath` opens with
`if (!runtimes.containsKey(runtimeId)) return`. `closeRuntime` also calls
`wakeDriver` itself. **So the gap is external death only**, and the sketch's
three steps stand as written.

**What is missing is one fact.** Five device runs, three of them with the window
open, sampling `adb shell ps -A` for `sandboxed`, `nogipx`, `rpc_dart_wasm` and
`webview`: only `webview_zygote` ever appeared, so nothing could be killed and
every arm read `death: NONE, closed: false, after-kill call: echo:b after 84ms`
— the runtime was alive because nothing had killed it.

`webview_zygote` is the sandbox service's PARENT, so its child is the target.

**And the obstacle is probably NOT timing, which is what I assumed for four of
the runs.** A sample taken 88 s in — comfortably inside the window, with the test
demonstrably past its first successful call — showed `webview_zygote` and
nothing else: not the sandbox child, and **not the example app's own process
either**, though it was plainly running. So `adb shell ps -A` is not seeing this
app's processes at all on this image, and hunting the sandbox with `ps` is the
wrong instrument rather than a mistimed one.

The next round should reach for `adb shell pidof com.nogipx.rpc_dart_wasm_example`
or `adb shell dumpsys activity processes | grep -i wasm` first, and confirm it
can see the APP before trying to find the sandbox. Once a pid can be named, the
committed test is the whole witness and this closes in one run.

## Owner decision

—
