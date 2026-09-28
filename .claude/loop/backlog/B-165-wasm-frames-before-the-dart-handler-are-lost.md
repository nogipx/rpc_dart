---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-165 — wasm: bytes pushed before the Dart handler (or the guest's handler) is installed are dropped

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Both native sides push before `loadRuntime` returns (Kotlin `drainAndPush` at `:373`, iOS during `invokeMain`) while Dart registers its handlers in the bridge constructor after it; Flutter's ChannelBuffers default is believed to be one message per channel (unverified), dropping the earliest — usually the window grant; guest-side, frames arriving before `rpcWasmReceiveBytes` exists are dropped with no else-branch.

## The shape

`packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart:51-73, 100-137, 177`; `packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:330-337, 373`;
`packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:264-271`.

## Why it matters

Flow control silently off, or a lost boot frame, for guests that emit more than
one frame at boot or await before `RpcWasm.run`.

## Witness a round would build

Guest that sends three frames during `configure`; count frames received by Dart.
Guest that awaits 100 ms before `run`; host sends immediately.

## Fix sketch

Buffer natively until Dart signals ready; queue guest-side until the handler is
installed.

## Owner decision

—
