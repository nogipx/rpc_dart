---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/lib/rpc_dart_wasm.dart, packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart, packages/transport/rpc_dart_wasm/pubspec.yaml]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-171 — wasm: the barrel claims to be runtime-agnostic and needs Flutter; `canRunDartWasm` ignores Android's requirements

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The library doc says transport layer only, but the barrel exports the Flutter bridge and the pubspec hard-depends on flutter; the stub's "non-Flutter" comment is wrong (it is the web branch); podspec 0.2.0 vs pubspec 0.2.1; `canRunDartWasm` ignores `wasmCompilationSupported`/`namedDataSupported`, so it can say yes while `load()` fails.

## The shape

`packages/transport/rpc_dart_wasm/lib/rpc_dart_wasm.dart:5-13`; `lib/src/rpc_flutter_wasm_bridge.dart:28-29, 141-151`;
`packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:145-150`.

## Why it matters

Misleading API for embedders; a support probe that lies on some devices.

## Witness a round would build

None / an emulator without wasm compilation.

## Fix sketch

Fold the two flags into `canRunDartWasm`; fix docs and versions.

## Owner decision

—
