---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/lib/src/rpc_wasm.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-172 — wasm: smaller native and Dart defects

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Racing checkSupport web views, unescaped script splicing, a retain cycle, an unguarded detach, unanswered replies after cancel, an empty channel name, a doc double start, a stale endpoint, a one-shot run, interop copies, an ignored HTTP status.

## The shape

1. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:276-279` — the recv loop never checks `r.ok`; the 499 that `stop()`
   answers (`:416-426`) is delivered to the guest as an empty frame. (The loop's
   silent give-up itself is B-38, closed by the owner, not re-filed.)
2. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:47-66` — concurrent `checkSupport` calls replace and deallocate each
   other's WKWebView.
3. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:286-287, 345-351` — glue spliced into an inline `<script>` without
   escaping `</script>`; `stripModuleSyntax` is an unanchored global replace while
   the leftover check is line-anchored.
4. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:567-568` — `userContentController.add(self, ...)` retains the runtime
   until `close()`; a runtime never closed after a reported death leaks a
   WKWebView and its process.
5. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:312` — `?? ""` registers a handler on the empty channel name.
6. `packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:57` — `onDetachedFromEngine` closes runtimes without try; after
   `scope.cancel()` the per-message `launch` never runs its `finally`, so
   `reply.reply(null)` is never sent and Dart's `send()` hangs.
7. `packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:146-149` — error maps inconsistent (`runtimeId` missing); `messageCounter`
   atomic on a single thread; `var globalThis = this;` (`:175`); outbox budget
   arithmetic (`:309-323`) computes a constant.
8. `rpc_wasm.dart:31-35` — doc calls `endpoint.start()` inside `configure` and
   `_boot` calls it again; `_activeEndpoint` never cleared (`:40-43, 143`);
   `_initialized` makes `run` one-shot (`:63`); `toDart`/`toJS` read bytes through
   interop (`:188, 201`).
9. Drift facts for the owner's C-23/C-56 decisions: `onerror`/
   `onunhandledrejection` hooks exist on iOS only; a `performance` shim on Android
   only.

## Why it matters

Items 1, 2, 4 and 6 are behaviour; the rest hygiene.

## Witness a round would build

Item 6: detach the engine with a send in flight.

## Fix sketch

One commit per platform.

## Owner decision

—
