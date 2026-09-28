---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-170 — wasm: multi-line console messages lose their level prefix

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The bridge splits console text on `\n` and only the first line carries `E:`/`W:`; a stack trace or `'uncaught: ' + stack` becomes unprefixed lines, so a consumer filtering on `E:` misses most of an error.

## The shape

`packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart:88, 115`; Android joins calls with
`\n` (`packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:200`).

## Why it matters

Errors disappear from level-filtered logs.

## Witness a round would build

Guest `console.error('a\nb')`; inspect the console stream.

## Fix sketch

Carry the level per message, not per line.

## Owner decision

—
