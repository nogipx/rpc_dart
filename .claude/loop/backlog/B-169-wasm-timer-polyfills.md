---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-169 — wasm: the timer polyfills are O(n) per call and break event-loop ordering

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_scheduleNextTick` walks every timer on every `setTimeout` (O(n^2) for many timers); due timers fire in id order, not deadline order; microtasks are flushed after ALL due timers instead of between them; `setInterval(fn, 0)` becomes 16 ms; extra `setTimeout` arguments are dropped; on iOS the polyfill replaces working native timers.

## The shape

`packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:207-259`; `packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:219-259`.

## Why it matters

Guest code observing different timer semantics than JS and Dart specify.

## Witness a round would build

Two timers (20 ms, 10 ms) scheduled in that order with a microtask each; observe
order.

## Fix sketch

A deadline-ordered heap; flush microtasks per timer; native timers on iOS.

## Owner decision

—
