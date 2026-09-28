---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
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

## Owner decision

—
