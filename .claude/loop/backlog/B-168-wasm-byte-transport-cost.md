---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-168 — wasm: one HTTP request per frame on iOS, base64 plus a fresh script per frame on Android, a polling driver

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

IOS: a URL-scheme fetch per frame each way, `/recv` returns exactly one frame even when many are queued, sends are fire-and-forget with no backpressure and ordered only by WebKit convention, send rejections surface as unhandled-rejection console noise; Android: pure-JS base64 with per-byte string concatenation, V8 parses and compiles a new script for every frame under 64 KiB, and the driver costs three IPC round trips per tick.

## The shape

`packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:261, 276-280, 476-478`; `packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:266-295, 309-323, 465-507, 583-585`.

## Why it matters

Throughput and latency; part is forced by `JavaScriptSandbox`, but named data is
already in use and could carry all host→guest traffic.

## Witness a round would build

Frames/s for 1 KiB frames each direction, both platforms.

## Fix sketch

Batch `/recv` with length prefixes; named data for every host→guest frame; drain
console and outbox in one evaluation.

## Owner decision

—
