---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-166 — Android wasm: the sandbox (or its failure) is cached for the process lifetime

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`if (sandbox != null) return sandbox!!` and `sandboxFuture = scope.async {...}` — one failed bind is rethrown to every later `checkSupport`/`loadRuntime`, a dead sandbox is reused and every `createIsolate` throws; `checkSupport` starts the whole sandbox service just to probe.

## The shape

`packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:86-103`.

## Why it matters

One transient failure disables wasm until the app restarts.

## Witness a round would build

Kill the sandbox process; call `loadRuntime` again.

## Fix sketch

Reset both fields on failure and on sandbox death.

## Owner decision

—
